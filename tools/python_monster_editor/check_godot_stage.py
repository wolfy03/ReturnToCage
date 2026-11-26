"""Stage monster presentations with the real engine and check what it built (MONSTER-STEP 3).

    python tools/python_monster_editor/check_godot_stage.py --godot <godot> [--artifacts <dir>] [--carrier <id>]

For each example that has clips, and for a draft assembled here with the editor's own helpers:

* copy the project, import it, and run the bridge's ``stage_monster`` in the copy;
* Godot builds a SpriteFrames and an EnemyAnimationProfile and readies a registered enemy actor with the
  profile - once for presentation and once the way the server runtime creates it;
* a second Godot process reads the two files back from disk;
* that readback must equal the document (clips, frames, regions, durations, roles, scale, offset, facing,
  hit frame, texture filter), ``EnemyAnimationProfile.validation_errors()`` must be empty, the staged
  images must be the files the document recorded, the carrier must draw from the staged resources with
  the profile's filter, and the server-side actor must build no visual.

Then the safety checks: the bridge refuses the real project, a request from another staging session and
malformed requests with a code instead of a script error; an image that changed since the document was
written is reported; every staging copy is gone afterwards; and the real project - every file of it
outside the engine's own cache - is byte-for-byte unchanged by the whole run.

What this does not check: how anything looks on screen (``check_godot_render.py``), and any combat,
network or publishing behaviour, which MONSTER-STEP 3 does not have.
"""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import time

TOOL = Path(__file__).resolve().parent
PROJECT = TOOL.parents[1]
sys.path.insert(0, str(TOOL))

from application import animation  # noqa: E402
from bridge import client, staging  # noqa: E402
from bridge.client import BridgeError  # noqa: E402
from bridge.staging import StagingSession  # noqa: E402
from rtcmonster import new_document, read_document, set_value  # noqa: E402

EXAMPLES = TOOL / "examples"
# Everything except what Godot itself rewrites while it runs (.godot) and what is not the game (.git, ...).
UNWATCHED = {".git", ".godot", ".claude", "__pycache__", ".pytest_cache"}


def manifest(project):
    """Content hashes of every project file a stage could conceivably touch."""
    rows = {}
    pending = [Path(project)]
    while pending:
        folder = pending.pop()
        for item in folder.iterdir():
            if item.name in UNWATCHED:
                continue
            if item.is_dir():
                pending.append(item)
            else:
                rows[item.relative_to(project).as_posix()] = hashlib.sha256(item.read_bytes()).hexdigest()
    return rows


def manifest_difference(before, after):
    return sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))


def draft_from_art(carrier_document):
    """A new draft built the way a person would in the editor, from the art of an existing monster."""
    document = new_document("stage_check_draft", "Stage Check Draft")
    source = carrier_document.data
    for row in source["assets"]["images"]:
        _image_id, edits = animation.register_image(document.data, PROJECT, row["path"], image_id=row["id"])
        document = document.apply(*edits)
    for clip in source["animations"]["clips"]:
        image = next(row for row in source["assets"]["images"] if row["id"] == clip["frames"][0]["image"])
        columns = image["width"] // clip["frames"][0]["rect"][2]
        document = document.apply(*animation.clip_from_grid(document.data, image["id"], clip["id"], columns,
                                                            fps=clip["fps"], loop=clip["loop"]))
    for role, clip_id in source["presentation"]["roles"].items():
        if clip_id:
            document = document.apply(*animation.bind_role(document.data, role, clip_id))
    document = document.apply(set_value(("presentation", "visual_scale"), [1.5, 1.5]),
                              set_value(("presentation", "attack_hit_frame"), source["presentation"]["attack_hit_frame"]))
    return document.apply(*animation.bottom_center_edits(document.data, source["presentation"]["roles"]["idle"]))


def with_filter(document, value):
    """The document as an import would carry it, with the original profile's texture filter."""
    from rtcmonster import encode
    binding = json.loads(encode(document))["source_binding"]
    binding["passthrough"] = {**(binding.get("passthrough") or {}), "profile_texture_filter": value}
    return document.replace(("source_binding",), binding)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--carrier", default="", help="registered enemy whose actor carries the staged profile "
                                                      "(default: the first one the registry lists)")
    args = parser.parse_args()
    if args.artifacts:
        args.artifacts.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix="rtc-stage-check-"))
    started = time.monotonic()
    before = manifest(PROJECT)
    documents = {path.stem: read_document(path)[0] for path in sorted(EXAMPLES.glob("*.rtcmonster"))}
    staged = {name: document for name, document in documents.items() if document.data["animations"]["clips"]}
    if not staged:
        print("no example has animation clips", file=sys.stderr)
        return 1
    first = next(iter(staged.values()))
    staged["draft_from_art"] = draft_from_art(first)
    report, failures = {"stages": {}, "safety": {}}, []

    def check(name, passed, detail=""):
        print(f"{'PASS' if passed else 'FAIL':5} {name}" + (f" :: {detail}" if detail and not passed else ""), flush=True)
        if not passed:
            failures.append(name)
        return passed

    def refused(name, code, action):
        try:
            action()
        except BridgeError as error:
            report["safety"][name] = error.code
            return check(name, error.code == code, f"{error.code}: {error.detail}")
        return check(name, False, "it was accepted")

    for name, document in staged.items():
        try:
            result = staging.stage_presentation(args.godot, PROJECT, document, work, args.carrier, keep=True)
        except BridgeError as error:
            check(f"{name}: staged", False, f"{error.code}: {error.detail}")
            if args.artifacts and error.log:
                (args.artifacts / f"{name}-engine.log").write_text(error.log, encoding="utf-8")
            continue
        try:
            marker = json.loads((result.staging_root / staging.MARKER).read_text(encoding="utf-8"))
            check(f"{name}: staged in a copy outside the project, marked with its session",
                  marker.get("session") == result.session.id and PROJECT not in result.staging_root.parents)
            check(f"{name}: the readback from a second Godot process equals the document", result.passed,
                  "; ".join(result.differences))
            check(f"{name}: EnemyAnimationProfile.validation_errors() is empty", result.profile.get("errors") == [],
                  str(result.profile.get("errors")))
            check(f"{name}: resources, disk readback, images and attach all pass",
                  [result.areas[key] for key in ("staging", "resources", "readback", "images", "attach")] == ["PASS"] * 5,
                  str(result.areas))
            check(f"{name}: rendering, combat, network and publish are reported as not evaluated",
                  all(result.areas[key] == "NOT_EVALUATED" for key in ("rendering", "combat_runtime", "network", "publish")))
            expected_filter = staging.texture_filter_of(document)[0]
            attach = result.attach
            check(f"{name}: the texture filter is the document's, in the profile and on the sprite",
                  result.profile.get("texture_filter") == expected_filter
                  and attach.get("presentation", {}).get("texture_filter") == expected_filter,
                  f"profile {result.profile.get('texture_filter')}, sprite "
                  f"{attach.get('presentation', {}).get('texture_filter')}, expected {expected_filter}")
            check(f"{name}: a registered actor draws from the staged profile",
                  attach.get("evaluated") and attach.get("presentation", {}).get("has_presenter")
                  and attach["presentation"].get("frame_has_texture")
                  and attach["presentation"].get("sprite_frames_path") == result.sprite_frames_path, str(attach))
            check(f"{name}: the server-runtime actor builds no visual",
                  attach.get("evaluated") and attach.get("server", {}).get("has_presenter") is False, str(attach))
            text = (result.staging_root / result.sprite_frames_path.removeprefix("res://")).read_text(encoding="utf-8")
            check(f"{name}: the saved SpriteFrames is an engine-written resource referencing project textures",
                  text.startswith("[gd_resource type=\"SpriteFrames\"") and "ext_resource" in text)
            check(f"{name}: the engine and the editor agree on the generated files' hashes",
                  len(result.resources) == 2 and all(len(value) == 64 for value in result.resources.values()))
            report["stages"][name] = {"differences": list(result.differences), "attempts": result.attempts,
                                      "process": result.process, "areas": result.areas, "notes": list(result.notes),
                                      "seconds": round(result.seconds, 2), "carrier": attach.get("carrier"),
                                      "clips": sorted(result.profile.get("animations", {})),
                                      "texture_filter": result.profile.get("texture_filter"),
                                      "resources": result.resources, "godot_version": result.godot_version,
                                      "document_fingerprint": result.document_fingerprint,
                                      "project_fingerprint": result.project_fingerprint,
                                      "copy": {"files": result.session.files, "bytes": result.session.bytes,
                                               "seconds": round(result.session.seconds, 2)}}
        finally:
            removed = result.session.remove()
            check(f"{name}: the staging copy was removed", removed and not result.staging_root.exists())

    # ---- texture filter: an imported monster's filter survives, whatever it is
    draft = staged["draft_from_art"]
    for value in (2, 0):                               # linear, and "inherit from the parent"
        try:
            result = staging.stage_presentation(args.godot, PROJECT, with_filter(first, value), work, args.carrier)
            check(f"texture filter {value} is carried into the staged profile and onto the sprite",
                  result.passed and result.profile.get("texture_filter") == value
                  and result.attach.get("presentation", {}).get("texture_filter") == value,
                  "; ".join(result.differences) or str(result.profile.get("texture_filter")))
        except BridgeError as error:
            check(f"texture filter {value} is carried into the staged profile and onto the sprite", False,
                  f"{error.code}: {error.detail}")

    # ---- an image that changed since the document recorded it
    stale = draft.apply(set_value(("assets", "images", 0, "sha256"), "0" * 64))
    try:
        result = staging.stage_presentation(args.godot, PROJECT, stale, work, args.carrier)
        check("an image that is not the recorded file is reported, though every rect still fits",
              not result.passed and result.areas["images"] == "FAIL" and result.areas["resources"] == "PASS",
              str(result.areas))
    except BridgeError as error:
        check("an image that is not the recorded file is reported, though every rect still fits", False, error.code)

    # ---- the bridge's own refusals
    refused("the real project refuses stage_monster", "NOT_A_STAGING_PROJECT",
            lambda: client.call(args.godot, PROJECT, "stage_monster", "stage_check_draft",
                                stage=staging.stage_request(draft, args.carrier, "any-session")))
    refused("the real project refuses read_stage", "NOT_A_STAGING_PROJECT",
            lambda: client.call(args.godot, PROJECT, "read_stage", "stage_check_draft",
                                stage={"staging_session": "any-session"}))
    check("the real project has no staged output", not (PROJECT / staging.OUTPUT_ROOT).exists()
          and not (PROJECT / staging.MARKER).exists())

    session = None
    try:
        session = StagingSession.create(PROJECT, work)
        staging.import_assets(args.godot, session.root)
        good = staging.stage_request(draft, args.carrier, session.id)

        def send(change, operation="stage_monster", monster_id="stage_check_draft"):
            request = json.loads(json.dumps(good))
            change(request)
            return lambda: client.call(args.godot, session.root, operation, monster_id, stage=request)
        refused("a request from another staging session is refused", "STAGING_NOT_OWNED",
                send(lambda request: request.update(staging_session="0" * 32)))
        refused("a request without a staging session is refused", "STAGING_NOT_OWNED",
                send(lambda request: request.pop("staging_session")))
        for label, change in (
                ("a fractional source rect", lambda r: r["clips"][0]["frames"][0].update(rect=[0.5, 0, 64, 48])),
                ("a rect outside its image", lambda r: r["clips"][0]["frames"][0].update(rect=[0, 0, 99999, 48])),
                ("a negative rect", lambda r: r["clips"][0]["frames"][0].update(rect=[-1, 0, 64, 48])),
                ("a text fps", lambda r: r["clips"][0].update(fps="fast")),
                ("a zero duration", lambda r: r["clips"][0]["frames"][0].update(duration=0)),
                ("a loop that is not a boolean", lambda r: r["clips"][0].update(loop=1)),
                ("a role naming no clip", lambda r: r["presentation"]["roles"].update(idle="absent_clip")),
                ("a fractional hit frame", lambda r: r["presentation"].update(attack_hit_frame=2.5)),
                ("a zero visual scale", lambda r: r["presentation"].update(visual_scale=[0, 1])),
                ("an unknown texture filter", lambda r: r.update(texture_filter=99)),
                ("an image path that leaves the project", lambda r: r["images"].update(
                    {next(iter(r["images"])): "../outside.png"})),
                ("an image ID that is not an ID", lambda r: r["images"].update({"Bad ID": "assets/x.png"})),
                ("a carrier that is not text", lambda r: r.update(carrier=5))):
            refused(f"{label} is INVALID_REQUEST, not a script error", "INVALID_REQUEST", send(change))
        refused("a monster ID that is not an ID is INVALID_REQUEST", "INVALID_REQUEST",
                send(lambda request: None, monster_id="../escape"))
        refused("reading back a stage that was never made is RESOURCE_MISSING", "RESOURCE_MISSING",
                send(lambda request: None, operation="read_stage", monster_id="never_staged"))
        check("refused requests wrote nothing into the copy", not (session.root / staging.OUTPUT_ROOT).exists()
              or not any((session.root / staging.OUTPUT_ROOT).rglob("*.tres")))
        # A half-written file of an earlier attempt must not survive into the next one.
        folder = session.root / staging.OUTPUT_ROOT / "stage_check_draft"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "animation_profile.tres").write_text("left by a crashed attempt", encoding="utf-8")
        response = client.call(args.godot, session.root, "stage_monster", "stage_check_draft", stage=good)
        text = (folder / "animation_profile.tres").read_text(encoding="utf-8")
        check("a stage replaces what an earlier attempt left in its output folder",
              text.startswith("[gd_resource") and response.data["staging_session"] == session.id)
    except BridgeError as error:
        check("the request checks ran", False, f"{error.code}: {error.detail}")
    finally:
        if session is not None:
            check("the request-check copy was removed", session.remove() and not session.parent.exists())

    broken = draft.apply(set_value(("assets", "images", 0, "path"), "assets/absent_for_stage_check.png"))
    refused("a missing image stops the stage", "RESOURCE_MISSING",
            lambda: staging.stage_presentation(args.godot, PROJECT, broken, work, args.carrier))
    refused("a document without clips is refused before any copy", staging.NOTHING_TO_STAGE,
            lambda: staging.stage_presentation(args.godot, PROJECT, new_document("stage_check_empty", "Empty"), work))

    left = [path.name for path in work.iterdir() if path.name.startswith(staging.STAGING_PREFIX)]
    check("no staging copy is left behind by any of the runs", not left and not staging.leftovers(), str(left))
    changed = manifest_difference(before, manifest(PROJECT))
    check("the whole run left the real project byte-for-byte unchanged", not changed, str(changed[:10]))
    report["safety"]["project_files_compared"] = len(before)
    shutil.rmtree(work, ignore_errors=True)

    report.update(passed=not failures, failures=failures, seconds=round(time.monotonic() - started, 1))
    if args.artifacts:
        (args.artifacts / "stage_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                                          encoding="utf-8")
    print(f"MONSTER STAGE CHECK {'PASS' if not failures else 'FAIL'} "
          f"({len(report['stages'])} staged; {len(failures)} failed checks; {report['seconds']} s)")
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
