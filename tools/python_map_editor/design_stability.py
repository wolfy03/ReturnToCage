"""Run independent official Windows Godot snapshot trials and audit every child."""

import argparse
from collections import Counter
import os
from pathlib import Path
from threading import Event
import traceback
from uuid import uuid4

from bridge_stability import environment
from check_v4_region_bridge import SEWER, new_regions, publication, sewer
from godot_bridge import ENGINE_ERROR, GodotSession, ProjectSettings, fingerprint, project_manifest, read_json, write_json

COUNTS = {"v3": 30, "v4": 30, "flat": 20, "platform": 20, "publish": 20}
EXPECTED_PROCESSES = {"v3": 6, "v4": 10, "flat": 6, "platform": 6, "publish": 12}


def v3(settings):
    with GodotSession(settings, Event(), print) as session:
        document, original = session.import_region(SEWER)
        linked, result = session.stage_export(document)
        assert linked.source == document.source
        assert result["output_hash"] == original["scene_hash"]


def audit(root, profile):
    rows, failures = [], []
    launches = {path.with_name(path.name.removesuffix(".process.json")) for path in root.rglob("*.process.json")}
    exits = {path.with_name(path.name.removesuffix(".exit.json")) for path in root.rglob("*.exit.json")}
    if len(launches) != EXPECTED_PROCESSES[profile] or launches != exits:
        failures.append(f"expected {EXPECTED_PROCESSES[profile]} matching process/exit records; found {len(launches)}/{len(exits)}")
    for path in sorted(exits):
        result = read_json(Path(str(path) + ".exit.json"))
        launch = read_json(Path(str(path) + ".process.json")) if path in launches else {}
        reply_path = Path(str(path) + ".result.json")
        reply = read_json(reply_path) if reply_path.is_file() else {}
        logs = "".join(candidate.read_text(encoding="utf-8", errors="replace") for ending in (".stdout.log", ".stderr.log", ".godot.log")
                       if (candidate := Path(str(path) + ending)).is_file())
        code = result.get("exit_code")
        native = type(code) is int and (code < 0 or code > 255)
        expected = (profile == "v4" and path.name.startswith("stage_v4_export-") and code == 1
                    and reply.get("status") == "FAIL" and reply.get("error_code") == "UNSUPPORTED_NODE"
                    and "settlement exit sewer_gate" in reply.get("message", ""))
        status = "EXPECTED_REJECTION" if expected else "PASS" if code == 0 else "FAIL"
        if (not result.get("pid") or result.get("pid") != launch.get("pid") or not result.get("started_utc")
                or not result.get("exited_utc") or result.get("job_active_at_exit") != 0
                or ENGINE_ERROR.search(logs) or (reply and code == 0 and reply.get("status") != "PASS")):
            status = "FAIL"
        rows.append({**result, "operation": reply.get("operation", path.name), "result_status": reply.get("status"),
                     "native_crash": native, "status": status})
    if sum(row["status"] == "EXPECTED_REJECTION" for row in rows) != int(profile == "v4"):
        failures.append("unexpected number of verified input rejections")
    return rows, failures


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--profile", required=True, choices=COUNTS)
    parser.add_argument("--count", type=int, help="Override only for local diagnostic runs")
    args = parser.parse_args()
    count = COUNTS[args.profile] if args.count is None else args.count
    if count < 1:
        parser.error("--count must be positive")
    output = args.artifacts.resolve() / f"{args.profile}-{uuid4().hex[:10]}"
    output.mkdir(parents=True)
    settings = ProjectSettings(Path.cwd(), args.godot, output).checked()
    environment(settings.godot, output / "environment.json")
    # Keep runner credentials and unrelated configuration out of Godot and its dumps.
    allowed = {"SYSTEMROOT", "WINDIR", "SYSTEMDRIVE", "COMSPEC", "TEMP", "TMP", "USERPROFILE",
               "PROGRAMDATA", "PROGRAMFILES", "PROGRAMFILES(X86)", "NUMBER_OF_PROCESSORS", "PROCESSOR_ARCHITECTURE"}
    for key in list(os.environ):
        if key.upper() not in allowed:
            del os.environ[key]
    os.environ["PATH"] = str(Path(os.environ["SYSTEMROOT"]) / "System32")
    original = fingerprint(project_manifest(settings.project, Event()))
    outcomes = []
    for number in range(1, count + 1):
        folder = output / f"attempt-{number:02}"
        folder.mkdir()
        trial = ProjectSettings(settings.project, settings.godot, folder)
        problems = []
        try:
            if args.profile in ("flat", "platform"):
                new_regions(trial, (args.profile,), check_unsafe=False)
            else:
                {"v3": v3, "v4": sewer, "publish": publication}[args.profile](trial)
        except Exception:
            problems.append(traceback.format_exc())
        processes, failures = audit(folder, args.profile)
        problems.extend(failures)
        if fingerprint(project_manifest(settings.project, Event())) != original:
            problems.append("source project changed")
        passed = not problems and all(row["status"] != "FAIL" for row in processes)
        outcomes.append({"attempt": number, "passed": passed, "problems": problems, "processes": processes})
        totals = Counter(row["status"] for outcome in outcomes for row in outcome["processes"])
        write_json(output / "summary.json", {"profile": args.profile, "required": count, "attempts": outcomes, "process_totals": totals})
        print(f"{args.profile} {number}/{count}: {passed}", flush=True)
        if not passed:
            break
    return int(len(outcomes) != count or not all(item["passed"] for item in outcomes))


if __name__ == "__main__":
    raise SystemExit(main())
