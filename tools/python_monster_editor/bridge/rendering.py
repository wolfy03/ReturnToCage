"""Have the real Godot renderer draw a staged monster, and say where it should have drawn it. No Qt.

``render_staged`` runs ``tools/monster_bridge/render_check.tscn`` in a staging copy **without**
``--headless``: a registered enemy actor is readied with the staged ``EnemyAnimationProfile`` and each
requested clip frame is drawn into an off-screen viewport and saved as a PNG. The scene also reports,
from the scene tree, where the frame's four corners ended up on that image, which clip the real
``EnemyAnimationPresenter`` picks per state, the sprite's texture filter, and which frame
``AnimatedSprite2D`` showed after how long while really playing.

This module computes the *expected* answers from the document with the same ``rtcmonster.geometry`` and
``rtcmonster.timing`` the preview canvas uses, and compares. Comparing the pixels themselves needs an
image library and lives in ``gui/render_compare.py``.

A machine without a usable renderer answers ``NO_RENDERER`` (or fails to start); callers report that as
NOT_EVALUATED. A headless structure check is never offered in its place.
"""

from dataclasses import dataclass, field
import json
from pathlib import Path
import re
import tempfile
import time
import uuid

from rtcmonster.geometry import sprite_to_actor
from rtcmonster.timing import clip_seconds, frame_at

from . import client
from .client import BridgeError

RENDER_SCENE = "res://tools/monster_bridge/render_check.tscn"
# The render scene is this tool's own: any engine error line while it runs is a defect of the check.
RENDER_ERRORS = re.compile(r"(?:^|\n)ERROR:", re.I)
NO_RENDERER = "NO_RENDERER"
DEFAULT_SIZE = (320, 240)
DEFAULT_ZOOM = 3
CORNER_TOLERANCE = 0.01          # pixels; these are transforms of exact numbers, not sampled pixels
# Roles the scene can force on the real presenter. jump_start and land depend on timers inside the
# presenter (a crouch before a hop, a settle time after touching down) and are not forced.
FORCED_ROLES = ("idle", "move", "attack", "hurt", "death", "jump", "fall")
UNFORCED_ROLES = ("jump_start", "land")


@dataclass(frozen=True)
class RenderResult:
    monster_id: str
    data: dict                    # the scene's answer: shots, timings, role_selection, texture_filter ...
    renderer: dict                # display server, rendering method and driver, video adapter
    output_dir: Path              # where the PNGs are
    differences: tuple            # geometry, role, filter and timing lines; empty when all agree
    log: str = ""
    seconds: float = 0.0
    notes: tuple = field(default_factory=tuple)
    crashes: tuple = ()           # exit codes of attempts that crashed and were run again

    @property
    def passed(self):
        return not self.differences


def clip_of(document, clip_id):
    return next((clip for clip in document.data["animations"]["clips"] if clip["id"] == clip_id), None)


def frame_size(document, clip, index):
    frame = clip["frames"][index]
    if frame["rect"] is not None:
        return frame["rect"][2], frame["rect"][3]
    image = next(row for row in document.data["assets"]["images"] if row["id"] == frame["image"])
    return image["width"], image["height"]


def default_shots(document, shapes=None, frames_per_clip=2):
    """Both facings of the first and a middle frame of every clip.

    ``shapes(clip_id, frame)`` may return ``[{"kind", "id", "shape"}]`` to be drawn over a second
    screenshot of the same frame.
    """
    shots = []
    for clip in document.data["animations"]["clips"]:
        count = len(clip["frames"])
        chosen = sorted({0, count // 2} if frames_per_clip > 1 else {0})
        for index in chosen:
            for facing, side in ((1, "right"), (-1, "left")):
                shot = {"name": f"{clip['id']}_f{index}_{side}", "clip": clip["id"], "frame": index, "facing": facing}
                if shapes is not None:
                    shot["shapes"] = shapes(clip["id"], index)
                shots.append(shot)
    return shots


def default_timings(document, limit=3.0):
    """One real playback per clip: a little past its end for a one-shot clip, into the second pass of a loop."""
    rows = []
    for clip in document.data["animations"]["clips"]:
        seconds = clip_seconds(clip)
        rows.append({"clip": clip["id"], "seconds": round(min(limit, seconds * (1.6 if clip["loop"] else 1.3) + 0.1), 3)})
    return rows


def expected_corners(document, clip_id, frame, facing, size, zoom):
    """Where the frame's corners should be on the screenshot: top-left, top-right, bottom-right, bottom-left
    *of the frame* (so a mirrored frame has its "left" corners on the right of the image)."""
    clip = clip_of(document, clip_id)
    extent = frame_size(document, clip, frame)
    presentation = document.data["presentation"]
    corners = []
    for x, y in ((0, 0), (extent[0], 0), (extent[0], extent[1]), (0, extent[1])):
        point = sprite_to_actor([x, y], extent, presentation, facing)
        corners.append([size[0] / 2 + point[0] * zoom, size[1] / 2 + point[1] * zoom])
    return corners


def compare_geometry(document, data):
    """Lines where the scene tree's frame placement differs from ``rtcmonster.geometry``'s."""
    lines = []
    size, zoom = data["size"], data["zoom"]
    images = {row["id"]: row for row in document.data["assets"]["images"]}
    for shot in data["shots"]:
        name = shot["name"]
        if shot.get("error"):
            lines.append(f"{name}: {shot['error']}")
            continue
        if not shot.get("saved"):
            lines.append(f"{name}: the screenshot was not saved")
        clip = clip_of(document, shot["clip"])
        frame = clip["frames"][shot["frame"]]
        image = images[frame["image"]]
        rect = list(frame["rect"]) if frame["rect"] is not None else [0, 0, image["width"], image["height"]]
        if [round(value) for value in shot["region"]] != rect or shot["texture_path"] != "res://" + image["path"]:
            lines.append(f"{name}: drawn from {shot['texture_path']} {shot['region']}, not res://{image['path']} {rect}")
        expected = expected_corners(document, shot["clip"], shot["frame"], shot["facing"], size, zoom)
        worst = max(abs(a - b) for got, want in zip(shot["corners"], expected) for a, b in zip(got, want))
        if worst > CORNER_TOLERANCE:
            lines.append(f"{name}: the frame is drawn at {shot['corners']}, the document places it at {expected} "
                         f"(off by {worst:.3f} px)")
    return lines


def compare_roles(document, selection):
    """``(differences, not_evaluated)`` for the clip the real presenter picked per forced state.

    A role without a clip is not an error here: the presenter then falls back (an airborne monster with
    no jump clip keeps its idle or move clip), and that fallback is what is compared.
    """
    roles = document.data["presentation"]["roles"]
    lines = []
    for role in FORCED_ROLES:
        if role not in selection:
            continue
        expected = roles[role]
        if not expected and role in ("jump", "fall"):
            expected = roles["idle"]                   # no airborne clip: drawn as a grounded, standing actor
        if expected and selection[role] != expected:
            lines.append(f"role {role}: the presenter shows {selection[role]!r}, the document binds {expected!r}")
    return lines, [role for role in UNFORCED_ROLES if roles[role]]


def compare_filter(document, data):
    from .staging import texture_filter_of
    expected, source = texture_filter_of(document)
    lines = []
    for key in ("profile_texture_filter", "texture_filter"):
        if data.get(key) != expected:
            lines.append(f"{key}: {data.get(key)} != {expected} ({source})")
    return lines


def compare_timing(document, timings):
    """Lines where real playback showed a frame the document's timing rule does not allow at that time.

    Each sample is ``[elapsed seconds, frame, playing]`` taken once per rendered frame. The scene's clock
    and the sprite's own are advanced by the same steps but not at the same moment within a frame (the
    sprite may already have consumed the step in which playback was started, or not yet the current one),
    so a sample may show the frame of any instant within one step either side of it. Anything outside that
    window is a difference. A one-shot clip must end on its last frame and stop.
    """
    lines = []
    for row in timings:
        clip = clip_of(document, row["clip"])
        if row.get("error") or clip is None:
            lines.append(f"timing {row['clip']}: {row.get('error', 'not a clip of the document')}")
            continue
        slack = row["largest_delta"] + 1e-4
        wrong = []
        for elapsed, frame, _playing in row["samples"]:
            # Every frame the window touches is allowed (it may span a short frame entirely).
            steps = 8
            allowed = {frame_at(clip, max(0.0, elapsed + slack * part / steps)) for part in range(-steps, steps + 1)}
            if frame not in allowed:
                wrong.append((round(elapsed, 4), frame, sorted(allowed)))
        if wrong:
            lines.append(f"timing {row['clip']}: {len(wrong)} of {len(row['samples'])} samples show a frame the "
                         f"document's timing does not allow, first: t={wrong[0][0]} s frame {wrong[0][1]} "
                         f"(allowed {wrong[0][2]})")
        if not row["samples"]:
            lines.append(f"timing {row['clip']}: no samples")
            continue
        last_elapsed, last_frame, last_playing = row["samples"][-1]
        if bool(row["loop"]) != bool(clip["loop"]):
            lines.append(f"timing {row['clip']}: the SpriteFrames loop flag is {row['loop']}, the document says {clip['loop']}")
        if not clip["loop"] and last_elapsed > clip_seconds(clip) + slack:
            if last_frame != len(clip["frames"]) - 1 or last_playing:
                lines.append(f"timing {row['clip']}: a one-shot clip must hold its last frame and stop; "
                             f"after {last_elapsed:.3f} s it shows frame {last_frame}, playing={last_playing}")
        if clip["loop"] and last_elapsed > clip_seconds(clip) + slack and not last_playing:
            lines.append(f"timing {row['clip']}: a looping clip stopped")
    return lines


def render_staged(godot, session, document, output_dir, shots=None, timings=None, carrier="", size=DEFAULT_SIZE,
                  zoom=DEFAULT_ZOOM, cancel=None, timeout=client.DEFAULT_TIMEOUT, rendering_method=""):
    """Draw a staged document's frames with the real renderer and compare placement, roles, filter and timing.

    ``session`` is the ``StagingSession`` the document was staged in (``stage_presentation(..., keep=True)``).
    Raises ``BridgeError``: ``NO_RENDERER`` when the engine has no renderer here, the usual codes otherwise.
    """
    started = time.monotonic()
    # A run that crashes is repeated: it reads the staged resources and writes only screenshots, which the
    # next attempt overwrites. The crashes stay on the result.
    result, crashes, _log = client.retry_crashes(
        lambda: _render_once(godot, session, document, output_dir, shots, timings, carrier, size, zoom, cancel,
                             timeout, rendering_method), cancel)
    from dataclasses import replace
    return replace(result, crashes=crashes, seconds=time.monotonic() - started)


def _render_once(godot, session, document, output_dir, shots, timings, carrier, size, zoom, cancel, timeout,
                 rendering_method):
    output_dir = Path(output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    monster_id = document.data["monster_id"]
    request_id = uuid.uuid4().hex
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="rtc-monster-render-") as folder:
        request_path, result_path = Path(folder) / "request.json", Path(folder) / "result.json"
        request = {"protocol": client.PROTOCOL, "request_id": request_id, "result_path": str(result_path),
                   "staging_session": session.id, "monster_id": monster_id, "carrier": carrier,
                   "output_dir": str(output_dir), "size": list(size), "zoom": zoom,
                   "shots": shots if shots is not None else default_shots(document),
                   "timings": timings if timings is not None else default_timings(document)}
        request_path.write_text(json.dumps(request), encoding="utf-8")
        # No sound is played; without this a machine with no audio device (a CI runner) logs audio driver
        # errors, and this check treats any engine error line of its own scene as a failure.
        command = [str(godot), "--path", str(session.root), "--windowed", "--resolution", "320x180",
                   "--audio-driver", "Dummy"]
        if rendering_method:
            command += ["--rendering-method", rendering_method]
        command += [RENDER_SCENE, "--", "--request", str(request_path)]
        code, log = client._run(command, session.root, cancel, timeout)
        if cancel is not None and cancel.is_set():
            raise BridgeError(client.CANCELLED, "the operation was cancelled", log)
        if code < 0 or code > 255:
            raise BridgeError(client.PROCESS_CRASH, f"Godot crashed (exit {code}, 0x{code & 0xffffffff:08X})", log, code)
        if client.ENGINE_ERRORS.search(log) or RENDER_ERRORS.search(log):
            raise BridgeError(client.ENGINE_ERROR, "Godot reported errors while rendering", log)
        result = client._read_result(result_path, code, log)
    if result.get("request_id") != request_id or result.get("operation") != "render_check" \
            or result.get("protocol") != client.PROTOCOL:
        raise BridgeError(client.RESPONSE_MISMATCH, "the render check answered another request", log)
    answered = result.get("project_path")
    if not isinstance(answered, str) or Path(answered).resolve() != Path(session.root).resolve():
        raise BridgeError(client.RESPONSE_MISMATCH, f"the render check ran in another project: {answered!r}", log)
    if result.get("status") != "PASS" or code != 0:
        name = result.get("error_code") or client.ENGINE_ERROR
        raise BridgeError(name if isinstance(name, str) else client.ENGINE_ERROR,
                          str(result.get("message") or f"exit {code}"), log)
    data, renderer = result.get("data"), result.get("renderer")
    if not isinstance(data, dict) or not isinstance(renderer, dict) or not isinstance(data.get("shots"), list) \
            or data.get("staging_session") != session.id or data.get("monster_id") != monster_id:
        raise BridgeError(client.INVALID_RESPONSE, "the render check answer is malformed or about another stage", log)
    if renderer.get("display_server") == "headless":
        raise BridgeError(NO_RENDERER, "the engine had no renderer", log)
    for shot in data["shots"]:
        if not isinstance(shot, dict) or not isinstance(shot.get("name"), str):
            raise BridgeError(client.INVALID_RESPONSE, "a shot in the render check answer is malformed", log)
        if shot.get("error"):
            continue
        if not all(isinstance(shot.get(key), list) for key in ("corners", "region", "frame_size")) or len(shot["corners"]) != 4:
            raise BridgeError(client.INVALID_RESPONSE, f"shot {shot['name']} has no placement", log)
        for key in ("image", "overlay_image"):
            if key in shot and (Path(shot[key]).name != shot[key] or not (output_dir / shot[key]).is_file()):
                raise BridgeError(client.INVALID_RESPONSE, f"shot {shot['name']} names a file that was not written", log)
    differences = compare_geometry(document, data) + compare_filter(document, data)
    role_lines, unforced = compare_roles(document, data.get("role_selection") or {})
    differences += role_lines + compare_timing(document, data.get("timings") or [])
    notes = tuple(f"role {role}: bound to a clip, but the presenter shows it only through its own timers; "
                  "not forced by this check" for role in unforced)
    return RenderResult(monster_id, data, renderer, output_dir, tuple(differences), log,
                        time.monotonic() - started, notes)
