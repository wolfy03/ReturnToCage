"""Build and validate a pinned Windows release before publishing the demo EXE."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
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


def source_identity(allow_dirty: bool = False) -> dict:
    def git(*arguments: str) -> bytes:
        return subprocess.check_output(["git", *arguments], cwd=ROOT, timeout=15)
    commit = git("rev-parse", "HEAD").decode().strip()
    status = git("status", "--porcelain").decode().strip()
    if status and not allow_dirty:
        raise RuntimeError("Release source is dirty; commit changes first (local preflight may use --allow-dirty)")
    if os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("GITHUB_SHA") != commit:
        raise RuntimeError("GitHub build SHA differs from the checked-out commit")
    fingerprint = hashlib.sha256(git("diff", "--binary", "HEAD"))
    for name in git("ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if name:
            path = ROOT / os.fsdecode(name)
            fingerprint.update(name)
            fingerprint.update(path.read_bytes())
    return {"git_commit": commit, "git_branch": git("branch", "--show-current").decode().strip(),
            "source_dirty": bool(status), "fingerprint": fingerprint.hexdigest()}


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
    parser.add_argument("--rendering-method", choices=("gl_compatibility", "forward_plus"))
    parser.add_argument("--allow-dirty", action="store_true", help="Local preflight only; manifest records source_dirty=true")
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
        source = source_identity(args.allow_dirty)
        run([args.godot, "--headless", "--path", str(ROOT), "--editor", "--quit"], artifacts / "import.log")
        run([args.godot, "--headless", "--path", str(ROOT), "--export-release", "Windows Desktop", str(pending)], artifacts / "export.log")
        manifest = inspect_executable(pending)
        validations = []
        for rendered in ([False, True] if args.rendered else [False]):
            checks = ExportChecks(args.godot, pending, artifacts / ("rendered" if rendered else "headless"),
                                  rendered, args.rendering_method)
            try:
                checks.run()
                content = checks.results["export-content"]
                validations.append({"rendered": rendered, "display_server": content["display_server"],
                                    "rendering_method": content["rendering_method"],
                                    "content_definitions": len(content["content_ids"]),
                                    "content_parity": True, "host_join": True,
                                    "session_recovery": checks.results["lifecycle"]})
            finally:
                checks.close()
        if source_identity(args.allow_dirty) != source:
            raise RuntimeError("Source changed during release validation; refusing publication")
        if inspect_executable(pending) != manifest:
            raise RuntimeError("EXE changed during validation; refusing publication")
        manifest.update({"schema_version": 1, "git_commit": source["git_commit"], "git_branch": source["git_branch"],
                         "source_dirty": source["source_dirty"], "built_at_utc": datetime.now(timezone.utc).isoformat(),
                         "manual_two_pc_test": False, "validations": validations})
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
