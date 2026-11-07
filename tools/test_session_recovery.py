"""Repeat GUI/session/world transitions in unchanged Editor or release processes."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
from types import SimpleNamespace
import subprocess
import sys
import tempfile

from test_multiplayer_roster import Probe as RosterController, publish_command
from test_windows_export import ERRORS

ROOT = Path(__file__).resolve().parents[1]


class LifecycleChecks(RosterController):
    def __init__(self, godot: str, executable: Path | None, artifacts: Path,
                 rendered: bool = False, rendering_method: str | None = None) -> None:
        super().__init__(SimpleNamespace(godot=godot, artifacts=artifacts, rendered=rendered))
        self.executable = executable.resolve() if executable else None
        self.rendering_method = rendering_method
        self.worlds: dict[str, str] = {}
        self.active_step: dict = {}

    def launch(self, role: str) -> None:
        if role in self.roles:
            raise RuntimeError("A lifecycle role must never restart its process")
        folder = self.directory / role
        folder.mkdir()
        env = os.environ.copy()
        env.update(APPDATA=str(folder / "appdata"), XDG_DATA_HOME=str(folder / "xdg"),
                   RTC_TEST_USER_ROOT=str(folder))
        command = [str(self.executable)] if self.executable else [self.args.godot, "--path", str(ROOT)]
        if not self.args.rendered:
            command.append("--headless")
        elif self.rendering_method:
            command += ["--rendering-method", self.rendering_method]
        if os.environ.get("RTC_VALIDATION_AUDIO_DRIVER"):
            command += ["--audio-driver", os.environ["RTC_VALIDATION_AUDIO_DRIVER"]]
        command += ["--log-file", str(folder / "engine.log"), "--", "--export-validation=lifecycle",
                    f"--export-result={folder / 'bootstrap.json'}",
                    f"--role={role}", f"--port={self.port}",
                    f"--command={folder / 'command.json'}", f"--result={folder / 'result.json'}"]
        capture = (folder / "process.log").open("wb")
        startup = None
        if sys.platform == "win32":
            startup = subprocess.STARTUPINFO()
            startup.dwFlags |= subprocess.STARTF_USESHOWWINDOW
            startup.wShowWindow = subprocess.SW_HIDE
        process = subprocess.Popen(command, cwd=folder, env=env, stdout=capture,
                                   stderr=subprocess.STDOUT, startupinfo=startup)
        self.roles[role] = {"process": process, "folder": folder, "log_file": capture, "sequence": 0}
        data = self.wait(role, 0, "ready")
        context = data["export_context"]
        if not context.get("content_valid") or "default_game_start" not in context["content_ids"] or not context["difficulty_ids"]:
            raise RuntimeError("Lifecycle process did not validate all mandatory content")
        if self.executable and (context["editor"] or context["debug"]):
            raise RuntimeError("Lifecycle verification requires the actual release EXE")
        if self.args.rendered and data["display_server"] == "headless":
            raise RuntimeError("GUI lifecycle verification ran headless")
        self.roles[role].update(player_id=data["profile_id"], game_pid=data["process_id"],
                                initial_frames=data.get("rendered_frames", 0))
        if len({item["player_id"] for item in self.roles.values()}) != len(self.roles):
            raise RuntimeError("Lifecycle test roles share a persistent identity")

    def call(self, role: str, action: str, **values) -> dict:
        self.active_step = {"role": role, "action": action, **values}
        data = super().call(role, action, **values)
        if data["process_id"] != self.roles[role]["game_pid"]:
            raise RuntimeError("Game process changed during the lifecycle sequence")
        if self.args.rendered and action == "assert_motion" and data.get("rendered_frames", 0) <= self.roles[role]["initial_frames"]:
            raise RuntimeError("Movement/animation checks did not advance GUI rendering frames")
        return data

    def check(self, label: str) -> None:
        for role, world in self.worlds.items():
            expected = [self.roles[r]["player_id"] for r, w in self.worlds.items() if w == world]
            self.call(role, "inspect", expected=expected, world=world, label=label)

    def movement(self, role: str, *, left: bool = False) -> None:
        observers = [r for r, w in self.worlds.items() if w == self.worlds.get(role)] if role in self.worlds else [role]
        for observer in observers:
            self.call(observer, "watch", player=self.roles[role]["player_id"], left=left)
        self.call(role, "move", left=left)
        for observer in observers:
            self.call(observer, "assert_motion")

    def travel(self, role: str, action: str) -> None:
        self.call("A", "place", player=self.roles[role]["player_id"], destination=action)
        self.call(role, action)
        self.worlds[role] = "adventure:sewer_region" if action == "enter" else "settlement"
        self.check(role + " " + action)

    def run(self) -> None:
        try:
            self._run_sequence()
        except (OSError, RuntimeError, subprocess.SubprocessError):
            states = {}
            for role, item in self.roles.items():
                item["log_file"].flush()
                report = item["folder"] / "result.json"
                try:
                    states[role] = json.loads(report.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    states[role] = {"exit": item["process"].poll()}
            failure = {"failed_step": self.active_step, "last_reports": states}
            (self.directory / "failure.json").write_text(json.dumps(failure, indent=2), encoding="utf-8")
            print("SESSION LIFECYCLE FAILURE STATES", json.dumps(failure), flush=True)
            raise

    def race_field_gear(self) -> str:
        for role in ("B", "D"):
            self.call(role, "field_gear_ready")
        self.active_step = {"action": "field_gear_race", "roles": ["B", "D"]}
        # Publish both commands before waiting for either reply.
        for role in ("B", "D"):
            item = self.roles[role]
            item["sequence"] += 1
            publish_command(item["folder"], {"sequence": item["sequence"], "action": "field_gear_race"})
        winners = []
        for role in ("B", "D"):
            item = self.roles[role]
            result = self.wait(role, item["sequence"])
            if result["process_id"] != item["game_pid"] or result["profile_id"] != item["player_id"] or (
                result["protocol"], result["save"], result["profile"]
            ) != (17, 5, 1):
                raise RuntimeError("Craft race changed process, profile or version contract")
            if result["field_gear_won"]:
                winners.append(role)
            self.steps.append({"role": role, "action": "field_gear_race", "result": result})
            print(role, "field_gear_race PASS", flush=True)
        (self.directory / "steps.json").write_text(json.dumps(self.steps, indent=2), encoding="utf-8")
        if len(winners) != 1:
            raise RuntimeError(f"Exactly one request may spend the shared field gear inputs: {winners}")
        return winners[0]

    def _run_sequence(self) -> None:
        self.launch("A")
        self.call("A", "new_game")
        self.call("A", "item_windows")
        self.call("A", "slot_ui")
        self.call("A", "item_seed", player=self.roles["A"]["player_id"], instance="offline-demo-vest")
        self.call("A", "item_ui", operation="equip")
        self.call("A", "field_gear_materials")
        self.call("A", "field_gear_craft")
        for item, stat, value, durability in (("leaf_hat", "defense", 3.0, 30),
                                              ("acorn_necklace", "max_health", 110.0, 40),
                                              ("seed_ring", "stamina_regen", 20.0, 35)):
            self.call("A", "item_ui", operation="equip", item=item, stat=stat, value=value, durability=durability)
        self.movement("A")
        self.call("A", "save_fixture")
        self.call("A", "to_menu")
        self.call("A", "load_game")
        self.call("A", "item_display")
        self.launch("B")
        first_host = self.call("A", "host")  # Loaded single-player -> Host in the same process.
        self.worlds["A"] = "settlement"
        self.call("B", "join", address="127.0.0.1")
        self.worlds["B"] = "settlement"
        self.check("two-player join")
        self.call("A", "item_windows")
        self.call("B", "item_windows")
        self.call("B", "slot_rpc", to=4)
        self.call("B", "slot_rpc", **{"from": 4, "to": 0})
        self.call("A", "slot_transition_fixture", player=self.roles["B"]["player_id"], block=True)
        self.call("B", "slot_ui", reject=True)
        self.call("A", "slot_transition_fixture", player=self.roles["B"]["player_id"], block=False)
        self.call("B", "slot_ui")
        self.call("B", "slot_ui", **{"from": 4, "to": 0})
        self.call("A", "item_seed", player=self.roles["A"]["player_id"], instance="ui-host-vest")
        self.call("A", "item_seed", player=self.roles["B"]["player_id"])
        self.call("B", "item_foreign", instance="ui-host-vest")
        self.call("A", "item_ui", operation="equip")
        self.call("A", "slot_transition_fixture", player=self.roles["B"]["player_id"], block=True)
        self.call("B", "item_ui", operation="equip", reject=True)
        self.call("A", "slot_transition_fixture", player=self.roles["B"]["player_id"], block=False)
        self.call("B", "item_ui", operation="equip", delay_response=True)
        self.call("B", "item_ui", operation="use")
        # Settlement puts the joining client directly to the Host's right.
        # Walk away from each other so both peers can observe a sustained run.
        self.movement("A", left=True)
        self.movement("B")
        self.launch("D")
        self.call("D", "join", address="127.0.0.1")
        self.worlds["D"] = "settlement"
        self.check("three-player late join")
        self.call("A", "field_gear_materials")
        if self.race_field_gear() != "B":
            self.call("A", "field_gear_materials")
            self.call("B", "field_gear_craft")
        self.call("A", "field_gear_save")
        self.call("B", "slot_remember")
        self.call("A", "field_gear_materials")
        self.call("B", "field_gear_replay")
        self.call("B", "field_gear_replay", sequence_offset=-1)
        self.call("B", "disconnect")
        del self.worlds["B"]
        self.call("A", "disconnect")
        self.worlds.clear()
        self.call("D", "check_menu")
        self.call("A", "field_gear_rehost")
        self.worlds["A"] = "settlement"
        for role in ("B", "D"):
            self.call(role, "join", address="127.0.0.1")
            self.worlds[role] = "settlement"
        self.check("craft save and rehost")
        self.call("B", "slot_check")
        for item, stat, value, durability in (("leaf_hat", "defense", 3.0, 30),
                                              ("acorn_necklace", "max_health", 110.0, 40),
                                              ("seed_ring", "stamina_regen", 20.0, 35)):
            self.call("B", "item_ui", operation="equip", item=item, stat=stat, value=value, durability=durability)
        self.call("D", "slot_privacy")
        self.call("B", "item_ui", operation="use", hold_response=True)
        self.travel("B", "enter")
        self.call("B", "item_display")
        self.call("B", "slot_remember")
        self.travel("B", "return")
        self.call("B", "disconnect")
        del self.worlds["B"]
        self.call("B", "join", address="127.0.0.1")
        self.worlds["B"] = "settlement"
        self.check("equipped client reconnects")
        self.call("B", "slot_check")
        self.call("B", "item_display")
        self.call("A", "field_gear_save")
        self.call("A", "disconnect")
        self.worlds.clear()
        for role in ("B", "D"):
            self.call(role, "check_menu")
        self.call("A", "field_gear_rehost")
        self.worlds["A"] = "settlement"
        for role in ("B", "D"):
            self.call(role, "join", address="127.0.0.1")
            self.worlds[role] = "settlement"
        self.check("equipped client restored from Host Save")
        self.call("B", "slot_check")
        self.call("B", "item_display")
        self.call("D", "slot_privacy")
        self.call("D", "slot_remember")
        self.call("A", "slot_seed", player=self.roles["B"]["player_id"])
        self.call("B", "slot_ready")
        self.call("B", "slot_rpc", reject="owner", player=self.roles["D"]["player_id"])
        self.call("B", "slot_rpc", reject="session")
        self.call("B", "slot_rpc", reject="revision")
        self.call("B", "slot_rpc", reject="index", to=999)
        self.call("B", "slot_rpc", reject="instance", **{"from": 5, "to": 12})
        self.call("B", "slot_rpc", reject="quantity", slot_action=3, amount=99)
        self.call("B", "slot_rpc", slot_action=3, amount=2, to=7)
        self.call("B", "slot_rpc", reject="replay")
        self.call("B", "slot_rpc", **{"from": 5, "to": 12})
        self.call("B", "slot_rpc", slot_action=1, **{"from": 2, "to": 12})
        self.call("B", "slot_rpc", slot_action=2, **{"from": 7, "to": 0})
        self.call("B", "slot_rpc", slot_action=4, **{"from": -1, "to": -1})
        self.call("B", "slot_rpc", **{"from": 2, "to": 15})
        self.call("A", "slot_canonical", player=self.roles["B"]["player_id"])
        self.call("D", "slot_privacy")
        self.call("D", "slot_check")
        self.call("B", "slot_remember")
        self.call("B", "slot_prepare")
        self.travel("B", "enter")
        self.call("B", "slot_check")
        self.call("B", "slot_rpc", reject="world")
        self.call("B", "slot_ui")
        self.call("B", "slot_ui", **{"from": 4, "to": 0})
        self.travel("A", "enter")
        self.movement("A")
        self.movement("B")
        self.travel("B", "return")
        self.travel("B", "enter")
        self.check("Sewer re-entry")
        self.call("B", "slot_check")
        self.call("A", "disconnect")
        self.worlds.clear()
        for role in self.roles:
            self.call(role, "check_menu")
        self.call("A", "new_game")
        self.movement("A")
        self.call("A", "to_menu")
        self.call("A", "load_game")
        self.call("A", "item_windows")
        # Confirm both waiting clients stay in their menus while A loads and plays offline.
        for role in ("B", "D"):
            self.call(role, "check_menu")
        self.movement("A")
        self.call("A", "host_saved")
        self.worlds["A"] = "settlement"
        self.call("B", "join", address="127.0.0.1")
        self.worlds["B"] = "settlement"
        self.check("restored host and returning client")
        # D remains disconnected while A and B exercise the saved session.
        self.call("D", "check_menu")
        self.call("A", "slot_seed", player=self.roles["B"]["player_id"])
        self.call("B", "slot_ready")
        self.call("B", "slot_rpc", **{"from": 5, "to": 15})
        self.call("A", "item_seed", player=self.roles["B"]["player_id"])
        self.call("B", "item_ui", operation="equip")
        self.call("B", "slot_remember")
        self.call("A", "slot_transition_fixture", player=self.roles["B"]["player_id"], block=True)
        self.call("B", "item_ui", operation="use", hold_response=True)
        self.call("B", "disconnect")
        del self.worlds["B"]
        self.check("manual client leave")
        self.call("D", "check_menu")
        self.call("B", "new_game")
        self.call("B", "item_windows")
        self.movement("B")
        self.call("B", "to_menu")
        self.call("D", "check_menu")
        self.call("B", "join", address="127.0.0.1")
        self.worlds["B"] = "settlement"
        self.check("same-process client rejoin")
        self.call("B", "slot_check")
        self.call("B", "slot_ui")
        self.call("B", "item_ui", operation="unequip")
        self.call("A", "disconnect")
        self.worlds.clear()
        self.call("B", "check_menu")
        replacement = self.call("D", "host")
        if first_host["session_id"] == replacement["session_id"]:
            raise RuntimeError("Replacement Host reused the old Host session")
        self.worlds["D"] = "settlement"
        self.call("B", "join", address="::1")
        self.worlds["B"] = "settlement"
        self.check("join another Host address")
        # Adjacent Settlement spawns put B directly to D's right. Walk away
        # from B so collision cannot truncate the replicated run to a few ticks.
        self.movement("D", left=True)
        self.movement("B")
        self.call("A", "check_menu")
        self.call("B", "remember", player=self.roles["B"]["player_id"])
        self.call("B", "item_ui", operation="use", hold_response=True)
        self.call("D", "kill", player=self.roles["B"]["player_id"])
        self.call("B", "item_resume")
        self.call("B", "assert_replaced", player=self.roles["B"]["player_id"])
        self.call("B", "disconnect")
        del self.worlds["B"]
        self.check("replacement Host keeps its own roster")
        self.call("D", "disconnect")
        self.worlds.clear()
        self.call("A", "new_game")
        self.call("A", "item_windows")
        rehost = self.call("A", "host")
        if rehost["session_id"] == first_host["session_id"]:
            raise RuntimeError("New Game followed by rehost retained the previous session")
        self.worlds["A"] = "settlement"
        self.call("B", "join", address="127.0.0.1")
        self.worlds["B"] = "settlement"
        self.check("original host rehosts after offline New Game")
        self.call("A", "disconnect")
        self.worlds.clear()
        for role in self.roles:
            self.call(role, "quit")
        for role, item in self.roles.items():
            code = item["process"].wait(timeout=10)
            item["log_file"].close()
            output = (item["folder"] / "engine.log").read_text(encoding="utf-8", errors="replace")
            if code or ERRORS.search(output) or "SESSION LIFECYCLE PROBE PASS" not in output:
                raise RuntimeError(f"{role} exit={code}\n{output}")
        summary = {"status": "pass", "release_exe": bool(self.executable), "rendered": self.args.rendered,
                   "steps": len(self.steps), "process_ids": {r: i["game_pid"] for r, i in self.roles.items()},
                   "manual_two_pc_test": False, "audio_playback_verified": False}
        (self.directory / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print("SESSION LIFECYCLE RECOVERY PASS (3 unchanged processes)", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--rendered", action="store_true")
    parser.add_argument("--rendering-method", choices=("gl_compatibility", "forward_plus"))
    args = parser.parse_args()
    if args.exe and sys.platform != "win32":
        parser.error("Actual Windows EXE execution requires Windows")
    artifacts = args.artifacts or Path(tempfile.mkdtemp(prefix="rtc_lifecycle_")) / "checks"
    checks = LifecycleChecks(args.godot, args.exe, artifacts, args.rendered, args.rendering_method)
    try:
        checks.run()
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("Session lifecycle validation failed:", error, file=sys.stderr)
        return 1
    finally:
        checks.close()


if __name__ == "__main__":
    raise SystemExit(main())
