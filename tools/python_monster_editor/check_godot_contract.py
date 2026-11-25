"""Check the .rtcmonster examples against the real Godot project.

Runs tools/monster_bridge/contract_probe.tscn in the pinned Godot, then compares
what the engine reports - EnemyDefinition values, actor scene structure, state
timings, collision shapes, animation profiles, SpriteFrames and loot tables -
with the example documents. Nothing is mocked: a number in an example that
differs from the game fails here.

    python tools/python_monster_editor/check_godot_contract.py --godot <Godot 4.7.2>

What this does not prove: no data-driven runtime exists yet, so no document is
executed. Combat and network behaviour of data-driven monsters stay
NOT_EVALUATED.
"""

import argparse
import json
import math
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from rtcmonster import FAIL, read_document, validate, write_document  # noqa: E402
from rtcmonster.modules import EVENTS, GAMEPLAY, MODULES, SNAPSHOT_STATES  # noqa: E402
from rtcmonster.project import bind_sources, published_monsters, source_states, UNCHANGED  # noqa: E402
from rtcmonster.timing import DEFAULT_TICK_RATE  # noqa: E402
from rtcmonster.validation import STATIC_DOMAINS  # noqa: E402

EXAMPLES = HERE / "examples"
ENGINE_ERRORS = re.compile(
    r"SCRIPT ERROR:|(?:^|\n)(?:ERROR|WARNING):|Parse Error|orphan|CowData|ObjectDB instances leaked|"
    r"resources still in use", re.I)
EXPECTED_NETWORK_PROTOCOL = 20
# EnemyRuntimeSnapshot.State that NetworkEnemyComponent derives from a legacy state name.
DEFAULT_SNAPSHOT = {"chase": "MOVING", "patrol": "MOVING", "attack": "ATTACKING", "hurt": "HURT", "dead": "DEAD"}


class Checks:
    def __init__(self):
        self.rows = []

    def check(self, name, condition, detail=""):
        self.rows.append((name, bool(condition), detail))
        print(("PASS " if condition else "FAIL ") + name + (f" :: {detail}" if detail and not condition else ""),
              flush=True)

    def same(self, name, actual, expected):
        self.check(name, _equal(actual, expected), f"document {actual!r} != game {expected!r}")

    @property
    def failed(self):
        return [row for row in self.rows if not row[1]]


def _equal(left, right):
    if isinstance(left, (int, float)) and isinstance(right, (int, float)) \
            and not isinstance(left, bool) and not isinstance(right, bool):
        return math.isclose(left, right, rel_tol=0, abs_tol=1e-6)
    if isinstance(left, (list, tuple)) and isinstance(right, (list, tuple)):
        return len(left) == len(right) and all(_equal(a, b) for a, b in zip(left, right))
    if isinstance(left, dict) and isinstance(right, dict):
        return left.keys() == right.keys() and all(_equal(left[key], right[key]) for key in left)
    return left == right


def run_probe(godot, project, output):
    command = [str(godot), "--headless", "--path", str(project), "res://tools/monster_bridge/contract_probe.tscn",
               "--", str(output)]
    print("RUN", subprocess.list2cmdline(command), flush=True)
    result = subprocess.run(command, cwd=project, capture_output=True, text=True, encoding="utf-8", errors="replace",
                            timeout=180, stdin=subprocess.DEVNULL)
    log = result.stdout + result.stderr
    if result.returncode or ENGINE_ERRORS.search(log) or "MONSTER CONTRACT PROBE PASS" not in log:
        print(log)
        raise RuntimeError(f"contract probe failed (exit={result.returncode})")
    return json.loads(output.read_text(encoding="utf-8")), log


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


def first_commit(pattern):
    return min(event["time"] for event in pattern["events"] if EVENTS[event["type"]].side == GAMEPLAY)


def compare_common(checks, name, data, game, probe):
    c = lambda label, actual, expected: checks.same(f"{name}: {label}", actual, expected)  # noqa: E731
    binding = data["source_binding"]
    checks.check(f"{name}: EnemyDefinition validates in ContentRegistry", game["definition_errors"] == [],
                 game["definition_errors"])
    c("display_name", data["metadata"]["display_name"], game["display_name"])
    for key in ("max_health", "attack_damage", "move_speed", "chase_range", "attack_range", "faction"):
        c(f"stats.{key}", data["stats"][key], game[key])
    c("stats.hit_invulnerability_seconds", data["stats"]["hit_invulnerability_seconds"],
      game["invulnerability_seconds"])
    c("movement.gravity", data["movement"]["gravity"], probe["gravity"])
    c("sensors.target_keep_scale", data["sensors"]["target_keep_scale"], probe["target_keep_range_scale"])
    c("binding definition path", binding["definition_path"], res(game["definition_path"]))
    c("binding actor scene path", binding["actor_scene_path"], res(game["actor_scene_path"]))
    c("binding animation profile path", binding["animation_profile_path"], res(game["animation_profile_path"]))
    # Collision
    body = data["collision"]["body"]
    c("body shape", [body["shape"]], [shape_of(row) for row in game["body"]])
    c("body layer/mask", [body["layer"], body["mask"]], [game["collision_layer"], game["collision_mask"]])
    c("hurtbox shapes", [row["shape"] for row in data["collision"]["hurtboxes"] if row["enabled"]],
      [shape_of(row) for row in game["hurtbox"]["shapes"] if not row["disabled"]])
    c("hurtbox layer/mask follows the project convention",
      [game["hurtbox"]["collision_layer"], game["hurtbox"]["collision_mask"]], [2, 4])
    # Presentation and clips
    profile, presentation = game["profile"], data["presentation"]
    checks.check(f"{name}: EnemyAnimationProfile validates", profile["errors"] == [], profile["errors"])
    c("binding sprite frames path", binding["sprite_frames_path"], res(profile["sprite_frames_path"]))
    for key in ("faces_right_by_default", "visual_scale", "visual_offset", "attack_hit_frame", "airborne_speed",
                "move_speed_threshold", "roles"):
        c(f"presentation.{key}", presentation[key], profile[key])
    images = {row["id"]: row for row in data["assets"]["images"]}
    clips = {row["id"]: row for row in data["animations"]["clips"]}
    c("clip names", sorted(clips), sorted(profile["animations"]))
    for clip_id, clip in clips.items():
        shipped = profile["animations"].get(clip_id)
        if shipped is None:
            continue
        c(f"clip {clip_id} fps/loop", [clip["fps"], clip["loop"]], [shipped["fps"], shipped["loop"]])
        c(f"clip {clip_id} frames",
          [[images[frame["image"]]["path"], frame["rect"], frame["duration"]] for frame in clip["frames"]],
          [[res(frame["texture_path"]), frame["region"], frame["duration"]] for frame in shipped["frames"]])
    # Loot
    loot, table = data["loot"], game["loot"]
    c("loot table id", loot["loot_table_id"], game["loot_table_id"])
    c("binding loot table path", binding["loot_table_path"], res(table["path"]))
    c("loot entries", [[row["item_id"], row["weight"], row["min_amount"], row["max_amount"]] for row in loot["entries"]],
      [list(row) for row in zip(table["item_ids"], table["weights"], table["min_amounts"], table["max_amounts"])])
    c("loot difficulty multiplier", loot["apply_difficulty_multiplier"], table["apply_difficulty_multiplier"])
    # States and replication mapping
    folded = set(binding["passthrough"].get("folded_states", []))
    legacy_ids = [row["id"] for row in game["states"]]
    document_ids = [row["id"] for row in data["behavior"]["states"]]
    c("state ids (legacy states minus the ones folded into modules)", sorted(document_ids),
      sorted(set(legacy_ids) - folded))
    for row in game["states"]:
        replicated = (probe["snapshot_states"][row["snapshot_state"]] if row["snapshot_state"] >= 0
                      else DEFAULT_SNAPSHOT.get(row["id"], "IDLE"))
        if row["id"] in folded:
            c(f"folded state {row['id']} replicates as MOVING (the Hop module's busy part)", replicated, "MOVING")
            continue
        declared = state(data, row["id"])
        module = MODULES[declared["module"]]
        expected = declared["snapshot_state"] if declared["snapshot_state"] != "auto" else module.snapshot
        # A dynamic module replicates IDLE while it waits, which is the state the legacy node reports.
        c(f"state {row['id']} replicated state", "IDLE" if expected == "dynamic" else expected, replicated)
    # The real actor, run as a headless authority
    run = game["run"]
    checks.check(f"{name}: actor scene instantiates and runs", run["instantiated"])
    c("first state is the document's initial state", run["states_seen"][:1], [data["behavior"]["initial_state"]])
    idle_done = next(row["to"] for row in state(data, "idle")["transitions"]
                     if row["condition"].get("type") == "ActionCompleted")
    c("idle leaves to the state the document names", run["states_seen"][1:2], [idle_done])
    checks.check(f"{name}: server-mode actor creates no presenter", not run["presenter_in_server_mode"])
    checks.check(f"{name}: presentation-mode actor creates its presenter", run["presenter_in_presentation_mode"])
    # Timing shared by both legacy enemies
    attack = legacy_state(game, "attack")["properties"]
    pattern = data["attack_patterns"][0]
    c("attack pattern duration", pattern["duration"], attack["duration_seconds"])
    hit = attack["duration_seconds"] - attack["recovery_seconds"]
    c("attack commit time", first_commit(pattern), hit)
    c("wind-up ends at the commit time", pattern["phases"][0]["end"], hit)
    checks.check(f"{name}: profile hit frame shows the commit within half a tick",
                 abs(profile["attack_hit_seconds"] - first_commit(pattern)) <= 0.5 / probe["physics_ticks_per_second"],
                 f"{profile['attack_hit_seconds']} vs {first_commit(pattern)}")
    c("death removal time", state(data, "dead")["params"]["removal_seconds"],
      legacy_state(game, "dead")["properties"]["removal_seconds"])


def compare_frog(checks, data, game):
    c = lambda label, actual, expected: checks.same(f"frog: {label}", actual, expected)  # noqa: E731
    agent, constants = game["agent_properties"], game["agent_constants"]
    patrol, chase, back = (state(data, name)["params"] for name in ("patrol", "chase", "return"))
    pattern = data["attack_patterns"][0]
    impulse = next(event for event in pattern["events"] if event["type"] == "ApplyImpulse")
    contact = next(row for row in data["collision"]["hitboxes"] if row["id"] == "leap_contact")["shape"]
    c("movement.ground_brake", data["movement"]["ground_brake"], constants["GROUND_BRAKE"])
    c("movement.ground_grace_seconds", data["movement"]["ground_grace_seconds"], constants["GROUND_GRACE_SECONDS"])
    c("sensors.leash_distance", data["sensors"]["leash_distance"], agent["leash_distance"])
    c("idle wait", state(data, "idle")["params"]["seconds"], legacy_state(game, "idle")["properties"]["wait_seconds"])
    c("alert seconds", state(data, "alert")["params"]["seconds"], agent["alert_seconds"])
    c("patrol hop count", patrol["count"], legacy_state(game, "patrol")["properties"]["hops_per_patrol"])
    c("patrol hop interval", patrol["interval_seconds"], agent["patrol_hop_interval"])
    c("patrol speed scale", patrol["speed_scale"], agent["patrol_speed_scale"])
    c("patrol hop lift", patrol["lift"], agent["patrol_hop_lift"])
    c("patrol radius", patrol["patrol_radius"], agent["patrol_radius"])
    for label, params in (("chase", chase), ("return", back)):
        c(f"{label} hop interval", params["interval_seconds"], agent["chase_hop_interval"])
        c(f"{label} hop lift", params["lift"], agent["chase_hop_lift"])
        c(f"{label} stuck seconds", params["stuck_seconds"], agent["stuck_seconds"])
    c("return arrive distance", back["arrive_distance"], legacy_state(game, "return")["constants"]["ARRIVE_DISTANCE"])
    for label, params in (("patrol", patrol), ("chase", chase), ("return", back)):
        c(f"{label} prepare seconds", params["prepare_seconds"], agent["prepare_seconds"])
        c(f"{label} max drop", params["max_drop"], agent["max_drop"])
        c(f"{label} max air seconds", params["max_air_seconds"], agent["max_air_seconds"])
    c("attack cooldown", pattern["cooldown"], agent["attack_cooldown_seconds"])
    c("attack vertical reach", pattern["range"]["vertical"], agent["attack_vertical_reach"])
    c("leap impulse", impulse["velocity"], [agent["attack_leap_speed_scale"], -agent["attack_leap_lift"]])
    c("leap max air seconds", pattern["completion"]["max_air_seconds"], agent["max_air_seconds"])
    c("leap min air seconds", pattern["completion"]["min_air_seconds"],
      legacy_state(game, "hop")["constants"]["MIN_AIR_SECONDS"])
    c("contact box", contact["size"], [agent["attack_contact_distance"] * 2, agent["attack_vertical_reach"] * 2])


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--artifacts", type=Path, help="keep probe.json and the Godot log in this folder")
    parser.add_argument("--refresh-bindings", action="store_true",
                        help="after every value check passes, rewrite source_binding.files hashes in the examples")
    args = parser.parse_args()
    project = args.project.resolve()
    with tempfile.TemporaryDirectory(prefix="rtc-monster-contract-") as temporary:
        folder = args.artifacts.resolve() if args.artifacts else Path(temporary)
        folder.mkdir(parents=True, exist_ok=True)
        probe, log = run_probe(args.godot, project, folder / "probe.json")
        (folder / "godot.log").write_text(log, encoding="utf-8")

    checks = Checks()
    pinned = (project / ".godot-version").read_text(encoding="utf-8").strip()
    checks.check("Godot is the pinned version", probe["godot_version"].startswith(pinned + "-"),
                 f"{probe['godot_version']} vs {pinned}")
    checks.same("physics tick rate is the validator's default", DEFAULT_TICK_RATE, probe["physics_ticks_per_second"])
    checks.check("ContentRegistry validates", probe["content_errors"] == [], probe["content_errors"])
    checks.same("EnemyRuntimeSnapshot.State names", list(SNAPSHOT_STATES), probe["snapshot_states"])
    checks.same("network protocol version is unchanged", EXPECTED_NETWORK_PROTOCOL,
                probe["network_protocol_version"])
    checks.same("static catalog scan agrees with ContentRegistry", sorted(published_monsters(project)),
                sorted(probe["enemies"]))

    documents = {}
    for path in sorted(EXAMPLES.glob("*.rtcmonster")):
        document, revision = read_document(path)
        documents[document.monster_id] = (path, document, revision)
        report = validate(document, project, probe["physics_ticks_per_second"])
        failures = [item for item in report.findings if item.status == FAIL and item.domain in STATIC_DOMAINS]
        checks.check(f"{document.monster_id}: static validation has no failure",
                     not failures, "; ".join(f"{item.code} {item.path}" for item in failures))
    for monster_id, game in sorted(probe["enemies"].items()):
        if monster_id not in documents:
            checks.check(f"{monster_id}: has an example document", False, "no .rtcmonster mirrors this enemy")
            continue
        path, document, revision = documents[monster_id]
        compare_common(checks, monster_id, document.data, game, probe)
        if monster_id == "frog":
            compare_frog(checks, document.data, game)
        stale = [name for name, status in source_states(document, project) if status != UNCHANGED]
        if stale and args.refresh_bindings and not checks.failed:
            names = [row["path"] for row in document.data["source_binding"]["files"]]
            write_document(path, bind_sources(document, project, names), revision)
            print(f"REFRESHED {path.name}: {', '.join(stale)}")
            stale = []
        checks.check(f"{monster_id}: source files are the ones the example was derived from", not stale,
                     "changed: " + ", ".join(stale) + " - review the example, then run with --refresh-bindings")
    for monster_id, (path, document, _) in sorted(documents.items()):
        if document.data["source_binding"] is None:
            checks.check(f"{monster_id}: draft is not registered game content", monster_id not in probe["enemies"])
            missing = [row["item_id"] for row in document.data["loot"]["entries"] or ()
                       if row["item_id"] not in probe["items"]]
            checks.check(f"{monster_id}: loot items exist in ContentRegistry", not missing, missing)

    print("NOT_EVALUATED data-driven monster combat (no data-driven runtime exists in MONSTER-STEP 1)")
    print("NOT_EVALUATED data-driven monster network replication")
    if checks.failed:
        print(f"MONSTER CONTRACT CHECK FAIL ({len(checks.failed)} of {len(checks.rows)} checks failed)")
        return 1
    print(f"MONSTER CONTRACT CHECK PASS ({len(checks.rows)} checks)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
