"""Build and validate a pinned Windows release before publishing the demo EXE."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

from test_windows_export import ERRORS, ExportChecks

ROOT = Path(__file__).resolve().parents[1]


def run(command: list[str], log: Path) -> None:
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=180)
    output = result.stdout.decode("utf-8", errors="replace")
    log.write_text(output, encoding="utf-8")
    if result.returncode or ERRORS.search(output):
        raise RuntimeError(f"Command failed: {subprocess.list2cmdline(command)}\n{output}")


def inspect_executable(path: Path) -> dict:
    with path.open("rb") as file:
        if file.read(2) != b"MZ":
            raise RuntimeError("Export is not a Windows PE executable")
        file.seek(0x3C)
        header = struct.unpack("<I", file.read(4))[0]
        file.seek(header)
        if file.read(4) != b"PE\0\0" or struct.unpack("<H", file.read(2))[0] != 0x8664:
            raise RuntimeError("Export is not Windows x86_64")
        file.seek(-12, 2)
        pack_size, magic = struct.unpack("<Q4s", file.read(12))
    if magic != b"GDPC" or not 0 < pack_size < path.stat().st_size:
        raise RuntimeError("Export has no valid embedded PCK footer")
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return {"architecture": "x86_64", "embedded_pck": True, "size": path.stat().st_size,
            "sha256": digest.hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--output", type=Path, default=ROOT / "build/windows/ReturnToCage_Demo.exe")
    parser.add_argument("--rendered", action="store_true", help="Verify the default Windows renderer as well as headless execution")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("This release validation requires actual Windows EXE execution")
    version = (ROOT / ".godot-version").read_text().strip()
    actual = subprocess.check_output([args.godot, "--version"], text=True, timeout=15).strip()
    if not actual.startswith(version + "."):
        raise RuntimeError(f"Expected Godot {version}; found {actual}")
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    validation_root = ROOT / "build/validation"
    validation_root.mkdir(parents=True, exist_ok=True)
    artifacts = Path(tempfile.mkdtemp(prefix="windows-release-", dir=validation_root))
    pending = output.with_name(output.stem + ".pending.exe")
    try:
        run([args.godot, "--headless", "--path", str(ROOT), "--editor", "--quit"], artifacts / "import.log")
        run([args.godot, "--headless", "--path", str(ROOT), "--export-release", "Windows Desktop", str(pending)], artifacts / "export.log")
        manifest = inspect_executable(pending)
        for rendered in ([False, True] if args.rendered else [False]):
            checks = ExportChecks(args.godot, pending, artifacts / ("rendered" if rendered else "headless"), rendered)
            try:
                checks.run()
            finally:
                checks.close()
        pending.replace(output)
        manifest.update({"engine": actual, "protocol": 16, "save": 4, "profile": 1,
                         "release": True, "validation_artifacts": str(artifacts),
                         "rendered_checked": args.rendered})
        (output.parent / "build_manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        (output.parent / "SHA256SUMS.txt").write_text(f"{manifest['sha256']}  {output.name}\n", encoding="utf-8")
        print("WINDOWS DEMO BUILD AND EXE VALIDATION PASS", output, flush=True)
        print(json.dumps(manifest, indent=2), flush=True)
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        return 1
    finally:
        print("Build validation artifacts:", artifacts, flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
