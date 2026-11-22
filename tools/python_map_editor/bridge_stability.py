"""Sequential official-engine isolation and stability gates for the map editor."""

import argparse
from dataclasses import asdict
from importlib.metadata import PackageNotFoundError, version
import json
import os
from pathlib import Path
import platform
from threading import Event
from uuid import uuid4

from check_scene_bridge import REGION, check
from godot_bridge import (
    ENGINE_ERROR, BridgeError, GodotSession, ProjectSettings, file_hash, fingerprint, read_json, response,
    run_child, write_json,
)

PHASES = ("load", "inventory", "contract", "collision", "session", "validate_export")
EXTRA = ("inspect_project", "import_region", "validate_document", "export_region", "runtime")


def environment(godot, output):
    dependencies = {}
    for name in ("PySide6-Essentials", "PyInstaller"):
        try:
            dependencies[name] = version(name)
        except PackageNotFoundError:
            dependencies[name] = None
    write_json(output, {"godot_sha256": file_hash(godot), "os": platform.platform(), "architecture": platform.machine(),
                        "python": platform.python_version(), "dependencies": dependencies,
                        "runner": {key: os.environ.get(key) for key in ("ImageOS", "ImageVersion", "RUNNER_OS",
                                                                       "RUNNER_ARCH", "GITHUB_SHA")}})


def scenario(session, phase, index, expected, document):
    label = f"{phase}-{index:03}"
    result_file = session.evidence / f"{label}.result.json"
    request_file = session.evidence / f"{label}.request.json"
    request_id = uuid4().hex
    row = {"phase": phase, "index": index, "status": "FAIL", "files": label,
           "fixture_hash": expected["scene_hash"], "exit_code": None}
    request = {"protocol": 1, "request_id": request_id, "operation": phase,
               "result": str(result_file), "region_path": "res://" + REGION, "expected": expected}
    arguments = ["--scene", "res://tools/map_bridge/bridge.tscn", "--", "--request", str(request_file)]
    if phase in PHASES[:-1]:
        arguments = ["--scene", "res://tools/map_bridge/phase_probe.tscn", "--", "--phase", phase, str(request_file)]
    elif phase == "runtime":
        arguments = ["--scene", "res://tools/map_bridge/runtime_validation.tscn", "--", "--region", "sewer_region"]
    elif phase in ("export_region", "validate_document"):
        link = document.source
        request.update(region_id=document.region_id, display_name=document.display_name,
                       objects=[asdict(item) for item in document.objects],
                       bindings={item.id: item.as_bridge_data() for item in link.bindings},
                       source={name: getattr(link, name) for name in ("scene_hash", "scene_path", "region_hash",
                                                                     "scene_uid", "region_uid")})
    write_json(request_file, request)
    try:
        code, output = session._run(label, arguments, allow_response=True)
        row["exit_code"] = code
        milestones = [line for line in output.splitlines() if line.startswith("RTC_BRIDGE ")]
        row["last_milestone"] = milestones[-1] if milestones else None
        if result_file.exists():
            row["result_status"] = read_json(result_file).get("status")
        if phase == "runtime":
            runtime = {line.removeprefix("REGION_PLAYTEST_JSON ") for line in output.splitlines()
                       if line.startswith("REGION_PLAYTEST_JSON ")}
            if code != 0 or len(runtime) != 1 or "AUTHORED FIELD RUNTIME PASS" not in output:
                raise BridgeError("RUNTIME_LOAD_FAILED", f"Runtime exit {code}")
            if json.loads(next(iter(runtime))).get("overall") not in ("PASS", "PASS_WITH_WARNINGS"):
                raise BridgeError("RUNTIME_LOAD_FAILED", "Runtime result was not PASS")
            if ENGINE_ERROR.search(output):
                raise BridgeError("RUNTIME_LOAD_FAILED", "Runtime logged engine errors")
        else:
            response(result_file, phase, request_id, code, output)
        row["status"] = "PASS"
    except (BridgeError, OSError, ValueError) as error:
        row["error"] = str(error)
    exit_file = session.evidence / f"{label}.exit.json"
    if exit_file.exists():
        row.update(read_json(exit_file))
    return row


def capture_native_failure(session, procdump, row):
    # This is an additional diagnostic launch; the original failure is retained.
    prefix = row["files"]
    launch = read_json(session.evidence / f"{prefix}.process.json")
    folder = session.evidence / "diagnostic-dump"
    folder.mkdir()
    request_file = session.evidence / f"{prefix}.request.json"
    request = read_json(request_file)
    request["result"] = str(folder / "result.json")
    diagnostic_request = folder / "request.json"
    write_json(diagnostic_request, request)
    argv = [str(diagnostic_request) if arg == str(request_file) else arg for arg in launch["argv"]]
    argv[argv.index("--log-file") + 1] = str(folder / "engine.log")
    allowed = {"SYSTEMROOT", "WINDIR", "PATH", "COMSPEC", "TEMP", "TMP", "APPDATA", "LOCALAPPDATA",
               "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "HOME"}
    env = {key: value for key, value in session.env.items() if key.upper() in allowed}
    env["PATH"] = str(Path(os.environ["SYSTEMROOT"]) / "System32")
    monitor = [str(procdump), "-accepteula", "-n", "1", "-e", "-mm", "-x", str(folder), *argv]
    try:
        code, _ = run_child(monitor, session.stage, env, folder, "procdump", session.cancel, 90)
        result = {"procdump_exit": code, "dumps": {dump.name: file_hash(dump) for dump in folder.glob("*.dmp")}}
    except (BridgeError, OSError) as error:
        result = {"error": str(error)}
    write_json(folder / "capture.json", {"trigger": prefix, **result})


def collect(settings, output, phase_count, validation_count, commands, external_contract, procdump):
    rows = []
    with GodotSession(settings, Event()) as session:
        expected, document = None, None
        if external_contract is not None:
            # An external result may only seed diagnostic comparisons. It cannot
            # attest an export, and the runner marks this run as diagnostic.
            expected = read_json(external_contract)["data"]
            scene = session.stage / expected["scene_path"]
            region = session.stage / expected["region_path"]
            if file_hash(scene) != expected["scene_hash"] or file_hash(region) != expected["region_hash"]:
                raise BridgeError("SOURCE_MODIFIED", "diagnostic contract is for a different fixture")
        else:
            document, expected = session.import_region(REGION)
        expected["output_hash"] = expected["scene_hash"]
        summary = {"evidence": str(session.evidence), "fixture": fingerprint(session.manifest), "godot": session.version,
                   "diagnostic_contract": external_contract is not None, "attempts": rows}
        cases = [(phase, validation_count if phase == "validate_export" else phase_count) for phase in PHASES]
        cases.extend((phase, 3) for phase in EXTRA
                     if commands and (document is not None or phase not in ("export_region", "validate_document")))
        for phase, count in cases:
            for index in range(1, count + 1):
                row = scenario(session, phase, index, expected, document)
                rows.append(row)
                write_json(output, summary)
                print(phase, index, row["status"], row["exit_code"], flush=True)
                if procdump and (row["exit_code"] or 0) & 0xffffffff == 0xc0000005:
                    capture_native_failure(session, procdump, row)
                    procdump = None
        summary["totals"] = {phase: {
            "runs": len(results),
            "pass": sum(item["status"] == "PASS" for item in results),
            "access_violations": sum((item["exit_code"] or 0) & 0xffffffff == 0xc0000005 for item in results),
        } for phase, _ in cases if (results := [item for item in rows if item["phase"] == phase])}
        write_json(output, summary)
    return all(row["status"] == "PASS" for row in rows) and external_contract is None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--phase-count", type=int, default=30)
    parser.add_argument("--validation-count", type=int, default=50)
    parser.add_argument("--round-trips", type=int, default=0)
    parser.add_argument("--commands", action="store_true")
    parser.add_argument("--diagnostic-contract", type=Path)
    parser.add_argument("--procdump", type=Path, help="Capture a separate diagnostic dump on the first access violation")
    args = parser.parse_args()
    if min(args.phase_count, args.validation_count, args.round_trips) < 0:
        parser.error("repeat counts must be nonnegative")
    output = args.artifacts.resolve() / f"stability-{uuid4().hex[:12]}"
    output.mkdir(parents=True)
    print(f"BRIDGE STABILITY EVIDENCE {output}", flush=True)
    settings = ProjectSettings(args.project, args.godot, output).checked()
    environment(settings.godot, output / "environment.json")
    passed = False
    outcome = {}
    try:
        passed = collect(settings, output / "phases.json", args.phase_count, args.validation_count,
                         args.commands, args.diagnostic_contract,
                         args.procdump.resolve(strict=True) if args.procdump else None)
    except (BridgeError, OSError, ValueError) as error:
        outcome["matrix_error"] = str(error)
    repetitions = []
    for index in range(1, args.round_trips + 1):
        destination = output / f"round-trip-{index:02}"
        destination.mkdir()
        repetitions.append(check(settings.project, settings.godot, destination, transformations=False) == 0)
        write_json(output / "result.json", {**outcome, "phase_gate": passed, "round_trips": repetitions})
    write_json(output / "result.json", {**outcome, "phase_gate": passed, "round_trips": repetitions})
    return 0 if passed and all(repetitions) else 1


if __name__ == "__main__":
    raise SystemExit(main())
