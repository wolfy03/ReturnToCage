"""Check the read-only Godot bridge and the legacy import against a real Godot.

    python tools/python_monster_editor/check_godot_import.py --godot <Godot 4.7.2> [--artifacts <dir>]

Three groups of checks, each with its own PASS / FAIL lines:

    game        inspect_monsters and import_monster on this project: every baseline monster is found, each
                import reproduces the verified example document, survives save and reopen, and not one
                project file changes.
    isolated    a throw-away copy of the project with two monsters added: one that reuses a known actor
                (must import completely under its own ID and values) and one with an unknown actor script
                (must be reported as unsupported, never as a successful import). The importer therefore
                does not work by knowing the baseline monsters' IDs.
    failures    a missing executable, an engine of another version, an unknown monster, a timeout and a
                cancellation each end with their own error code and leave nothing behind.

Exit code 0 only when every check passed. With --artifacts the imported documents and a structured
import_report.json are kept.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

from bridge import client, importer  # noqa: E402
from rtcmonster import FAIL, encode, read_document, validate, write_document  # noqa: E402

EXAMPLES = HERE / "examples"
GAMEPLAY_SECTIONS = ("stats", "movement", "sensors", "presentation", "collision", "attack_patterns", "behavior", "loot")
BINDING_KEYS = ("runtime", "definition_path", "actor_scene_path", "animation_profile_path", "sprite_frames_path",
                "loot_table_path", "files", "editability", "unsupported")
EXPECTED = {"sewer_beetle": ("complete", "ground_melee", 0), "frog": ("partial", "hopper", 2)}
SKIPPED_FOLDERS = {".git", ".godot", ".claude", "__pycache__", ".pytest_cache", "artifacts", "node_modules", "venv",
                   ".venv"}
ENEMIES = "res://gameplay/actors/enemies/"

CAVE_BEETLE = """[gd_resource type="Resource" script_class="EnemyDefinition" load_steps=3 format=3]
[ext_resource path="res://data/definitions/enemy_definition.gd" type="Script" id="1"]
[ext_resource path="res://gameplay/actors/enemies/sewer_beetle.tscn" type="PackedScene" id="2"]
[resource]
script = ExtResource("1")
id = &"cave_beetle"
display_name = "Cave Beetle"
actor_scene = ExtResource("2")
max_health = 61.0
attack_damage = 13.0
move_speed = 71.0
chase_range = 310.0
attack_range = 52.0
faction = &"hostile"
loot_table_id = &"sewer_beetle_loot"
"""
ODD_BUG = CAVE_BEETLE.replace("sewer_beetle.tscn", "odd_bug.tscn").replace("cave_beetle", "odd_bug").replace(
    "Cave Beetle", "Odd Bug")
ODD_AGENT = "extends EnemyAgent\n## An actor script no import profile was written for.\n"


class Checks:
    def __init__(self):
        self.rows = []

    def add(self, group, name, passed, detail=""):
        self.rows.append({"group": group, "name": name, "status": "PASS" if passed else "FAIL", "detail": str(detail)})
        print(f"{'PASS' if passed else 'FAIL'} [{group}] {name}" + (f" :: {detail}" if detail and not passed else ""),
              flush=True)
        return passed

    @property
    def failed(self):
        return [row for row in self.rows if row["status"] == "FAIL"]


def tree_hash(root):
    """One hash per file under ``root`` (engine cache and VCS folders left out)."""
    hashes = {}
    for folder, names, files in os.walk(root):
        names[:] = [name for name in names if name not in SKIPPED_FOLDERS]
        for name in files:
            path = Path(folder) / name
            hashes[path.relative_to(root).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def clips_by_path(document):
    images = {row["id"]: row for row in document.data["assets"]["images"]}
    return {clip["id"]: (clip["fps"], clip["loop"],
                         [(images[frame["image"]]["path"], tuple(frame["rect"]), frame["duration"],
                           images[frame["image"]]["sha256"]) for frame in clip["frames"]])
            for clip in document.data["animations"]["clips"]}


def expect_error(checks, group, name, code, action):
    try:
        action()
    except client.BridgeError as error:
        return checks.add(group, name, error.code == code, f"got {error.code}: {error.detail}")
    return checks.add(group, name, False, "no error was raised")


def check_game(checks, godot, artifacts, timings):
    before = tree_hash(ROOT)
    start = time.perf_counter()
    listing = client.inspect_monsters(godot, ROOT)
    timings["inspect_monsters_ms"] = round((time.perf_counter() - start) * 1000)
    rows = {row["monster_id"]: row for row in listing.data["monsters"]}
    checks.add("game", "the engine answering is the pinned version",
               listing.environment.get("godot_version", "").startswith((ROOT / ".godot-version").read_text().strip()),
               listing.environment)
    checks.add("game", "every baseline monster is registered", set(EXPECTED) <= set(rows), sorted(rows))
    checks.add("game", "the game's own content validation is clean", listing.data.get("content_errors") == [],
               listing.data.get("content_errors"))
    for monster_id, (status, profile, unsupported) in EXPECTED.items():
        if monster_id not in rows:
            continue
        checks.add("game", f"{monster_id}: import support is reported as {status}",
                   rows[monster_id]["import_support"] == status, rows[monster_id])
        start = time.perf_counter()
        result, response = client.import_monster(godot, ROOT, monster_id)
        timings[f"import_{monster_id}_ms"] = round((time.perf_counter() - start) * 1000)
        example = read_document(EXAMPLES / f"{monster_id}.rtcmonster")[0]
        checks.add("game", f"{monster_id}: status, profile and unsupported notes",
                   (result.status, result.profile, len(result.notes)) == (status, profile, unsupported),
                   (result.status, result.profile, result.notes))
        different = [section for section in GAMEPLAY_SECTIONS if result.document.data[section] != example.data[section]]
        checks.add("game", f"{monster_id}: gameplay sections equal the verified example", not different, different)
        checks.add("game", f"{monster_id}: animation clips, frames and image hashes equal the example",
                   clips_by_path(result.document) == clips_by_path(example))
        mine, theirs = result.document.data["source_binding"], example.data["source_binding"]
        different = [key for key in BINDING_KEYS if mine[key] != theirs[key]]
        checks.add("game", f"{monster_id}: source binding equals the example", not different, different)
        report = validate(result.document, ROOT)
        blocking = [item.code for item in report.select(FAIL) if item.domain != "publish"]
        checks.add("game", f"{monster_id}: the imported document validates", not blocking, blocking)
        checks.add("game", f"{monster_id}: publish is blocked exactly when something was not converted",
                   (report.status("publish") == FAIL) == bool(unsupported), report.status("publish"))
        with tempfile.TemporaryDirectory(prefix="rtc-import-") as folder:
            path = Path(folder) / "한글 폴더" / f"{monster_id}.rtcmonster"
            path.parent.mkdir()
            write_document(path, result.document)
            reopened = read_document(path)[0]
            checks.add("game", f"{monster_id}: saved and reopened without change",
                       reopened.fingerprint == result.document.fingerprint and encode(reopened) == path.read_bytes())
        if artifacts:
            (artifacts / f"imported_{monster_id}.rtcmonster").write_bytes(encode(result.document))
        unchanged = importer.project_fingerprint(ROOT, result.document) == {
            row["path"]: row["sha256"] for row in mine["files"]}
        checks.add("game", f"{monster_id}: bound source files still have the recorded hashes", unchanged)
    after = tree_hash(ROOT)
    changed = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path)
                     and not (artifacts and (ROOT / path).resolve().is_relative_to(artifacts.resolve())))
    checks.add("game", "inspecting and importing changed no project file", not changed, changed[:10])


def make_isolated_project(target):
    def ignore(_folder, names):
        return [name for name in names if name in SKIPPED_FOLDERS]
    shutil.copytree(ROOT, target, ignore=ignore)
    (target / "data/content/enemies/cave_beetle.tres").write_text(CAVE_BEETLE, encoding="utf-8", newline="\n")
    (target / "data/content/enemies/odd_bug.tres").write_text(ODD_BUG, encoding="utf-8", newline="\n")
    (target / "gameplay/actors/enemies/odd_agent.gd").write_text(ODD_AGENT, encoding="utf-8", newline="\n")
    scene = (target / "gameplay/actors/enemies/sewer_beetle.tscn").read_text(encoding="utf-8")
    marker = 'path="res://gameplay/actors/enemies/enemy_agent.gd"'
    if marker not in scene:
        raise RuntimeError("sewer_beetle.tscn no longer references enemy_agent.gd; update this check")
    (target / "gameplay/actors/enemies/odd_bug.tscn").write_text(
        scene.replace(marker, 'path="res://gameplay/actors/enemies/odd_agent.gd"'), encoding="utf-8", newline="\n")


def check_isolated(checks, godot, artifacts, timings):
    with tempfile.TemporaryDirectory(prefix="rtc-isolated-") as folder:
        project = Path(folder) / "project"
        make_isolated_project(project)
        start = time.perf_counter()
        result = subprocess.run([str(client.engine_binary(godot)), "--headless", "--path", str(project), "--import"],
                                cwd=project,
                                capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=900,
                                stdin=subprocess.DEVNULL)
        timings["isolated_first_import_ms"] = round((time.perf_counter() - start) * 1000)
        if not checks.add("isolated", "the project copy opens in Godot", result.returncode == 0,
                          (result.stdout or "")[-2000:] + (result.stderr or "")[-2000:]):
            return
        before = tree_hash(project)
        listing = client.inspect_monsters(godot, project)
        rows = {row["monster_id"]: row for row in listing.data["monsters"]}
        # The client itself rejects an answer whose project_path is another project (RESPONSE_MISMATCH),
        # so reaching this line already means Godot answered about the copy.
        checks.add("isolated", "the copy has monsters the real project does not",
                   not (ROOT / "data/content/enemies/cave_beetle.tres").exists() and "cave_beetle" in rows)
        checks.add("isolated", "both added monsters are discovered without any code change",
                   {"cave_beetle", "odd_bug", "frog", "sewer_beetle"} <= set(rows), sorted(rows))
        checks.add("isolated", "a new monster on a known actor is importable",
                   rows.get("cave_beetle", {}).get("import_support") == "complete", rows.get("cave_beetle"))
        checks.add("isolated", "a monster on an unknown actor script is reported unsupported",
                   rows.get("odd_bug", {}).get("import_support") == "unsupported"
                   and rows.get("odd_bug", {}).get("agent_script") == ENEMIES + "odd_agent.gd", rows.get("odd_bug"))
        cave, _ = client.import_monster(godot, project, "cave_beetle")
        stats = cave.document.data["stats"]
        checks.add("isolated", "the new monster imports completely under its own ID",
                   (cave.status, cave.profile, cave.document.monster_id, cave.notes)
                   == ("complete", "ground_melee", "cave_beetle", []), (cave.status, cave.notes))
        checks.add("isolated", "its values are its own, not the baseline monster's",
                   (stats["max_health"], stats["attack_damage"], stats["move_speed"], stats["chase_range"],
                    stats["attack_range"]) == (61, 13, 71, 310, 52)
                   and cave.document.data["metadata"]["display_name"] == "Cave Beetle"
                   and cave.document.data["source_binding"]["definition_path"]
                   == "data/content/enemies/cave_beetle.tres", dict(stats))
        blocking = [item.code for item in validate(cave.document, project).select(FAIL) if item.domain != "publish"]
        checks.add("isolated", "the new monster's document validates against the copy", not blocking, blocking)
        odd, _ = client.import_monster(godot, project, "odd_bug")
        binding = odd.document.data["source_binding"]
        checks.add("isolated", "an unknown actor is never called a successful import",
                   odd.status == "unsupported" and odd.profile == "" and len(odd.notes) >= 2
                   and binding["editability"]["behavior"] == "unsupported"
                   and binding["editability"]["attack_patterns"] == "unsupported", (odd.status, odd.notes))
        checks.add("isolated", "its publish check fails instead of passing silently",
                   validate(odd.document, project).status("publish") == FAIL)
        checks.add("isolated", "values Godot could read are still kept for the unknown actor",
                   odd.document.data["stats"]["max_health"] == 61)
        if artifacts:
            (artifacts / "isolated_cave_beetle.rtcmonster").write_bytes(encode(cave.document))
            (artifacts / "isolated_odd_bug.rtcmonster").write_bytes(encode(odd.document))
        after = tree_hash(project)
        changed = sorted(path for path in set(before) | set(after) if before.get(path) != after.get(path))
        checks.add("isolated", "the bridge changed no file in the copy", not changed, changed[:10])
        expect_error(checks, "isolated", "an unknown monster ID is UNKNOWN_MONSTER", client.UNKNOWN_MONSTER,
                     lambda: client.import_monster(godot, project, "no_such_monster"))


def check_failures(checks, godot, timings):
    with tempfile.TemporaryDirectory(prefix="rtc-failures-") as folder:
        folder = Path(folder)
        expect_error(checks, "failures", "a missing executable is GODOT_MISSING", client.GODOT_MISSING,
                     lambda: client.inspect_monsters(folder / "no_godot_here.exe", ROOT))
        expect_error(checks, "failures", "a folder that is not the project is PROJECT_INVALID", client.PROJECT_INVALID,
                     lambda: client.inspect_monsters(godot, folder))
        other = folder / "other_version"
        other.mkdir()
        (other / ".godot-version").write_text("9.9.9\n", encoding="utf-8")
        expect_error(checks, "failures", "an engine of another version is GODOT_VERSION_MISMATCH",
                     client.GODOT_VERSION_MISMATCH, lambda: client.check_version(godot, other))
        checks.add("failures", "the pinned version is accepted", bool(client.check_version(godot, ROOT)))
        expect_error(checks, "failures", "an unknown monster is UNKNOWN_MONSTER", client.UNKNOWN_MONSTER,
                     lambda: client.import_monster(godot, ROOT, "no_such_monster"))
        work = folder / "work"
        work.mkdir()
        start = time.perf_counter()
        expect_error(checks, "failures", "an engine that takes too long is TIMEOUT", client.TIMEOUT,
                     lambda: client.call(godot, ROOT, "inspect_monsters", timeout=0.05, work_folder=work))
        timings["timeout_stop_ms"] = round((time.perf_counter() - start) * 1000)
        cancel = threading.Event()
        threading.Timer(0.3, cancel.set).start()
        start = time.perf_counter()
        expect_error(checks, "failures", "a cancelled call is CANCELLED", client.CANCELLED,
                     lambda: client.call(godot, ROOT, "inspect_monsters", cancel=cancel, work_folder=work))
        timings["cancel_stop_ms"] = round((time.perf_counter() - start) * 1000)
        checks.add("failures", "stopped calls stop promptly",
                   timings["timeout_stop_ms"] < 15000 and timings["cancel_stop_ms"] < 15000, timings)
        checks.add("failures", "no request or result file is left behind", list(work.iterdir()) == [],
                   [path.name for path in work.iterdir()])
        again = client.inspect_monsters(godot, ROOT)
        checks.add("failures", "the bridge works again after the failures", len(again.data["monsters"]) >= 2)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--skip-isolated", action="store_true", help="skip the project-copy checks (slow)")
    args = parser.parse_args()
    artifacts = args.artifacts.resolve() if args.artifacts else None
    if artifacts:
        artifacts.mkdir(parents=True, exist_ok=True)
    checks, timings = Checks(), {}
    groups = [("game", lambda: check_game(checks, args.godot, artifacts, timings)),
              ("failures", lambda: check_failures(checks, args.godot, timings))]
    if not args.skip_isolated:
        groups.insert(1, ("isolated", lambda: check_isolated(checks, args.godot, artifacts, timings)))
    for group, run in groups:
        try:
            run()
        except Exception as error:      # a crash in one group is that group's failure, with the reason kept
            checks.add(group, "the group ran to the end", False, f"{type(error).__name__}: {error}")
    report = {"checked_at": datetime.now(timezone.utc).isoformat(timespec="seconds"), "godot": str(args.godot),
              "isolated_project": "skipped" if args.skip_isolated else "checked", "timings_ms": timings,
              "passed": len(checks.rows) - len(checks.failed), "failed": len(checks.failed), "checks": checks.rows}
    if artifacts:
        (artifacts / "import_report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n",
                                                      encoding="utf-8")
    print("TIMINGS", json.dumps(timings))
    if checks.failed:
        print(f"MONSTER IMPORT CHECK FAIL: {len(checks.failed)} of {len(checks.rows)} checks failed")
        return 1
    print(f"MONSTER IMPORT CHECK PASS: {len(checks.rows)} checks")
    return 0


if __name__ == "__main__":
    sys.exit(main())
