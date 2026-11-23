"""Smoke-test the built zip from an isolated directory with no Python on PATH."""

import argparse
import hashlib
import json
import os
from pathlib import Path
from threading import Event
import shutil
import struct
import subprocess
import sys
import tempfile
from zipfile import ZipFile


def package_environment():
    # A crash dump of this process must not inherit runner tokens or credentials.
    keys = ("SYSTEMROOT", "WINDIR", "SYSTEMDRIVE", "COMSPEC", "TEMP", "TMP", "USERPROFILE",
            "HOMEDRIVE", "HOMEPATH", "PROGRAMDATA", "PROGRAMFILES", "PROGRAMFILES(X86)",
            "PROCESSOR_ARCHITECTURE", "NUMBER_OF_PROCESSORS")
    env = {key: os.environ[key] for key in keys if key in os.environ}
    env["PATH"] = str(Path(env["SYSTEMROOT"]) / "System32")
    env["QT_FORCE_STDERR_LOGGING"] = "1"
    return env


def pe_subsystem(executable):
    with executable.open("rb") as stream:
        if stream.read(2) != b"MZ":
            raise ValueError("expected a Windows PE executable")
        stream.seek(0x3C)
        header, = struct.unpack("<I", stream.read(4))
        stream.seek(header)
        if stream.read(4) != b"PE\0\0":
            raise ValueError("invalid PE signature")
        stream.seek(header + 24 + 68)  # Subsystem in the PE32/PE32+ optional header.
        value, = struct.unpack("<H", stream.read(2))
        return value


def run_smoke(executable, cwd, env, evidence, scale):
    env = {**env, "QT_SCALE_FACTOR": scale}
    run = {"scale": float(scale), "passed": False}
    stem = f"qt-smoke-{scale}"
    for name, flag, key in (("edit", None, None), ("reopen", "--smoke-reopen", "fixture"),
                            ("region-reopen", "--smoke-region-reopen", "region_fixture")):
        report = evidence / f"{stem}-{name}.json"
        extra = [flag, run["edit"][key]] if flag else []
        try:
            completed = subprocess.run([str(executable), "--smoke-report", str(report), *extra],
                                       cwd=cwd, env=env, timeout=45, check=False)
        except subprocess.TimeoutExpired:
            run[f"{name}_timeout"] = True
            return run
        run[f"{name}_exit_code"] = completed.returncode
        qt = run[name] = json.loads(report.read_text(encoding="utf-8")) if report.exists() else {}
        if (completed.returncode != 0 or qt.get("passed") is not True or qt.get("frozen") is not True
                or qt.get("platform") != "windows" or Path(qt["executable"]).resolve() != executable.resolve()
                or qt.get("device_pixel_ratio", 0) < float(scale)):
            return run
        if key and qt.get("draft_sha256") != hashlib.sha256(Path(run["edit"][key]).read_bytes()).hexdigest():
            return run
    run["passed"] = True
    return run


def run_bridge_smoke(executable, cwd, env, evidence, project, godot, include_design=False):
    from godot_bridge import BridgeError, project_manifest, run_child

    fixture = cwd / "하수구 임시 프로젝트"
    fixture.mkdir()
    (fixture / ".rtc-smoke-fixture").touch()
    original = project_manifest(project, Event(), fixture)
    report = evidence / "godot-qt-smoke.json"
    command = [str(executable), "--smoke-bridge", str(report),
               "--bridge-project", str(fixture), "--bridge-godot", str(godot)]
    if include_design:
        command.append("--include-design")
    try:
        code, _ = run_child(command, cwd, env, evidence, "package-godot", Event(), 240)
    except BridgeError as error:
        return {"passed": False, "error": str(error)}
    results = json.loads(report.read_text(encoding="utf-8")) if report.exists() else {}
    return {"exit_code": code, "qt": results, "passed": code == 0 and results.get("passed") is True
            and results.get("frozen") is True and project_manifest(project, Event()) == original}


def verify(archive, output, scales, project=None, godot=None, bridge_repeats=1, include_design=False):
    output.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="rtc-exe-", dir=output))
    result = {"archive": str(archive), "platform": sys.platform, "passed": False}
    try:
        with tempfile.TemporaryDirectory(prefix="RTC Map Editor ") as isolated:
            folder = Path(isolated)
            with ZipFile(archive) as package:
                package.extractall(folder / "unpacked")
            distribution = folder / "unpacked" / "ReturnToCageMapEditor"
            executable = distribution / "ReturnToCageMapEditor.exe"
            result["exe_sha256"] = hashlib.sha256(executable.read_bytes()).hexdigest()
            result["pe_subsystem"] = pe_subsystem(executable)
            if result["pe_subsystem"] != 2:
                raise ValueError("the bootloader must be a windowed PE executable")
            if not (distribution / "_internal" / "python314.dll").is_file():
                raise ValueError("the distribution is missing its Python runtime")

            env = package_environment()
            for name in ("APPDATA", "LOCALAPPDATA"):
                directory = folder / name.lower()
                directory.mkdir()
                env[name] = str(directory)
            cwd = folder / "working directory"
            cwd.mkdir()
            result["isolated_cwd"] = str(cwd)
            result["external_python_on_path"] = bool(shutil.which("python.exe", path=env["PATH"]))
            if result["external_python_on_path"]:
                raise ValueError("unexpected external Python in the smoke environment")

            result["runs"] = [run_smoke(executable, cwd, env, evidence, scale) for scale in scales]
            bridge_runs = result["bridge_runs"] = []
            if project is not None:
                for index in range(1, bridge_repeats + 1):
                    trial = evidence / f"godot-{index:02}"
                    trial.mkdir()
                    with tempfile.TemporaryDirectory(prefix=f"publish {index:02} ", dir=cwd) as isolated_trial:
                        outcome = run_bridge_smoke(executable, Path(isolated_trial), env, trial, project, godot, include_design)
                    bridge_runs.append(outcome)
                    print(f"PACKAGE GODOT {index}/{bridge_repeats}: {outcome['passed']}", flush=True)
                result["bridge"] = bridge_runs[0]
            result["passed"] = all(run["passed"] for run in (*result["runs"], *bridge_runs))
    finally:
        (evidence / "package-verification.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"PACKAGE EVIDENCE {evidence}")
    return int(not result["passed"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--scales", nargs="+", choices=("1", "1.5", "2"), default=("1", "1.5", "2"))
    parser.add_argument("--bridge-project", type=Path)
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--bridge-repeats", type=int, default=1)
    parser.add_argument("--include-design", action="store_true")
    args = parser.parse_args()
    if args.bridge_repeats < 1:
        parser.error("--bridge-repeats must be positive")
    if (args.bridge_project is None) != (args.godot is None):
        parser.error("--bridge-project and --godot must be used together")
    if sys.platform != "win32":
        parser.error("Windows with an interactive desktop is required")
    return verify(args.archive.resolve(strict=True), args.artifacts.resolve(), args.scales,
                  args.bridge_project.resolve(strict=True) if args.bridge_project else None,
                  args.godot.resolve(strict=True) if args.godot else None, args.bridge_repeats, args.include_design)


if __name__ == "__main__":
    raise SystemExit(main())
