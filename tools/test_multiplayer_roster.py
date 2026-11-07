"""World-scoped player presentation rosters over real ENet with separate runtime checks."""
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
SCENE = "res://tests/integration/multiplayer_roster_probe.tscn"
ERRORS = re.compile(r"SCRIPT ERROR:|(?:^|\n)(?:ERROR|WARNING):|ObjectDB instances leaked|resources still in use", re.I)


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


class Probe:
    def __init__(self, args) -> None:
        self.args = args
        self.directory = args.artifacts or Path(tempfile.mkdtemp(prefix="rtc_roster_"))
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
        temporary = item["folder"] / "command.tmp"
        temporary.write_text(json.dumps(command), encoding="utf-8")
        # Windows can hold the previous file open during a short Godot read.
        # Retry only the atomic rename; never resend an acknowledged command.
        rename_deadline = time.monotonic() + 3
        while True:
            try:
                temporary.replace(item["folder"] / "command.json")
                break
            except PermissionError:
                if time.monotonic() >= rename_deadline:
                    raise
                time.sleep(0.01)
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
        self.call("A", "host")
        self.launch("B")
        self.call("B", "join", address="127.0.0.1")
        worlds = {"A": "settlement", "B": "settlement"}
        if self.args.players == 3:
            self.launch("C")
            self.call("C", "join", address="127.0.0.1")
            worlds["C"] = "settlement"

        def check(label):
            for role, world in worlds.items():
                expected = [self.roles[r]["player_id"] for r, w in worlds.items() if w == world]
                self.call(role, "inspect", expected=expected, world=world, label=label)

        def travel(role, action):
            self.call("A", "place", player=self.roles[role]["player_id"], destination=action)
            self.call(role, action)
            worlds[role] = "adventure:sewer_region" if action == "enter" else "settlement"
            check(role + " " + action)

        def movement(role):
            observers = [r for r in worlds if worlds[r] == worlds[role]]
            for observer in observers:
                self.call(observer, "watch", player=self.roles[role]["player_id"])
            self.call(role, "move")
            for observer in observers:
                self.call(observer, "assert_motion")

        check("initial join")
        movement("A")
        movement("B")
        travel("B", "enter")
        travel("B", "return")
        movement("B")
        travel("A", "enter")
        travel("B", "enter")
        movement("A")
        movement("B")
        travel("A", "return")
        travel("B", "return")
        if self.args.players == 3:
            self.call("C", "disconnect")
            del worlds["C"]
            check("late join preparation")
            self.call("C", "join", address="127.0.0.1")
            worlds["C"] = "settlement"
            check("late join")
            travel("C", "enter")
            travel("C", "return")
            movement("C")
            travel("C", "enter")
        for role in worlds:
            self.call(role, "remember", player=self.roles["B"]["player_id"])
        self.call("A", "kill", player=self.roles["B"]["player_id"])
        check("same world death respawn")
        for role in worlds:
            if worlds[role] == "settlement":
                self.call(role, "assert_replaced", player=self.roles["B"]["player_id"])
        movement("B")
        travel("B", "enter")
        self.call("A", "kill", player=self.roles["B"]["player_id"])
        check("Adventure death respawn")
        movement("B")
        travel("B", "return")
        self.call("B", "disconnect")
        del worlds["B"]
        check("detach")
        self.call("B", "join", address="127.0.0.1")
        worlds["B"] = "settlement"
        check("persistent identity reconnect")
        movement("B")
        self.call("A", "repeat_arrival")
        check("duplicate roster delivery")
        for role in worlds:
            self.call(role, "invalid_roster")
        check("invalid roster ignored")
        for role in list(worlds):
            if role != "A":
                self.call(role, "disconnect")
                del worlds[role]
                check("final client detach")
        self.call("A", "disconnect")
        for role in self.roles:
            self.call(role, "quit")
        for item in self.roles.values():
            code = item["process"].wait(timeout=10)
            item["log_file"].close()
            output = (item["folder"] / "engine.log").read_text(encoding="utf-8", errors="replace")
            if code or ERRORS.search(output) or "PLAYER ROSTER PROBE PASS" not in output:
                raise RuntimeError(f"process exit={code}\n{output}")
        print(f"PLAYER PRESENTATION ROSTER PASS ({self.args.players} ENet processes)", flush=True)

    def close(self) -> None:
        for role, item in self.roles.items():
            if item["process"].poll() is None:
                item["process"].kill()
            item["process"].wait(timeout=5)
            if not item["log_file"].closed:
                item["log_file"].close()
        print("Player roster artifacts:", self.directory, flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--players", type=int, choices=(2, 3), default=2)
    parser.add_argument("--rendered", action="store_true")
    parser.add_argument("--rendering-method", default="gl_compatibility", choices=("gl_compatibility", "forward_plus"))
    probe = Probe(parser.parse_args())
    try:
        probe.run()
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("Player roster failed:", error, file=sys.stderr)
        return 1
    finally:
        probe.close()


if __name__ == "__main__":
    raise SystemExit(main())
