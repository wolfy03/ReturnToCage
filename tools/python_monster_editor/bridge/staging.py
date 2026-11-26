"""Stage a monster's presentation in a copy of the project and check what Godot built. No Qt.

``stage_presentation`` is the whole MONSTER-STEP 3 export path:

1. copy the project into a fresh staging folder and mark the copy;
2. let Godot import the copy (new PNGs become textures);
3. run the bridge's ``stage_monster`` there: Godot builds a ``SpriteFrames`` and an
   ``EnemyAnimationProfile`` with ``ResourceSaver``, reads them back, and readies a registered enemy actor
   with the profile;
4. compare the readback with the document, field by field.

The real project is never written: the copy is made first, the bridge refuses a project without the
staging marker, and this module refuses to stage into a folder inside the project. Python assembles no
``.tres`` text - every resource is created by the engine.

A stage that differs from the document is not an exception: ``StageResult.differences`` lists what
differs and ``passed`` is False. Exceptions (``BridgeError``) are for runs that produced no result.
"""

from dataclasses import dataclass, field
from pathlib import Path
import shutil
import tempfile

from . import client
from .client import BridgeError

MARKER = ".rtc_monster_staging"
# Top-level entries that Godot does not need to load the game. ``.godot`` is copied: it holds the import
# cache, and without it every staging would re-import the whole project.
NOT_COPIED = (".git", ".github", ".claude", "build", "docs", "devtools")
IGNORED_NAMES = ("__pycache__", ".pytest_cache", "*.pyc", "*.tmp")
STAGE_FAILED, STAGING_INSIDE_PROJECT, NOTHING_TO_STAGE = "STAGE_FAILED", "STAGING_INSIDE_PROJECT", "NOTHING_TO_STAGE"
IMPORT_TIMEOUT = 600
TOLERANCE = 1e-4


@dataclass(frozen=True)
class StageResult:
    monster_id: str
    staging_root: Path              # the project copy; the caller removes it when done
    sprite_frames_path: str         # res:// paths inside the copy
    profile_path: str
    differences: tuple              # human-readable lines; empty when the stage matches the document
    profile: dict = field(default_factory=dict)      # Godot's readback
    attach: dict = field(default_factory=dict)       # what a carrier actor did with the profile
    attempts: int = 1
    seconds: float = 0.0

    @property
    def passed(self):
        return not self.differences


def stage_request(document, carrier=""):
    """The ``stage`` payload for a document: plain data, nothing but what the engine needs."""
    data = document.data
    binding = data["source_binding"] or {}
    request = {
        "images": {row["id"]: row["path"] for row in data["assets"]["images"]},
        "clips": [{"id": clip["id"], "fps": clip["fps"], "loop": clip["loop"],
                   "frames": [{"image": frame["image"],
                               "rect": list(frame["rect"]) if frame["rect"] is not None else None,
                               "duration": frame["duration"]} for frame in clip["frames"]]}
                  for clip in data["animations"]["clips"]],
        "presentation": {key: (list(value) if isinstance(value, (list, tuple)) else
                               dict(value) if key == "roles" else value)
                         for key, value in data["presentation"].items()},
        "carrier": carrier,
    }
    # Schema V1 has no field for the sprite filter. An imported document keeps the profile's value in its
    # binding; it is passed on so staging an imported monster does not lose it.
    filter_value = (binding.get("passthrough") or {}).get("profile_texture_filter")
    if isinstance(filter_value, int) and not isinstance(filter_value, bool) and filter_value >= 0:
        request["texture_filter"] = filter_value
    return request


def make_staging_copy(project, work_folder=None):
    """Copy the project into a new folder and mark it. Returns the copy's root.

    The copy never lands inside the project: a staging tree there would be scanned by Godot as part of
    the real game.
    """
    project = Path(project).resolve()
    if not (project / "project.godot").is_file():
        raise BridgeError(client.PROJECT_INVALID, f"not a Godot project: {project}")
    parent = Path(tempfile.mkdtemp(prefix="rtc-monster-stage-", dir=work_folder)).resolve()
    if parent == project or project in parent.parents:
        shutil.rmtree(parent, ignore_errors=True)
        raise BridgeError(STAGING_INSIDE_PROJECT, "the staging folder must be outside the project")
    target = parent / "project"

    def ignore(folder, names):
        skipped = set(shutil.ignore_patterns(*IGNORED_NAMES)(folder, names))
        if Path(folder).resolve() == project:
            skipped.update(name for name in names if name in NOT_COPIED)
        return skipped

    try:
        shutil.copytree(project, target, ignore=ignore, symlinks=False)
        (target / MARKER).write_text("staging copy made by the Monster Editor; safe to delete\n", encoding="utf-8")
    except OSError as error:
        shutil.rmtree(parent, ignore_errors=True)
        raise BridgeError(STAGE_FAILED, f"cannot copy the project: {error}") from error
    return target


def remove_staging_copy(staging_root):
    """Delete a copy made by ``make_staging_copy``. Refuses anything that does not carry the marker."""
    staging_root = Path(staging_root)
    if not (staging_root / MARKER).is_file() or staging_root.name != "project":
        raise BridgeError(STAGE_FAILED, f"not a staging copy: {staging_root}")
    shutil.rmtree(staging_root.parent, ignore_errors=True)


def import_assets(godot, staging_root, cancel=None, timeout=IMPORT_TIMEOUT):
    """Let the editor import the copy's assets. Returns the engine log."""
    code, log = client._run([str(godot), "--headless", "--path", str(staging_root), "--import"], staging_root,
                            cancel, timeout)
    if cancel is not None and cancel.is_set():
        raise BridgeError(client.CANCELLED, "the operation was cancelled", log)
    if code < 0 or code > 255:
        raise BridgeError(client.PROCESS_CRASH, f"Godot crashed while importing (exit {code}, 0x{code & 0xffffffff:08X})", log)
    if code != 0:
        raise BridgeError(STAGE_FAILED, f"Godot could not import the staging copy (exit {code})", log)
    return log


def _close(first, second):
    return abs(float(first) - float(second)) <= TOLERANCE


def _same_numbers(first, second):
    return len(first) == len(second) and all(_close(a, b) for a, b in zip(first, second))


def compare(document, profile, attach=None):
    """Lines describing where Godot's readback differs from the document. Empty means equal."""
    data = document.data
    presentation = data["presentation"]
    lines = []
    if not isinstance(profile, dict) or "animations" not in profile:
        return [f"Godot returned no profile readback: {profile.get('error') if isinstance(profile, dict) else profile!r}"]
    lines += [f"EnemyAnimationProfile.validation_errors: {error}" for error in profile.get("errors", [])]
    images = {row["id"]: row for row in data["assets"]["images"]}
    built = profile["animations"]
    wanted = {clip["id"]: clip for clip in data["animations"]["clips"]}
    for name in sorted(set(wanted) ^ set(built)):
        lines.append(f"clip {name}: {'missing from' if name in wanted else 'unexpected in'} the SpriteFrames")
    for name in sorted(set(wanted) & set(built)):
        clip, animation = wanted[name], built[name]
        if not _close(clip["fps"], animation["fps"]):
            lines.append(f"clip {name}: fps {animation['fps']} != {clip['fps']}")
        if bool(clip["loop"]) != bool(animation["loop"]):
            lines.append(f"clip {name}: loop {animation['loop']} != {clip['loop']}")
        if len(clip["frames"]) != len(animation["frames"]):
            lines.append(f"clip {name}: {len(animation['frames'])} frames != {len(clip['frames'])}")
            continue
        for index, (frame, row) in enumerate(zip(clip["frames"], animation["frames"])):
            image = images.get(frame["image"])
            if image is None:
                lines.append(f"clip {name} frame {index}: image {frame['image']} is not registered")
                continue
            rect = list(frame["rect"]) if frame["rect"] is not None else [0, 0, image["width"], image["height"]]
            if row.get("texture_path") != "res://" + image["path"]:
                lines.append(f"clip {name} frame {index}: texture {row.get('texture_path')} != res://{image['path']}")
            if not _same_numbers(row.get("region", []), rect):
                lines.append(f"clip {name} frame {index}: region {row.get('region')} != {rect}")
            if not _close(row.get("duration", 0), frame["duration"]):
                lines.append(f"clip {name} frame {index}: duration {row.get('duration')} != {frame['duration']}")
    for role, clip_id in presentation["roles"].items():
        if profile["roles"].get(role) != clip_id:
            lines.append(f"role {role}: {profile['roles'].get(role)!r} != {clip_id!r}")
    for key in ("visual_scale", "visual_offset"):
        if not _same_numbers(profile.get(key, []), presentation[key]):
            lines.append(f"{key}: {profile.get(key)} != {list(presentation[key])}")
    for key in ("attack_hit_frame", "airborne_speed", "move_speed_threshold"):
        if not _close(profile.get(key, float("nan")), presentation[key]):
            lines.append(f"{key}: {profile.get(key)} != {presentation[key]}")
    if profile.get("faces_right_by_default") != presentation["faces_right_by_default"]:
        lines.append(f"faces_right_by_default: {profile.get('faces_right_by_default')} != "
                     f"{presentation['faces_right_by_default']}")
    if attach is not None:
        lines += compare_attach(document, profile, attach)
    return lines


def compare_attach(document, profile, attach):
    """Lines describing what went wrong when a carrier actor used the staged profile."""
    presentation = document.data["presentation"]
    if not attach.get("evaluated"):
        return [f"attach check not run: {attach.get('reason', 'unknown reason')}"]
    lines = []
    shown, server = attach.get("presentation", {}), attach.get("server", {})
    if not shown.get("has_presenter"):
        lines.append(f"carrier {attach.get('carrier')}: the actor built no animation presenter from the staged profile")
    else:
        if shown.get("sprite_frames_path") != profile.get("sprite_frames_path"):
            lines.append(f"carrier sprite uses {shown.get('sprite_frames_path')}, not the staged SpriteFrames")
        if not shown.get("frame_has_texture"):
            lines.append(f"carrier sprite has no texture for its first '{shown.get('animation')}' frame")
        if shown.get("animation") != presentation["roles"]["idle"]:
            lines.append(f"carrier sprite starts on {shown.get('animation')!r}, not the idle clip")
        if not _same_numbers(shown.get("sprite_position", []), presentation["visual_offset"]):
            lines.append(f"carrier sprite position {shown.get('sprite_position')} != visual_offset")
        scale = shown.get("presenter_scale", [])
        if len(scale) != 2 or not _close(abs(scale[0]), presentation["visual_scale"][0]) \
                or not _close(scale[1], presentation["visual_scale"][1]):
            lines.append(f"carrier presenter scale {scale} != visual_scale")
    if server.get("has_presenter"):
        lines.append("the server-runtime actor built a presenter; it must not load any visual")
    return lines


def stage_presentation(godot, project, document, work_folder=None, carrier="", cancel=None,
                       timeout=client.DEFAULT_TIMEOUT, keep_on_failure=False):
    """Build the document's presentation in a staging copy and return a ``StageResult``.

    The caller owns the returned copy and removes it with ``remove_staging_copy``. When the run raises,
    the copy is removed here, so a failed stage leaves nothing behind. ``keep_on_failure`` keeps it for
    inspection instead and names its path in the error; a cancelled run never keeps one.
    """
    if not document.data["animations"]["clips"]:
        raise BridgeError(NOTHING_TO_STAGE, "the document has no animation clips")
    client.check_version(godot, project, cancel)
    staging_root = make_staging_copy(project, work_folder)
    try:
        import_assets(godot, staging_root, cancel)
        response = client.call(godot, staging_root, "stage_monster", document.data["monster_id"], cancel, timeout,
                               work_folder, stage=stage_request(document, carrier))
    except BridgeError as error:
        if keep_on_failure and error.code != client.CANCELLED:
            raise BridgeError(error.code, f"{error.detail} (staging copy kept: {staging_root})", error.log) from error
        remove_staging_copy(staging_root)
        raise
    data = response.data
    for key in ("sprite_frames_path", "profile_path", "profile", "attach"):
        if key not in data:
            remove_staging_copy(staging_root)
            raise BridgeError(client.INVALID_RESPONSE, f"stage response has no {key}", response.log)
    for key in ("sprite_frames_path", "profile_path"):
        relative = str(data[key]).removeprefix("res://")
        if not (staging_root / relative).is_file():
            remove_staging_copy(staging_root)
            raise BridgeError(STAGE_FAILED, f"Godot reported {data[key]} but the file does not exist", response.log)
    return StageResult(document.data["monster_id"], staging_root, data["sprite_frames_path"], data["profile_path"],
                       tuple(compare(document, data["profile"], data["attach"])), data["profile"], data["attach"],
                       response.attempts, response.seconds)
