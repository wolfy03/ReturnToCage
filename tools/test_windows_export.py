"""Execute the actual release EXE outside the project with isolated user roots.

Tests resource ID parity against Editor and both Export/Export and Editor/Export
ENet directions. Never reports Windows execution success on another OS.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
ERRORS = re.compile(r"SCRIPT ERROR:|(?:^|\n)(?:ERROR|WARNING):|Parse Error|ObjectDB instances leaked|resources still in use", re.I)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


class ExportChecks:
    def __init__(self, godot: str, executable: Path, artifacts: Path, rendered: bool = False,
                 rendering_method: str | None = None) -> None:
        self.godot = godot
        self.executable = executable.resolve()
        self.artifacts = artifacts.resolve()
        self.artifacts.mkdir(parents=True, exist_ok=True)
        self.processes: list[tuple[subprocess.Popen, Path, Path]] = []
        self.results: dict[str, dict] = {}
        self.rendered = rendered
        self.rendering_method = rendering_method

    def launch(self, name: str, mode: str, editor: bool, port: int = 0, release: Path | None = None):
        directory = self.artifacts / name
        directory.mkdir()
        report, log = directory / "result.json", directory / "engine.log"
        environment = os.environ.copy()
        # Godot's native user:// selection is isolated before autoloads start.
        environment["APPDATA"] = str(directory / "appdata")
        environment["XDG_DATA_HOME"] = str(directory / "xdg")
        environment["RTC_TEST_USER_ROOT"] = str(directory)
        command = [self.godot, "--path", str(ROOT)] if editor else [str(self.executable)]
        if not self.rendered:
            command.append("--headless")
        elif self.rendering_method:
            command += ["--rendering-method", self.rendering_method]
        if os.environ.get("RTC_VALIDATION_AUDIO_DRIVER"):
            command += ["--audio-driver", os.environ["RTC_VALIDATION_AUDIO_DRIVER"]]
        command += ["--log-file", str(log), "--", f"--export-validation={mode}", f"--export-result={report}"]
        if port:
            command.append(f"--export-port={port}")
        if release:
            command.append(f"--export-release={release}")
        capture = (directory / "process.log").open("wb")
        try:
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = subprocess.SW_HIDE
            process = subprocess.Popen(command, cwd=directory, env=environment, stdout=capture, stderr=subprocess.STDOUT, startupinfo=startup)
        finally:
            capture.close()
        record = (process, report, log)
        self.processes.append(record)
        return record

    @staticmethod
    def wait_status(record, status: str, timeout: float = 25.0) -> dict:
        process, report, log = record
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            data = {}
            if report.exists():
                try:
                    data = json.loads(report.read_text(encoding="utf-8"))
                except (ValueError, OSError):
                    pass
            if data.get("status") == "fail":
                raise RuntimeError(str(data))
            if data.get("status") == status:
                return data
            if process.poll() is not None:
                raise RuntimeError(f"process exited {process.returncode} before {status}: {log.read_text(encoding='utf-8', errors='replace') if log.exists() else log}")
            time.sleep(0.05)
        raise RuntimeError(f"timeout waiting for {status}: {log}")

    def finish(self, name: str, record) -> dict:
        data = self.wait_status(record, "pass")
        process, _, log = record
        code = process.wait(timeout=10)
        output = log.read_text(encoding="utf-8", errors="replace")
        if code or ERRORS.search(output) or "EXPORT VALIDATION PASS" not in output:
            raise RuntimeError(f"{name} exit={code}\n{output}")
        if (data["protocol"], data["save"], data["profile"]) != (16, 4, 1):
            raise RuntimeError(f"version contract changed: {data}")
        if self.rendered and data["display_server"] == "headless":
            raise RuntimeError("rendered startup was requested but only headless execution occurred")
        if self.rendered and data.get("rendered_frames", 0) <= 0:
            raise RuntimeError("GUI validation produced no rendered frames")
        self.results[name] = data
        print(name, "PASS", flush=True)
        return data

    def run(self) -> None:
        editor = self.finish("editor-content", self.launch("editor-content", "content", True))
        exported = self.finish("export-content", self.launch("export-content", "content", False))
        if editor["content_ids"] != exported["content_ids"] or editor["difficulty_ids"] != exported["difficulty_ids"]:
            raise RuntimeError("Editor/Export content ID roster differs")
        if exported["editor"] or exported["debug"]:
            raise RuntimeError("tested EXE is not a release export")
        if not exported["content_valid"] or "default_game_start" not in exported["content_ids"]:
            raise RuntimeError("Export omitted mandatory dynamic content")
        print(f"EDITOR/EXPORT CONTENT PARITY PASS ({len(exported['content_ids'])} IDs)", flush=True)
        for label, host_editor, client_editor in [
            ("exe-exe", False, False), ("editor-exe", True, False), ("exe-editor", False, True)
        ]:
            release = self.artifacts / f"{label}-release"
            port = free_port()
            host = self.launch(f"{label}-host", "host", host_editor, port, release)
            self.wait_status(host, "listening")
            client = self.launch(f"{label}-client", "client", client_editor, port, release)
            host_data = self.wait_status(host, "ready")
            client_data = self.wait_status(client, "ready")
            if host_data["session_id"] != client_data["session_id"]:
                raise RuntimeError("Host and client accepted different sessions")
            if host_data["player_id"] == client_data["player_id"] or host_data["user_path"] == client_data["user_path"]:
                raise RuntimeError("Export probe mixed user directories or identities")
            if not all(client_data.get(key) for key in ["session_snapshot", "private_snapshot", "world_assignment", "settlement_loaded", "environment_loaded"]):
                raise RuntimeError("Client sync stages were not all verified")
            release.touch()
            self.finish(f"{label}-host", host)
            self.finish(f"{label}-client", client)
        # Keep every original content/Editor/EXE check above. The additional
        # lifecycle uses the same release binary outside the source directory.
        from test_session_recovery import LifecycleChecks
        lifecycle = LifecycleChecks(self.godot, self.executable, self.artifacts / "lifecycle",
                                    self.rendered, self.rendering_method)
        try:
            lifecycle.run()
            self.results["lifecycle"] = json.loads((lifecycle.directory / "summary.json").read_text(encoding="utf-8"))
        finally:
            lifecycle.close()
        (self.artifacts / "summary.json").write_text(json.dumps(self.results, indent=2), encoding="utf-8")

    def close(self) -> None:
        for process, _, _ in self.processes:
            if process.poll() is None:
                process.kill()
            process.wait(timeout=5)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--exe", type=Path, default=ROOT / "build/windows/ReturnToCage_Demo.exe")
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--rendered", action="store_true", help="Also initialize the default Windows graphics driver, without --headless")
    parser.add_argument("--rendering-method", choices=("gl_compatibility", "forward_plus"))
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("Windows EXE execution requires Windows; no PASS can be reported here")
    artifacts = args.artifacts or Path(tempfile.mkdtemp(prefix="return_to_cage_export_")) / "checks"
    checks = ExportChecks(args.godot, args.exe, artifacts, args.rendered, args.rendering_method)
    try:
        checks.run()
        print("WINDOWS RELEASE EXPORT CHECKS PASS", flush=True)
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Windows export check failed: {error}", file=sys.stderr)
        return 1
    finally:
        checks.close()
        print("Export validation artifacts:", checks.artifacts, flush=True)


if __name__ == "__main__":
    raise SystemExit(main())
