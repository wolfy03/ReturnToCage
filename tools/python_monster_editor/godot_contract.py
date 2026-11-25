"""Evaluate a Godot contract probe. Pure functions: no Godot, no files written.

The probe (tools/monster_bridge/contract_probe.gd) reports what the engine
really has. This module turns that into five separate contracts:

    environment   Godot version, tick rate, protocol version, a clean engine log
    registry      every registered enemy, whatever it is: valid definition, actor scene, required components,
                  loot, animation profile, and that the actor really runs. No example document is involved.
    legacy        the named baseline monsters only: every value of their .rtcmonster example against the game
    data_driven   monsters that run from data. No such runtime exists, so this is NOT_EVALUATED.
    behavior      what the probe run can and cannot say about runtime behaviour

Generic checks never name a monster, a state or an attack. Everything specific
to one legacy monster lives in its ``LegacyProfile`` and is registered in
``LEGACY_PROFILES``. A new enemy in the game is covered by ``registry`` the
moment it is registered; it needs a profile only if someone decides it is a
baseline whose behaviour must be pinned.
"""

from dataclasses import dataclass, field
import math

from rtcmonster import FAIL, validate
from rtcmonster.modules import GAMEPLAY, SNAPSHOT_STATES
from rtcmonster.project import UNCHANGED, source_states
from rtcmonster.timing import DEFAULT_TICK_RATE
from rtcmonster.validation import STATIC_DOMAINS

EXPECTED_NETWORK_PROTOCOL = 20
ENVIRONMENT, REGISTRY, LEGACY, DATA_DRIVEN, BEHAVIOR = "environment", "registry", "legacy", "data_driven", "behavior"
SECTIONS = (ENVIRONMENT, REGISTRY, LEGACY, DATA_DRIVEN, BEHAVIOR)
PASS, FAILED, NOT_EVALUATED = "PASS", "FAIL", "NOT_EVALUATED"
REQUIRED_COMPONENTS = ("health", "hurtbox", "network_enemy", "states")
# EnemyRuntimeSnapshot.State that NetworkEnemyComponent derives from a legacy state name.
DEFAULT_SNAPSHOT = {"chase": "MOVING", "patrol": "MOVING", "attack": "ATTACKING", "hurt": "HURT", "dead": "DEAD"}


@dataclass
class Result:
    section: str
    name: str
    status: str
    detail: str = ""
    monster: str = ""


@dataclass
class ContractReport:
    results: list = field(default_factory=list)

    def section(self, name):
        """FAIL if anything failed; NOT_EVALUATED if anything was left unexamined; PASS only when all passed."""
        states = {row.status for row in self.results if row.section == name}
        if FAILED in states:
            return FAILED
        return PASS if states == {PASS} else NOT_EVALUATED

    def summary(self):
        return {name: self.section(name) for name in SECTIONS}

    @property
    def failed(self):
        return [row for row in self.results if row.status == FAILED]

    @property
    def passed(self):
        return [row for row in self.results if row.status == PASS]

    @property
    def ok(self):
        return not self.failed


class Checks:
    """Collects results for one section, optionally for one monster."""

    def __init__(self, report, section, monster=""):
        self.report, self.section, self.monster = report, section, monster

    def check(self, name, condition, detail=""):
        self.report.results.append(Result(self.section, name, PASS if condition else FAILED,
                                          "" if condition else str(detail), self.monster))

    def same(self, name, actual, expected):
        self.check(name, equal(actual, expected), f"document {actual!r} != game {expected!r}")

    def skip(self, name, detail):
        self.report.results.append(Result(self.section, name, NOT_EVALUATED, detail, self.monster))


def equal(left, right):
    if isinstance(left, (int, float)) and isinstance(right, (int, float)) \
            and not isinstance(left, bool) and not isinstance(right, bool):
        return math.isclose(left, right, rel_tol=0, abs_tol=1e-6)
    if isinstance(left, (list, tuple)) and isinstance(right, (list, tuple)):
        return len(left) == len(right) and all(equal(a, b) for a, b in zip(left, right))
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(equal(left[key], right[key]) for key in left)
    return left == right


def res(path):
    return path.removeprefix("res://")


def shape_of(row):
    if row["class"] == "RectangleShape2D":
        return {"type": "rectangle", "center": row["position"], "size": row["size"]}
    if row["class"] == "CircleShape2D":
        return {"type": "circle", "center": row["position"], "radius": row["radius"]}
    return {"type": row["class"]}


def state(data, state_id):
    return next(row for row in data["behavior"]["states"] if row["id"] == state_id)


def legacy_state(game, state_id):
    return next(row for row in game["states"] if row["id"] == state_id)


def first_commit(pattern, registry):
    return min(event["time"] for event in pattern["events"] if registry.events[event["type"]].side == GAMEPLAY)


# ------------------------------------------------------------------------------------------------ environment
def check_environment(report, probe, pinned_version, engine_log_clean, static_ids):
    checks = Checks(report, ENVIRONMENT)
    checks.check("Godot ran without errors, warnings or leaks", engine_log_clean,
                 "the engine log contains an error, a warning or a leak report")
    checks.check("Godot is the pinned version", str(probe.get("godot_version", "")).startswith(pinned_version + "-"),
                 f"{probe.get('godot_version')} vs {pinned_version}")
    checks.same("physics tick rate is the validator's default", DEFAULT_TICK_RATE, probe["physics_ticks_per_second"])
    checks.same("EnemyRuntimeSnapshot.State names", list(SNAPSHOT_STATES), probe["snapshot_states"])
    checks.same("network protocol version is unchanged", EXPECTED_NETWORK_PROTOCOL,
                probe["network_protocol_version"])
    checks.check("ContentRegistry validates", probe["content_errors"] == [], probe["content_errors"])
    checks.same("static catalog scan agrees with ContentRegistry", sorted(static_ids), sorted(probe["enemies"]))


# --------------------------------------------------------------------------------------------------- registry
def check_registry(report, probe):
    """Every registered enemy, by the same rules. Knows nothing about any particular monster."""
    for monster_id, game in sorted(probe["enemies"].items()):
        checks = Checks(report, REGISTRY, monster_id)
        checks.check("EnemyDefinition validates", game.get("definition_errors") == [], game.get("definition_errors"))
        checks.check("definition path is under data/content/enemies",
                     res(game.get("definition_path", "")).startswith("data/content/enemies/"),
                     game.get("definition_path"))
        checks.check("has an actor scene whose root is an EnemyAgent", bool(game.get("agent_script")),
                     game.get("actor_scene_path") or "no actor scene")
        components = game.get("components", {})
        for component in REQUIRED_COMPONENTS:
            checks.check(f"actor has the {component} component", components.get(component, False))
        checks.check("stats are positive and finite", all(
            isinstance(game.get(key), (int, float)) and math.isfinite(game[key]) and game[key] >= 0
            for key in ("max_health", "attack_damage", "move_speed", "chase_range", "attack_range"))
            and game.get("max_health", 0) > 0)
        checks.check("has a body collision shape", bool(game.get("body")))
        hurtbox = game.get("hurtbox") or {}
        checks.check("hurtbox has a shape", bool(hurtbox.get("shapes")))
        checks.same("hurtbox layer/mask follows the project convention",
                    [hurtbox.get("collision_layer"), hurtbox.get("collision_mask")], [2, 4])
        if game.get("loot_table_id"):
            checks.check("loot table exists", "loot" in game, game.get("loot_table_id"))
            missing = [item for item in game.get("loot", {}).get("item_ids", []) if item not in probe["items"]]
            checks.check("loot items exist", not missing, missing)
        if game.get("animation_profile_path"):
            profile = game.get("profile", {})
            checks.check("animation profile loads and validates", profile.get("errors") == [],
                         profile.get("errors", profile.get("error", "profile missing")))
        run = game.get("run", {})
        checks.check("actor scene instantiates and runs", run.get("instantiated", False))
        checks.check("actor enters a state", bool(run.get("states_seen")))
        checks.check("server-mode actor creates no presenter", not run.get("presenter_in_server_mode", True))
        if game.get("animation_profile_path"):
            checks.check("presentation-mode actor creates its presenter",
                         run.get("presenter_in_presentation_mode", False))


# ----------------------------------------------------------------------------------------------------- legacy
@dataclass(frozen=True)
class LegacyProfile:
    """What must be compared for one baseline monster beyond the common fields."""
    attack_state: str            # legacy state node whose exported timing the pattern mirrors
    attack_pattern: str          # the pattern in the example that describes it
    death_state: str
    extra: object = None         # callable(checks, data, game) for monster-specific values


def _common(checks, data, game, probe, registry, profile):
    binding = data["source_binding"]
    checks.same("display_name", data["metadata"]["display_name"], game["display_name"])
    for key in ("max_health", "attack_damage", "move_speed", "chase_range", "attack_range", "faction"):
        checks.same(f"stats.{key}", data["stats"][key], game[key])
    checks.same("stats.hit_invulnerability_seconds", data["stats"]["hit_invulnerability_seconds"],
                game["invulnerability_seconds"])
    checks.same("movement.gravity", data["movement"]["gravity"], probe["gravity"])
    checks.same("sensors.target_keep_scale", data["sensors"]["target_keep_scale"], probe["target_keep_range_scale"])
    checks.same("binding definition path", binding["definition_path"], res(game["definition_path"]))
    checks.same("binding actor scene path", binding["actor_scene_path"], res(game["actor_scene_path"]))
    checks.same("binding animation profile path", binding["animation_profile_path"],
                res(game["animation_profile_path"]))
    body = data["collision"]["body"]
    checks.same("body shape", [body["shape"]], [shape_of(row) for row in game["body"]])
    checks.same("body layer/mask", [body["layer"], body["mask"]], [game["collision_layer"], game["collision_mask"]])
    checks.same("hurtbox shapes", [row["shape"] for row in data["collision"]["hurtboxes"] if row["enabled"]],
                [shape_of(row) for row in game["hurtbox"]["shapes"] if not row["disabled"]])
    shipped, presentation = game["profile"], data["presentation"]
    checks.same("binding sprite frames path", binding["sprite_frames_path"], res(shipped["sprite_frames_path"]))
    for key in ("faces_right_by_default", "visual_scale", "visual_offset", "attack_hit_frame", "airborne_speed",
                "move_speed_threshold", "roles"):
        checks.same(f"presentation.{key}", presentation[key], shipped[key])
    images = {row["id"]: row for row in data["assets"]["images"]}
    clips = {row["id"]: row for row in data["animations"]["clips"]}
    checks.same("clip names", sorted(clips), sorted(shipped["animations"]))
    for clip_id, clip in clips.items():
        game_clip = shipped["animations"].get(clip_id)
        if game_clip is None:
            continue
        checks.same(f"clip {clip_id} fps/loop", [clip["fps"], clip["loop"]], [game_clip["fps"], game_clip["loop"]])
        checks.same(f"clip {clip_id} frames",
                    [[images[frame["image"]]["path"], frame["rect"], frame["duration"]] for frame in clip["frames"]],
                    [[res(frame["texture_path"]), frame["region"], frame["duration"]]
                     for frame in game_clip["frames"]])
    loot, table = data["loot"], game["loot"]
    checks.same("loot table id", loot["loot_table_id"], game["loot_table_id"])
    checks.same("binding loot table path", binding["loot_table_path"], res(table["path"]))
    checks.same("loot entries",
                [[row["item_id"], row["weight"], row["min_amount"], row["max_amount"]] for row in loot["entries"]],
                [list(row) for row in zip(table["item_ids"], table["weights"], table["min_amounts"],
                                          table["max_amounts"])])
    checks.same("loot difficulty multiplier", loot["apply_difficulty_multiplier"],
                table["apply_difficulty_multiplier"])
    # States and replication mapping
    folded = set(binding["passthrough"].get("folded_states", []))
    checks.same("state ids (legacy states minus the ones folded into modules)",
                sorted(row["id"] for row in data["behavior"]["states"]),
                sorted({row["id"] for row in game["states"]} - folded))
    declared_ids = {row["id"] for row in data["behavior"]["states"]}
    for row in game["states"]:
        replicated = (probe["snapshot_states"][row["snapshot_state"]] if row["snapshot_state"] >= 0
                      else DEFAULT_SNAPSHOT.get(row["id"], "IDLE"))
        if row["id"] in folded:
            checks.same(f"folded state {row['id']} replicates as the module's busy state", replicated, "MOVING")
        elif row["id"] in declared_ids:
            declared = state(data, row["id"])
            module = registry.modules[declared["module"]]
            expected = declared["snapshot_state"] if declared["snapshot_state"] != "auto" else module.snapshot
            # A dynamic module replicates IDLE while it waits, which is the state the legacy node reports.
            checks.same(f"state {row['id']} replicated state", "IDLE" if expected == "dynamic" else expected,
                        replicated)
    run = game["run"]
    checks.same("first state is the document's initial state", run["states_seen"][:1],
                [data["behavior"]["initial_state"]])
    initial = state(data, data["behavior"]["initial_state"])
    completed = [row["to"] for row in initial["transitions"]
                 if registry.conditions.get(row["condition"].get("type", ""))
                 and registry.conditions[row["condition"]["type"]].signal == "completed"]
    checks.same("the initial state leaves to the state the document names", run["states_seen"][1:2], completed[:1])
    # Attack and death timing, through the states the profile names
    attack = legacy_state(game, profile.attack_state)["properties"]
    pattern = next(row for row in data["attack_patterns"] if row["id"] == profile.attack_pattern)
    hit = attack["duration_seconds"] - attack["recovery_seconds"]
    checks.same("attack pattern duration", pattern["duration"], attack["duration_seconds"])
    checks.same("attack commit time", first_commit(pattern, registry), hit)
    checks.same("wind-up ends at the commit time", pattern["phases"][0]["end"], hit)
    checks.check("profile hit frame shows the commit within half a tick",
                 abs(shipped["attack_hit_seconds"] - first_commit(pattern, registry))
                 <= 0.5 / probe["physics_ticks_per_second"],
                 f"{shipped['attack_hit_seconds']} vs {first_commit(pattern, registry)}")
    checks.same("death removal time", state(data, profile.death_state)["params"]["removal_seconds"],
                legacy_state(game, profile.death_state)["properties"]["removal_seconds"])


def _frog(checks, data, game):
    agent, constants = game["agent_properties"], game["agent_constants"]
    patrol, chase, back = (state(data, name)["params"] for name in ("patrol", "chase", "return"))
    pattern = data["attack_patterns"][0]
    impulse = next(event for event in pattern["events"] if event["type"] == "ApplyImpulse")
    contact = next(row for row in data["collision"]["hitboxes"] if row["id"] == "leap_contact")["shape"]
    same = checks.same
    same("movement.ground_brake", data["movement"]["ground_brake"], constants["GROUND_BRAKE"])
    same("movement.ground_grace_seconds", data["movement"]["ground_grace_seconds"], constants["GROUND_GRACE_SECONDS"])
    same("sensors.leash_distance", data["sensors"]["leash_distance"], agent["leash_distance"])
    same("idle wait", state(data, "idle")["params"]["seconds"], legacy_state(game, "idle")["properties"]["wait_seconds"])
    same("alert seconds", state(data, "alert")["params"]["seconds"], agent["alert_seconds"])
    same("patrol hop count", patrol["count"], legacy_state(game, "patrol")["properties"]["hops_per_patrol"])
    same("patrol hop interval", patrol["interval_seconds"], agent["patrol_hop_interval"])
    same("patrol speed scale", patrol["speed_scale"], agent["patrol_speed_scale"])
    same("patrol hop lift", patrol["lift"], agent["patrol_hop_lift"])
    same("patrol radius", patrol["patrol_radius"], agent["patrol_radius"])
    for label, params in (("chase", chase), ("return", back)):
        same(f"{label} hop interval", params["interval_seconds"], agent["chase_hop_interval"])
        same(f"{label} hop lift", params["lift"], agent["chase_hop_lift"])
        same(f"{label} stuck seconds", params["stuck_seconds"], agent["stuck_seconds"])
    same("return arrive distance", back["arrive_distance"], legacy_state(game, "return")["constants"]["ARRIVE_DISTANCE"])
    for label, params in (("patrol", patrol), ("chase", chase), ("return", back)):
        same(f"{label} prepare seconds", params["prepare_seconds"], agent["prepare_seconds"])
        same(f"{label} max drop", params["max_drop"], agent["max_drop"])
        same(f"{label} max air seconds", params["max_air_seconds"], agent["max_air_seconds"])
    same("attack cooldown", pattern["cooldown"], agent["attack_cooldown_seconds"])
    same("attack vertical reach", pattern["range"]["vertical"], agent["attack_vertical_reach"])
    same("leap impulse", impulse["velocity"], [agent["attack_leap_speed_scale"], -agent["attack_leap_lift"]])
    same("leap max air seconds", pattern["completion"]["max_air_seconds"], agent["max_air_seconds"])
    same("leap min air seconds", pattern["completion"]["min_air_seconds"],
         legacy_state(game, "hop")["constants"]["MIN_AIR_SECONDS"])
    same("contact box", contact["size"], [agent["attack_contact_distance"] * 2, agent["attack_vertical_reach"] * 2])


# The baseline monsters whose legacy behaviour is pinned by an example document.
# Adding an enemy to the game does NOT require an entry here.
LEGACY_PROFILES = {
    "sewer_beetle": LegacyProfile("attack", "bite", "dead"),
    "frog": LegacyProfile("attack", "leap_bite", "dead", _frog),
}


def check_legacy(report, probe, documents, project, profiles=None):
    """``documents`` maps monster_id -> MonsterDocument. Returns ``{monster_id: [stale source paths]}``."""
    profiles = LEGACY_PROFILES if profiles is None else profiles
    stale = {}
    for monster_id, profile in sorted(profiles.items()):
        checks = Checks(report, LEGACY, monster_id)
        document, game = documents.get(monster_id), probe["enemies"].get(monster_id)
        checks.check("baseline monster is registered in the game", game is not None,
                     "a legacy baseline is missing from ContentRegistry")
        checks.check("baseline monster has an example document", document is not None,
                     "no .rtcmonster mirrors this baseline")
        if document is None or game is None:
            continue
        checks.check("example is bound to the legacy runtime",
                     (document.data["source_binding"] or {}).get("runtime") == "legacy")
        if document.data["source_binding"] is None:
            continue
        try:
            _common(checks, document.data, game, probe, document.schema.registry, profile)
            if profile.extra is not None:
                profile.extra(checks, document.data, game)
        except (KeyError, StopIteration, IndexError, TypeError) as error:
            checks.check("example and game have the structure the profile expects", False,
                         f"{type(error).__name__}: {error}")
        changed = [name for name, status in source_states(document, project) if status != UNCHANGED]
        stale[monster_id] = changed
        checks.check("source files are the ones the example was derived from", not changed,
                     "changed: " + ", ".join(changed) + " - review the example, then run with --refresh-bindings")
    return stale


def check_documents(report, probe, documents, project):
    """Static validation of every example, and that drafts are not game content.

    A draft's checks are registry checks ("this ID is not in the game"). Nothing
    about a draft is evidence for the data-driven contract, which stays unevaluated.
    """
    for monster_id, document in sorted(documents.items()):
        bound = document.data["source_binding"] is not None
        checks = Checks(report, LEGACY if bound else REGISTRY, monster_id)
        failures = [item for item in validate(document, project, probe["physics_ticks_per_second"]).findings
                    if item.status == FAIL and item.domain in STATIC_DOMAINS]
        checks.check("static validation has no failure", not failures,
                     "; ".join(f"{item.code} {item.path}" for item in failures))
        if not bound:
            checks.check("draft is not registered game content", monster_id not in probe["enemies"])
            missing = [row["item_id"] for row in document.data["loot"]["entries"] or ()
                       if row["item_id"] not in probe["items"]]
            checks.check("draft loot items exist in ContentRegistry", not missing, missing)


def check_unevaluated(report, probe):
    Checks(report, DATA_DRIVEN).skip("data-driven monster combat",
                                     "no data-driven runtime exists in MONSTER-STEP 1")
    behavior = Checks(report, BEHAVIOR)
    behavior.check("legacy actors were instantiated and ticked as a headless authority",
                   bool(probe["enemies"]) and all(row.get("run", {}).get("instantiated")
                                                   for row in probe["enemies"].values()))
    behavior.skip("legacy combat, movement and replication",
                  "covered by tests/test_runner.tscn and tools/test_multiplayer_*.py, not by this probe")
    behavior.skip("data-driven monster behaviour and network replication",
                  "no data-driven runtime exists in MONSTER-STEP 1")


def evaluate(probe, documents, project, pinned_version, engine_log_clean, static_ids, profiles=None):
    """Run every contract. Returns ``(ContractReport, stale source paths by monster)``."""
    report = ContractReport()
    check_environment(report, probe, pinned_version, engine_log_clean, static_ids)
    check_registry(report, probe)
    stale = check_legacy(report, probe, documents, project, profiles)
    check_documents(report, probe, documents, project)
    check_unevaluated(report, probe)
    return report, stale
