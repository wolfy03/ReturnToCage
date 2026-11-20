"""Smoke-test the built zip from an isolated directory with no Python on PATH."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
from zipfile import ZipFile


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


def verify(archive, output):
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

            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(("PYTHON", "QT_", "QML", "GODOT")) and key != "VIRTUAL_ENV"}
            env["PATH"] = str(Path(env["SYSTEMROOT"]) / "System32")
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

            report = evidence / "qt-smoke.json"
            completed = subprocess.run([str(executable), "--smoke-report", str(report)], cwd=cwd,
                                       env=env, timeout=45, check=False)
            result["exit_code"] = completed.returncode
            if report.exists():
                result["qt"] = json.loads(report.read_text(encoding="utf-8"))
            qt = result.get("qt", {})
            result["passed"] = (completed.returncode == 0 and qt.get("passed") is True
                                and qt.get("frozen") is True and qt.get("platform") == "windows"
                                and Path(qt["executable"]).resolve() == executable.resolve())
    finally:
        (evidence / "package-verification.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(f"PACKAGE EVIDENCE {evidence}")
    return int(not result["passed"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Windows with an interactive desktop is required")
    return verify(args.archive.resolve(strict=True), args.artifacts.resolve())


if __name__ == "__main__":
    raise SystemExit(main())
