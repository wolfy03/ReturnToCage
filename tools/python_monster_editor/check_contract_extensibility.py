"""Prove with a real Godot that a new enemy needs no example and that a broken one is caught.

Works on a throwaway copy of the project (tracked files only), never on the
checkout itself:

    1. copy the project, add one new EnemyDefinition, import, run the contract check
       -> must pass; the new enemy is covered by the registry contract; legacy stays PASS
    2. break the new definition (unknown loot table), run again
       -> must fail in the registry contract for that enemy; legacy must still have no failure

    python tools/python_monster_editor/check_contract_extensibility.py --godot <Godot 4.7.2> [--artifacts <dir>]
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
NEW_ID = "contract_gnat"
DEFINITION = """[gd_resource type="Resource" script_class="EnemyDefinition" load_steps=3 format=3]
[ext_resource path="res://data/definitions/enemy_definition.gd" type="Script" id="1"]
[ext_resource path="res://gameplay/actors/enemies/sewer_beetle.tscn" type="PackedScene" id="2"]
[resource]
script = ExtResource("1")
id = &"contract_gnat"
display_name = "Contract Gnat"
actor_scene = ExtResource("2")
max_health = 9.0
attack_damage = 2.0
move_speed = 70.0
chase_range = 200.0
attack_range = 30.0
faction = &"hostile"
loot_table_id = &"{loot}"
"""


def copy_project(target):
    names = subprocess.run(["git", "ls-files", "-z"], cwd=ROOT, capture_output=True, check=True,
                           timeout=60).stdout.decode("utf-8").split("\0")
    for name in filter(None, names):
        if name.startswith((".github/", "docs/", "build/")):
            continue
        source, destination = ROOT / name, target / name
        if source.is_file():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)


def run(command, cwd, timeout):
    result = subprocess.run(command, cwd=cwd, capture_output=True, text=True, encoding="utf-8", errors="replace",
                            timeout=timeout, stdin=subprocess.DEVNULL)
    return result.returncode, (result.stdout or "") + (result.stderr or "")


def contract(godot, project, artifacts):
    code, log = run([sys.executable, "-X", "utf8", str(HERE / "check_godot_contract.py"), "--godot", str(godot),
                     "--project", str(project), "--artifacts", str(artifacts)], ROOT, 400)
    report_path = artifacts / "contract_report.json"
    report = json.loads(report_path.read_text(encoding="utf-8")) if report_path.is_file() else None
    return code, log, report


def rows(report, section, monster=None, status=None):
    return [row for row in report["results"] if row["section"] == section
            and (monster is None or row["monster"] == monster) and (status is None or row["status"] == status)]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--artifacts", type=Path)
    args = parser.parse_args()
    failures = []

    def expect(condition, message):
        print(("PASS " if condition else "FAIL ") + message, flush=True)
        if not condition:
            failures.append(message)

    with tempfile.TemporaryDirectory(prefix="rtc-monster-ext-") as temporary:
        work = Path(temporary)
        artifacts = args.artifacts.resolve() if args.artifacts else work / "artifacts"
        project = work / "project"
        copy_project(project)
        definition = project / f"data/content/enemies/{NEW_ID}.tres"
        definition.write_text(DEFINITION.format(loot="sewer_beetle_loot"), encoding="utf-8", newline="\n")
        code, log = run([str(args.godot), "--headless", "--path", str(project), "--editor", "--quit"], project, 600)
        expect(code == 0, f"the project copy imports (exit {code})")

        code, log, report = contract(args.godot, project, artifacts / "valid")
        expect(code == 0 and report is not None, "contract check passes with a new enemy that has no example")
        if report is None:
            print(log)
        else:
            expect(NEW_ID in report["registered_monsters"], "the new enemy is registered in ContentRegistry")
            mine = rows(report, "registry", NEW_ID)
            expect(len(mine) >= 14 and all(row["status"] == "PASS" for row in mine),
                   f"the registry contract examined the new enemy ({len(mine)} checks, all PASS)")
            expect(not rows(report, "legacy", NEW_ID), "the new enemy is not treated as a legacy baseline")
            expect(report["sections"]["legacy"] == "PASS" and report["sections"]["registry"] == "PASS",
                   "legacy and registry contracts both pass")
            expect(report["legacy_baselines"] == ["frog", "sewer_beetle"], "the baselines are unchanged")

        definition.write_text(DEFINITION.format(loot="no_such_loot_table"), encoding="utf-8", newline="\n")
        code, log, report = contract(args.godot, project, artifacts / "broken")
        expect(code != 0, "contract check fails when the new enemy's definition is broken")
        if report is None:
            expect(False, "a structured report exists for the broken run")
            print(log)
        else:
            broken = rows(report, "registry", NEW_ID, "FAIL")
            expect(bool(broken), "the failure is reported in the registry contract for the new enemy: "
                   + ", ".join(row["name"] for row in broken))
            expect(not rows(report, "legacy", status="FAIL"), "no legacy baseline check failed because of it")
            expect(report["sections"]["registry"] == "FAIL", "the registry section is FAIL")

    if failures:
        print(f"CONTRACT EXTENSIBILITY FAIL ({len(failures)} expectation(s) not met)")
        return 1
    print("CONTRACT EXTENSIBILITY PASS")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
