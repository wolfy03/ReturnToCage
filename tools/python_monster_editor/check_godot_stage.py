"""Stage monster presentations with the real engine and check what it built (MONSTER-STEP 3).

    python tools/python_monster_editor/check_godot_stage.py --godot <godot> [--artifacts <dir>] [--carrier <id>]

For each example that has clips, and for a draft assembled here with the editor's own helpers:

* copy the project, import it, and run the bridge's ``stage_monster`` in the copy;
* Godot builds a SpriteFrames and an EnemyAnimationProfile, reads them back, and readies a registered
  enemy actor with the profile - once for presentation and once the way the server runtime creates it;
* the readback must equal the document, ``EnemyAnimationProfile.validation_errors()`` must be empty, the
  carrier must draw from the staged resources, and the server-side actor must build no visual.

Then the safety checks: the real project refuses ``stage_monster`` and is byte-for-byte unchanged by the
whole run, and a document that cannot be staged is reported, not half-written.
"""

import argparse
import hashlib
import json
from pathlib import Path
import sys
import time

TOOL = Path(__file__).resolve().parent
PROJECT = TOOL.parents[1]
sys.path.insert(0, str(TOOL))

from application import animation  # noqa: E402
from bridge import client, staging  # noqa: E402
from bridge.client import BridgeError  # noqa: E402
from rtcmonster import new_document, read_document, set_value  # noqa: E402

EXAMPLES = TOOL / "examples"
WATCHED = ("assets", "data", "presentation", "gameplay", "tools/monster_bridge", "project.godot")


def manifest(project):
    """Content hashes of the project files a stage could conceivably touch."""
    rows = {}
    for name in WATCHED:
        path = project / name
        files = [path] if path.is_file() else sorted(item for item in path.rglob("*") if item.is_file())
        for item in files:
            rows[item.relative_to(project).as_posix()] = hashlib.sha256(item.read_bytes()).hexdigest()
    return rows


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--carrier", default="", help="registered enemy whose actor carries the staged profile "
                                                      "(default: the first one the registry lists)")
    args = parser.parse_args()
    if args.artifacts:
        args.artifacts.mkdir(parents=True, exist_ok=True)
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

    for name, document in staged.items():
        try:
            result = staging.stage_presentation(args.godot, PROJECT, document, args.artifacts, args.carrier)
        except BridgeError as error:
            check(f"{name}: staged", False, f"{error.code}: {error.detail}")
            if args.artifacts and error.log:
                (args.artifacts / f"{name}-engine.log").write_text(error.log, encoding="utf-8")
            continue
        try:
            check(f"{name}: staged in a copy outside the project",
                  (result.staging_root / staging.MARKER).is_file() and PROJECT not in result.staging_root.parents)
            check(f"{name}: Godot's readback equals the document", result.passed, "; ".join(result.differences))
            check(f"{name}: EnemyAnimationProfile.validation_errors() is empty", result.profile.get("errors") == [],
                  str(result.profile.get("errors")))
            attach = result.attach
            check(f"{name}: a registered actor draws from the staged profile",
                  attach.get("evaluated") and attach.get("presentation", {}).get("has_presenter")
                  and attach["presentation"].get("frame_has_texture")
                  and attach["presentation"].get("sprite_frames_path") == result.sprite_frames_path, str(attach))
            check(f"{name}: the server-runtime actor builds no visual",
                  attach.get("evaluated") and attach.get("server", {}).get("has_presenter") is False, str(attach))
            text = (result.staging_root / result.sprite_frames_path.removeprefix("res://")).read_text(encoding="utf-8")
            check(f"{name}: the saved SpriteFrames is an engine-written resource referencing project textures",
                  text.startswith("[gd_resource type=\"SpriteFrames\"") and "ext_resource" in text)
            report["stages"][name] = {"differences": list(result.differences), "attempts": result.attempts,
                                      "seconds": round(result.seconds, 2), "carrier": attach.get("carrier"),
                                      "clips": sorted(result.profile.get("animations", {}))}
        finally:
            staging.remove_staging_copy(result.staging_root)
            check(f"{name}: the staging copy was removed", not result.staging_root.exists())

    # ---- safety
    try:
        client.call(args.godot, PROJECT, "stage_monster", "stage_check_draft",
                    stage=staging.stage_request(staged["draft_from_art"], args.carrier))
        check("the real project refuses stage_monster", False, "the bridge accepted it")
    except BridgeError as error:
        check("the real project refuses stage_monster", error.code == "NOT_A_STAGING_PROJECT", error.code)
        report["safety"]["real_project"] = error.code
    check("the real project has no staged output", not (PROJECT / "monster_stage").exists()
          and not (PROJECT / staging.MARKER).exists())
    broken = staged["draft_from_art"].apply(set_value(("assets", "images", 0, "path"), "assets/absent_for_stage_check.png"))
    try:
        result = staging.stage_presentation(args.godot, PROJECT, broken, args.artifacts, args.carrier,
                                            keep_on_failure=False)
        staging.remove_staging_copy(result.staging_root)
        check("a missing image stops the stage", False, "it was staged")
    except BridgeError as error:
        check("a missing image stops the stage", error.code == "RESOURCE_MISSING", f"{error.code}: {error.detail}")
        report["safety"]["missing_image"] = error.code
    empty = new_document("stage_check_empty", "Empty")
    try:
        staging.stage_presentation(args.godot, PROJECT, empty, args.artifacts)
        check("a document without clips is refused before any copy", False)
    except BridgeError as error:
        check("a document without clips is refused before any copy", error.code == staging.NOTHING_TO_STAGE, error.code)
    check("the whole run left the real project byte-for-byte unchanged", manifest(PROJECT) == before)

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
