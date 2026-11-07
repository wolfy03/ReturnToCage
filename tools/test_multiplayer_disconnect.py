"""Real Boot UI mouse clicks and ENet recovery, without restarting role processes."""
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

from test_multiplayer_roster import publish_command

ROOT = Path(__file__).resolve().parents[1]
SCENE = "res://tests/integration/multiplayer_disconnect_probe.tscn"
ERRORS = re.compile(r"SCRIPT ERROR:|(?:^|\n)(?:ERROR|WARNING):|ObjectDB instances leaked|resources still in use", re.I)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


class Probe:
    def __init__(self, args) -> None:
        self.args = args
        self.directory = args.artifacts or Path(tempfile.mkdtemp(prefix="rtc_disconnect_"))
        self.directory = self.directory.resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.roles: dict[str, dict] = {}
        self.steps: list[dict] = []
        self.port = free_port()

    def launch(self, role: str) -> None:
        folder = self.directory / role
        folder.mkdir()
        env = os.environ.copy()
        env["APPDATA"] = str(folder / "appdata")
        env["XDG_DATA_HOME"] = str(folder / "xdg")
        env["RTC_TEST_USER_ROOT"] = str(folder)
        command = [self.args.godot, "--path", str(ROOT)]
        if not self.args.rendered:
            command.append("--headless")
        else:
            command += ["--rendering-method", self.args.rendering_method]
        command += [SCENE, "--", f"--role={role}", f"--port={self.port}",
                    f"--command={folder / 'command.json'}", f"--result={folder / 'result.json'}"]
        log_file = (folder / "engine.log").open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = subprocess.SW_HIDE
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log_file,
                                   stderr=subprocess.STDOUT, startupinfo=startup)
        self.roles[role] = {"process": process, "folder": folder, "log_file": log_file, "sequence": 0}
        data = self.wait(role, 0, "ready")
        self.roles[role]["player_id"] = data["profile_id"]

    def wait(self, role: str, sequence: int, status: str = "pass") -> dict:
        item = self.roles[role]
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            result = item["folder"] / "result.json"
            if result.exists():
                try:
                    data = json.loads(result.read_text(encoding="utf-8"))
                except (ValueError, OSError):
                    data = {}
                if data.get("status") == "fail":
                    raise RuntimeError(f"{role}: {data}")
                if data.get("sequence") == sequence and data.get("status") == status:
                    return data
            if item["process"].poll() is not None:
                raise RuntimeError(f"{role} exited {item['process'].returncode} before {sequence}/{status}")
            time.sleep(0.03)
        raise RuntimeError(f"{role} timeout waiting for {sequence}/{status}")

    def call(self, role: str, action: str, **values) -> dict:
        item = self.roles[role]
        item["sequence"] += 1
        command = {"sequence": item["sequence"], "action": action, **values}
        publish_command(item["folder"], command)
        data = self.wait(role, item["sequence"])
        if data["profile_id"] != item["player_id"] or (data["protocol"], data["save"], data["profile"]) != (17, 5, 1):
            raise RuntimeError("persistent identity or version contract changed")
        if self.args.rendered and data["display_server"] == "headless":
            raise RuntimeError("rendered GUI verification ran headless")
        self.steps.append({"role": role, "action": action, "result": data})
        (self.directory / "steps.json").write_text(json.dumps(self.steps, indent=2), encoding="utf-8")
        print(role, action, "PASS", flush=True)
        return data

    def run(self) -> None:
        self.launch("A")
        self.launch("B")
        self.call("A", "seed_save")
        self.call("A", "host")
        self.call("B", "join", address="127.0.0.1")
        self.call("A", "adventure")
        self.call("A", "disconnect")
        self.call("B", "check_menu")
        self.call("A", "new_game")
        self.call("A", "stale_callbacks")
        self.call("B", "new_game")
        self.call("A", "to_menu")
        self.call("A", "load_game")
        self.call("A", "to_menu")
        self.call("A", "host")
        self.call("A", "stale_callbacks")
        self.call("B", "to_menu")
        self.call("B", "join", address="127.0.0.1")
        self.call("B", "disconnect")
        self.call("B", "new_game")
        self.call("B", "to_menu")
        self.call("B", "join", address="127.0.0.1")
        self.call("A", "disconnect")
        self.call("B", "check_menu")
        first_save_host = self.call("A", "host_saved")
        self.call("B", "join", address="127.0.0.1")
        self.call("A", "adventure")
        self.call("A", "disconnect")
        self.call("B", "check_menu")
        second_save_host = self.call("A", "host_saved")
        if first_save_host["session_id"] != second_save_host["session_id"]:
            raise RuntimeError("Host Save fixture failed to reuse its saved session ID")
        self.call("B", "join", address="127.0.0.1")
        self.call("A", "disconnect")
        self.call("B", "check_menu")
        self.launch("D")
        self.call("D", "host")
        self.call("B", "join", address="::1")
        self.call("B", "disconnect")
        self.call("B", "new_game")
        self.call("D", "disconnect")
        for role in self.roles:
            self.call(role, "quit")
        for item in self.roles.values():
            code = item["process"].wait(timeout=10)
            item["log_file"].close()
            output = (item["folder"] / "engine.log").read_text(encoding="utf-8", errors="replace")
            if code or ERRORS.search(output) or "DISCONNECT RECOVERY PROBE PASS" not in output:
                raise RuntimeError(f"process exit={code}\n{output}")
        print("MULTIPLAYER DISCONNECT UI RECOVERY PASS (3 persistent processes)", flush=True)

    def close(self) -> None:
        for role, item in self.roles.items():
            if item["process"].poll() is None:
                item["process"].kill()
            item["process"].wait(timeout=5)
            if not item["log_file"].closed:
                item["log_file"].close()
        print("Disconnect recovery artifacts:", self.directory, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--rendered", action="store_true")
    parser.add_argument("--rendering-method", default="gl_compatibility", choices=("gl_compatibility", "forward_plus"))
    probe = Probe(parser.parse_args())
    try:
        probe.run()
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("Disconnect recovery failed:", error, file=sys.stderr)
        return 1
    finally:
        probe.close()


if __name__ == "__main__":
    raise SystemExit(main())
