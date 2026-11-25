"""Turn what Godot reported about a legacy monster into a MonsterDocument.

Two layers:

* ``_common`` reads what every enemy has in the same place - EnemyDefinition values, collision shapes,
  the animation profile and its clips, loot, source files. It knows nothing about any kind of monster.
* A **legacy import profile** converts the behaviour, which in the legacy runtime is GDScript. A profile is
  registered for an *actor script* (``enemy_agent.gd``, ``frog_agent.gd``), never for a monster ID, so a
  second monster built on the same actor needs no new code, and an actor nobody wrote a profile for is
  imported partially and says so.

A profile contains numbers that exist only as literals in the legacy scripts (the idle wait, the patrol
radius, the hurt time ...). Godot cannot report them, so the profile states them and lists the scripts in
``source_binding.files``: when a script changes, validation reports ``source_changed`` and the profile must
be reviewed. Nothing is ever invented silently - what cannot be converted is listed in
``source_binding.unsupported`` and the result is not called complete.

The result always passes through ``MonsterDocument`` normalization; a response the schema cannot hold
raises instead of producing a document.
"""

from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath
import re

from rtcmonster import DocumentError, MonsterDocument, new_document
from rtcmonster.project import SOURCE_SUFFIXES, file_sha256, inspect_image, resolve_project_file
from rtcmonster.schema import MAX_IMAGE_BYTES, ROLES
from rtcmonster.spec import ID_PATTERN

COMPLETE, PARTIAL, UNSUPPORTED, FAILED = "complete", "partial", "unsupported", "failed"
SHAPES = {"RectangleShape2D": lambda row: {"type": "rectangle", "center": row["position"], "size": row["size"]},
          "CircleShape2D": lambda row: {"type": "circle", "center": row["position"], "radius": row["radius"]}}
LEGACY_EDITABILITY = {"metadata": "editable", "stats": "editable", "loot": "editable", "movement": "read_only",
                      "sensors": "read_only", "assets": "read_only", "animations": "read_only",
                      "presentation": "read_only", "collision": "read_only", "attack_patterns": "read_only",
                      "behavior": "read_only"}
# Scripts every legacy enemy runs through, whatever its actor is.
BASE_SOURCES = ("gameplay/actors/enemies/enemy_agent.gd", "gameplay/actors/enemies/enemy_state.gd",
                "presentation/definitions/enemy_animation_profile.gd",
                "presentation/enemy/enemy_animation_presenter.gd", "data/definitions/enemy_definition.gd",
                "gameplay/components/network_enemy_component.gd", "core/models/network/enemy_runtime_snapshot.gd")


class ImportError_(DocumentError):
    """The monster cannot be imported at all. ``code`` is stable."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


@dataclass
class ImportResult:
    document: MonsterDocument
    status: str                      # complete / partial / unsupported
    notes: list = field(default_factory=list)       # human-readable, one per thing that was not converted
    profile: str = ""                # the legacy import profile that was used ("" = none)


def res(path):
    return str(path or "").removeprefix("res://")


def _stat(name, scale=1, offset=0):
    return {"stat": name, "scale": scale, "offset": offset}


def _compare(kind, op, value):
    return {"type": kind, "op": op, "value": value}


def _go(to, condition, priority=0):
    return {"to": to, "priority": priority, "condition": condition}


DONE = {"type": "ActionCompleted"}


@dataclass(frozen=True)
class LegacyImportProfile:
    name: str
    states: dict           # legacy state id -> script path the profile was written against
    build: object          # callable(monster) -> dict with movement / sensors / collision extras / patterns / behavior
    folded_states: tuple = ()
    unsupported: tuple = ()          # ({"path", "reason"}, ...) parts Schema V1 cannot express exactly


def _state(monster, state_id):
    return next(row for row in monster["states"] if row["id"] == state_id)


def _ground_melee(monster):
    attack = _state(monster, "attack")["properties"]
    hit = round(attack["duration_seconds"] - attack["recovery_seconds"], 6)
    detect = _compare("TargetDistance", "<=", _stat("chase_range"))
    return {
        "movement": {"locomotion": "ground"},
        "attack_patterns": [{
            "id": "bite", "display_name": "Bite", "kind": "melee", "clip": "attack",
            "duration": attack["duration_seconds"],
            "range": {"min": 0, "max": _stat("attack_range")},
            "damage": {"multiplier": 1, "type": "physical", "knockback": [100, -30]},
            "phases": [{"kind": "windup", "start": 0, "end": hit},
                       {"kind": "recovery", "start": hit, "end": attack["duration_seconds"]}],
            "events": [{"type": "RangeStrike", "time": hit, "reach": _stat("attack_range"), "slack": 12}],
        }],
        "behavior": {"initial_state": "idle", "states": [
            {"id": "idle", "module": "Wait", "params": {"seconds": 1},
             "transitions": [_go("chase", detect, 10), _go("patrol", DONE)]},
            {"id": "patrol", "module": "GroundPatrol", "params": {"radius": 90, "speed_scale": 0.55},
             "transitions": [_go("chase", detect)]},
            {"id": "chase", "module": "ChaseTarget", "transitions": [
                _go("patrol", _compare("TargetDistance", ">", _stat("chase_range", 1.35)), 20),
                _go("attack", _compare("TargetDistance", "<=", _stat("attack_range")), 10)]},
            {"id": "attack", "module": "ExecuteAttackPattern", "params": {"pattern": "bite"},
             "animation": {"mode": "pattern"}, "transitions": [_go("chase", {"type": "AttackPatternCompleted"})]},
            {"id": "hurt", "module": "HurtReaction", "params": {"seconds": 0.25}, "transitions": [_go("chase", DONE)]},
            {"id": "dead", "module": "Death",
             "params": {"removal_seconds": _state(monster, "dead")["properties"]["removal_seconds"]}},
        ]},
    }


def _hopper(monster):
    agent, constants = monster["agent_properties"], monster["agent_constants"]
    attack = _state(monster, "attack")["properties"]
    hit = round(attack["duration_seconds"] - attack["recovery_seconds"], 6)
    leash = agent["leash_distance"]
    in_leash = _compare("TargetOriginDistance", "<=", leash)
    noticed = {"all": [in_leash, _compare("TargetDistance", "<=", _stat("chase_range"))]}

    def hop(**extra):
        return {"prepare_seconds": agent["prepare_seconds"], "max_drop": agent["max_drop"],
                "max_air_seconds": agent["max_air_seconds"], "min_progress": 6, **extra}

    chase = dict(interval_seconds=agent["chase_hop_interval"], speed_scale=1, lift=agent["chase_hop_lift"],
                 stuck_seconds=agent["stuck_seconds"])
    return {
        "movement": {"locomotion": "hop", "ground_brake": constants["GROUND_BRAKE"],
                     "ground_grace_seconds": constants["GROUND_GRACE_SECONDS"]},
        "sensors": {"leash_distance": leash},
        "hitboxes": [{"id": "leap_contact", "shape": {
            "type": "rectangle", "center": [0, 0],
            "size": [agent["attack_contact_distance"] * 2, agent["attack_vertical_reach"] * 2]}}],
        "attack_patterns": [{
            "id": "leap_bite", "display_name": "Leap bite", "kind": "leap", "clip": "attack",
            "duration": attack["duration_seconds"],
            "completion": {"mode": "duration_and_landed",
                           "min_air_seconds": _state(monster, "hop")["constants"]["MIN_AIR_SECONDS"],
                           "max_air_seconds": agent["max_air_seconds"]},
            "range": {"min": 0, "max": _stat("attack_range"), "vertical": agent["attack_vertical_reach"]},
            "cooldown": agent["attack_cooldown_seconds"],
            "damage": {"multiplier": 1, "type": "physical", "knockback": [100, -30]},
            "phases": [{"kind": "windup", "start": 0, "end": hit},
                       {"kind": "active", "start": hit, "end": attack["duration_seconds"]}],
            "events": [{"type": "ApplyImpulse", "time": hit,
                        "velocity": [agent["attack_leap_speed_scale"], -agent["attack_leap_lift"]],
                        "x_scales_move_speed": True, "mode": "set", "requires_grounded": True},
                       {"type": "EnableHitbox", "time": hit, "hitbox": "leap_contact"}],
        }],
        "behavior": {"initial_state": "idle", "states": [
            {"id": "idle", "module": "Wait", "params": {"seconds": _state(monster, "idle")["properties"]["wait_seconds"]},
             "transitions": [_go("alert", noticed, 10), _go("patrol", DONE)]},
            {"id": "patrol", "module": "Hop",
             "params": hop(toward="patrol", count=_state(monster, "patrol")["properties"]["hops_per_patrol"],
                           interval_seconds=agent["patrol_hop_interval"], speed_scale=agent["patrol_speed_scale"],
                           lift=agent["patrol_hop_lift"], patrol_radius=agent["patrol_radius"], stuck_seconds=0),
             "transitions": [_go("alert", noticed, 10), _go("idle", DONE), _go("idle", {"type": "ActionFailed"})]},
            {"id": "alert", "module": "FaceTarget", "params": {"seconds": agent["alert_seconds"]},
             "transitions": [_go("return", {"not": in_leash}, 10), _go("chase", DONE)]},
            {"id": "chase", "module": "Hop",
             "params": hop(toward="target", count=0, hold_in_attack_range=True, **chase),
             "transitions": [
                 _go("return", {"any": [{"type": "LostTarget"}, {"not": in_leash},
                                        _compare("DistanceFromOrigin", ">", leash),
                                        _compare("TargetDistance", ">", _stat("chase_range", 1.35))]}, 30),
                 _go("attack", {"type": "AttackAvailable", "pattern": "leap_bite"}, 20),
                 _go("return", {"type": "ActionFailed"})]},
            {"id": "attack", "module": "ExecuteAttackPattern", "params": {"pattern": "leap_bite"},
             "animation": {"mode": "pattern"}, "transitions": [_go("chase", {"type": "AttackPatternCompleted"})]},
            {"id": "hurt", "module": "HurtReaction", "params": {"seconds": 0.25}, "transitions": [_go("chase", DONE)]},
            {"id": "return", "module": "Hop",
             "params": hop(toward="origin", count=0, rehome_on_stuck=True,
                           arrive_distance=_state(monster, "return")["constants"]["ARRIVE_DISTANCE"], **chase),
             "transitions": [_go("idle", DONE, 20),
                             _go("alert", {"all": [in_leash,
                                                   _compare("TargetDistance", "<=", _stat("chase_range", 0.8)),
                                                   _compare("DistanceFromOrigin", "<", leash * 0.75)]}, 10),
                             _go("idle", {"type": "ActionFailed"})]},
            {"id": "dead", "module": "Death",
             "params": {"removal_seconds": _state(monster, "dead")["properties"]["removal_seconds"]}},
        ]},
    }


_ENEMIES = "res://gameplay/actors/enemies/"
IMPORT_PROFILES = {
    _ENEMIES + "enemy_agent.gd": LegacyImportProfile(
        "ground_melee",
        {"idle": _ENEMIES + "idle_state.gd", "patrol": _ENEMIES + "patrol_state.gd",
         "chase": _ENEMIES + "chase_state.gd", "attack": _ENEMIES + "attack_state.gd",
         "hurt": _ENEMIES + "hurt_state.gd", "dead": _ENEMIES + "dead_state.gd"},
        _ground_melee),
    _ENEMIES + "frog/frog_agent.gd": LegacyImportProfile(
        "hopper",
        {"idle": _ENEMIES + "frog/frog_idle_state.gd", "patrol": _ENEMIES + "frog/frog_patrol_state.gd",
         "alert": _ENEMIES + "frog/frog_alert_state.gd", "chase": _ENEMIES + "frog/frog_chase_state.gd",
         "prepare": _ENEMIES + "frog/frog_prepare_state.gd", "hop": _ENEMIES + "frog/frog_hop_state.gd",
         "attack": _ENEMIES + "frog/frog_attack_state.gd", "hurt": _ENEMIES + "hurt_state.gd",
         "return": _ENEMIES + "frog/frog_return_state.gd", "dead": _ENEMIES + "dead_state.gd"},
        _hopper, folded_states=("prepare", "hop"),
        unsupported=(
            {"path": "attack_patterns[leap_bite].events[EnableHitbox]",
             "reason": "FrogAttackState tests the target's origin against |dx| <= 44 and |dy| <= 40 on every tick of "
                       "the leap. The 88x80 hitbox tests the target's hurtbox instead, which reaches further."},
            {"path": "behavior.states[return].params",
             "reason": "FrogReturnState switches to the short patrol hop (0.6 x speed, lift 230) once the origin is "
                       "closer than one chase hop. The Hop module has one speed and lift per state."})),
}


def register_import_profile(agent_script, profile):
    """Add a profile for another legacy actor script. Existing profiles are never replaced silently."""
    if agent_script in IMPORT_PROFILES:
        raise ValueError(f"an import profile for {agent_script} already exists")
    IMPORT_PROFILES[agent_script] = profile


def import_support(agent_script):
    """``complete`` / ``partial`` (a profile exists but lists unsupported parts) / ``unsupported``."""
    profile = IMPORT_PROFILES.get(agent_script)
    if profile is None:
        return UNSUPPORTED
    return PARTIAL if profile.unsupported else COMPLETE


def _image_id(path, used):
    stem = re.sub(r"[^a-z0-9_]", "_", PurePosixPath(path).stem.lower()) or "image"
    if not re.fullmatch(ID_PATTERN, stem):
        stem = ("i_" + stem)[:64]
    candidate, index = stem, 2
    while candidate in used:
        candidate, index = f"{stem[:60]}_{index}", index + 1
    return candidate


def _common(monster_id, monster, environment, project, notes):
    """The sections every enemy has. Returns ``(document data, source paths)``."""
    base = new_document(monster_id, monster.get("display_name") or monster_id).to_dict()
    data = {"monster_id": monster_id, "metadata": {"display_name": monster.get("display_name") or monster_id}}
    data["stats"] = {key: monster[key] for key in ("max_health", "attack_damage", "move_speed", "chase_range",
                                                    "attack_range", "faction")}
    if "invulnerability_seconds" in monster:
        data["stats"]["hit_invulnerability_seconds"] = monster["invulnerability_seconds"]
    data["movement"] = {"gravity": environment["gravity"]}
    data["sensors"] = {"target_keep_scale": environment["target_keep_range_scale"]}
    sources = [res(monster["definition_path"]), res(monster.get("actor_scene_path")), res(monster.get("agent_script"))]

    # Collision. The body is mandatory in the schema, so a monster without a usable one cannot be imported.
    bodies = monster.get("body") or []
    if len(bodies) != 1 or bodies[0]["class"] not in SHAPES:
        raise ImportError_("unsupported_body", "the actor needs exactly one rectangle or circle body shape; found "
                           + (", ".join(row["class"] for row in bodies) or "none"))
    data["collision"] = {"body": {"shape": SHAPES[bodies[0]["class"]](bodies[0]),
                                  "layer": monster["collision_layer"], "mask": monster["collision_mask"]},
                         "hurtboxes": []}
    for index, row in enumerate((monster.get("hurtbox") or {}).get("shapes", [])):
        if row["class"] not in SHAPES:
            notes.append({"path": f"collision.hurtboxes[{index}]",
                          "reason": f"hurtbox shape {row['class']} is not supported by Schema V1 and was left out"})
            continue
        data["collision"]["hurtboxes"].append({"id": "body" if index == 0 else f"hurtbox_{index + 1}",
                                               "shape": SHAPES[row["class"]](row), "enabled": not row["disabled"]})

    # Animation profile and clips.
    profile = monster.get("profile")
    passthrough = {}
    binding = {"animation_profile_path": "", "sprite_frames_path": ""}
    if profile and "error" not in profile:
        binding["animation_profile_path"] = res(monster["animation_profile_path"])
        binding["sprite_frames_path"] = res(profile["sprite_frames_path"])
        sources += [binding["animation_profile_path"], binding["sprite_frames_path"]]
        data["presentation"] = {key: profile[key] for key in (
            "faces_right_by_default", "visual_scale", "visual_offset", "attack_hit_frame", "airborne_speed",
            "move_speed_threshold")}
        data["presentation"]["roles"] = {role: profile["roles"].get(role, "") for role in ROLES}
        if profile.get("texture_filter", -1) >= 0:
            passthrough["profile_texture_filter"] = profile["texture_filter"]
        images, clips = {}, []
        for clip_id, clip in profile["animations"].items():
            frames = []
            for frame in clip["frames"]:
                path = res(frame.get("texture_path"))
                if path not in images:
                    width, height, digest = inspect_image(project, path)
                    images[path] = {"id": _image_id(path, {row["id"] for row in images.values()}), "path": path,
                                    "width": width, "height": height, "sha256": digest}
                frames.append({"image": images[path]["id"], "rect": [round(value) for value in frame["region"]],
                               "duration": frame["duration"]})
            clips.append({"id": clip_id, "fps": clip["fps"], "loop": clip["loop"], "frames": frames})
        data["assets"] = {"images": list(images.values())}
        data["animations"] = {"clips": clips}
    elif monster.get("animation_profile_path"):
        notes.append({"path": "presentation", "reason": "the animation profile could not be loaded: "
                      + str((profile or {}).get("error", "missing"))})

    # Loot.
    loot = monster.get("loot")
    data["loot"] = {"loot_table_id": monster.get("loot_table_id", "")}
    binding["loot_table_path"] = ""
    if loot:
        data["loot"].update(entries=[{"item_id": item, "weight": weight, "min_amount": low, "max_amount": high}
                                     for item, weight, low, high in zip(loot["item_ids"], loot["weights"],
                                                                         loot["min_amounts"], loot["max_amounts"])],
                            apply_difficulty_multiplier=loot["apply_difficulty_multiplier"])
        binding["loot_table_path"] = res(loot["path"])
        sources.append(binding["loot_table_path"])
    data["behavior"] = base["behavior"]
    data["source_binding"] = {"runtime": "legacy", "definition_path": res(monster["definition_path"]),
                              "actor_scene_path": res(monster.get("actor_scene_path")), **binding,
                              "editability": dict(LEGACY_EDITABILITY), "passthrough": passthrough}
    sources += [res(row["script"]) for row in monster.get("states", [])]
    return data, [path for path in sources if path]


def build_document(monster_id, monster, environment, project):
    """Convert one probed monster. Raises ImportError_ / DocumentError when no valid document can be made."""
    if not monster.get("agent_script"):
        raise ImportError_("no_actor", "the monster has no actor scene whose root is an EnemyAgent")
    notes = []
    data, sources = _common(monster_id, monster, environment, project, notes)
    profile = IMPORT_PROFILES.get(monster["agent_script"])
    binding = data["source_binding"]
    used = ""
    if profile is not None:
        found = {row["id"]: row["script"] for row in monster.get("states", [])}
        if found != profile.states:
            changed = sorted(set(found.items()) ^ set(profile.states.items()))
            notes.append({"path": "behavior", "reason": "the actor's states differ from the ones the '"
                          + profile.name + "' import profile was written for: "
                          + ", ".join(sorted({name for name, _ in changed}))})
            profile = None
    if profile is not None:
        try:
            built = profile.build(monster)
        except (KeyError, StopIteration, TypeError) as error:
            notes.append({"path": "behavior", "reason": f"the '{profile.name}' import profile could not read the "
                          f"actor ({type(error).__name__}: {error})"})
            profile = None
    if profile is not None:
        used = profile.name
        data["movement"].update(built.get("movement", {}))
        data["sensors"].update(built.get("sensors", {}))
        data["collision"]["hitboxes"] = built.get("hitboxes", [])
        data["attack_patterns"] = built["attack_patterns"]
        data["behavior"] = built["behavior"]
        if profile.folded_states:
            binding["passthrough"]["folded_states"] = list(profile.folded_states)
        notes.extend(dict(row) for row in profile.unsupported)
        sources += list(BASE_SOURCES)
    else:
        # No behaviour was converted. The placeholder states only keep the document well-formed.
        notes.append({"path": "behavior", "reason": "the behaviour of actor script " + monster["agent_script"]
                      + " was not imported; the states in this document are a placeholder, not the monster's AI"})
        notes.append({"path": "attack_patterns", "reason": "attacks were not imported"})
        binding["editability"].update(behavior="unsupported", attack_patterns="unsupported")
        sources += list(BASE_SOURCES)
    binding["unsupported"] = notes
    files = []
    for relative in sorted(set(sources)):
        try:
            path = resolve_project_file(project, relative, SOURCE_SUFFIXES, MAX_IMAGE_BYTES)
        except (OSError, DocumentError):
            continue
        files.append({"path": relative, "sha256": file_sha256(path)})
    binding["files"] = files
    document = MonsterDocument(data)
    status = UNSUPPORTED if not used else (PARTIAL if notes else COMPLETE)
    return ImportResult(document, status, [f"{row['path']}: {row['reason']}" for row in notes], used)


def project_fingerprint(project, document):
    """Hashes of the game files a document was imported from, to prove an import changed none of them."""
    root = Path(project)
    return {row["path"]: file_sha256(root / row["path"]) for row in document.data["source_binding"]["files"]}
