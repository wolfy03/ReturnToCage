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
import time

import loopback_policy
from test_multiplayer_roster import Probe as RosterController, publish_command
from test_windows_export import ERRORS

ROOT = Path(__file__).resolve().parents[1]

# A buff's remaining time and the Host's clock are sampled a frame apart, and the buff ticks once per
# rendered frame: allow that much disagreement, no more.
BUFF_CLOCK_TOLERANCE_SECONDS = 1.0
BUFF_RATE_TOLERANCE = 0.15
INJECTIONS = ("buff-delay", "stall-observer", "hold-result")


def blocked_tick_problem(before: dict, after: dict) -> str:
    """Why two authoritative samples of one player do *not* show a simulation that kept running.

    Returns "" when they do. ``before`` and ``after`` are ``input_sample`` dictionaries taken while that
    player's own UI blocked its input. Each quantity is judged by what it can show:

    - snapshots: the sequence must have advanced.
    - hunger, thirst: must have gone down - unless the value was already at its minimum, which says
      nothing either way and is reported as such instead of being read as "stopped".
    - the buff: its remaining time must have gone down by the time that passed on the Host's clock. A
      buff that is gone is fine exactly when more time passed than it had left (it ran out); gone
      earlier than that, or unchanged, or draining at another rate, is a failure.
    """
    for key in ("actor_instance", "world", "world_revision", "player_id"):
        if before.get(key) != after.get(key):
            return f"the two samples are not of the same actor in the same world ({key}: {before.get(key)} -> {after.get(key)})"
    if not after["snapshot"] > before["snapshot"]:
        return f"no transform snapshot was produced (sequence {before['snapshot']} -> {after['snapshot']})"
    for need in ("hunger", "thirst"):
        if before[need] <= 0.0:
            return f"{need} was already at its minimum; this window cannot show whether survival ticks ran"
        if not after[need] < before[need]:
            return f"{need} did not go down ({before[need]} -> {after[need]}): survival ticks stopped"
    if "ticks_msec" not in before or "ticks_msec" not in after:
        return "the samples carry no Host clock, so a buff that ran out cannot be told from one that vanished"
    elapsed = (after["ticks_msec"] - before["ticks_msec"]) / 1000.0
    had, has = before["quick_paws"], after["quick_paws"]
    if had <= 0.0:
        return "the buff was not active at the first sample; this window cannot show whether its time ran"
    if has < 0.0:                                     # the effect is gone
        if elapsed + BUFF_CLOCK_TOLERANCE_SECONDS >= had:
            return ""                                 # it ran out: {had} s were left and {elapsed} s passed
        return f"the buff disappeared with {had:.2f} s left after only {elapsed:.2f} s"
    if not 0.0 < has < had:
        return f"the buff's time did not go down ({had} -> {has} in {elapsed:.2f} s): buff ticks stopped"
    drained = had - has
    if abs(drained - elapsed) > BUFF_CLOCK_TOLERANCE_SECONDS + BUFF_RATE_TOLERANCE * elapsed:
        return f"the buff lost {drained:.2f} s while {elapsed:.2f} s passed on the Host"
    return ""


class LifecycleChecks(RosterController):
    def __init__(self, godot: str, executable: Path | None, artifacts: Path,
                 rendered: bool = False, rendering_method: str | None = None,
                 address: str = loopback_policy.IPV4_LOOPBACK, ipv6_mode: str = "auto",
                 inject: dict[str, float] | None = None) -> None:
        super().__init__(SimpleNamespace(godot=godot, artifacts=artifacts, rendered=rendered))
        self.loopback = loopback_policy.resolve(address, ipv6_mode)
        print("LOOPBACK", self.loopback.describe(), flush=True)
        self.executable = executable.resolve() if executable else None
        self.rendering_method = rendering_method
        self.worlds: dict[str, str] = {}
        self.active_step: dict = {}
        # Reproduction aids (``--inject``). None of them changes what is asserted.
        self.inject = dict(inject or {})
        self.tick_checks: list[dict] = []

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

    def hold_result(self, role: str, seconds: float) -> None:
        """Reproduction aid: keep ``result.json`` open the way a reader or a scanner would."""
        with (self.roles[role]["folder"] / "result.json").open("rb"):
            time.sleep(seconds)

    def check(self, label: str) -> None:
        for role, world in self.worlds.items():
            expected = [self.roles[r]["player_id"] for r, w in self.worlds.items() if w == world]
            self.call(role, "inspect", expected=expected, world=world, label=label)

    def movement(self, role: str, *, left: bool = False) -> None:
        observers = [r for r, w in self.worlds.items() if w == self.worlds.get(role)] if role in self.worlds else [role]
        for observer in observers:
            self.call(observer, "watch", player=self.roles[role]["player_id"], left=left)
        if self.inject.get("stall-observer"):
            # A starved observer: it runs no frame while the other player moves.
            for observer in observers:
                if observer != role:
                    self.call(observer, "stall", msec=int(self.inject["stall-observer"]))
        self.call(role, "move", left=left)
        for observer in observers:
            self.call(observer, "assert_motion")

    def authority_input(self, role: str, axis: int = 0, **requirements) -> dict:
        player = self.roles[role]["player_id"]
        return self.call("A", "input_authority", player=player, axis=axis, **requirements)["input_sample"]

    def input_windows(self, role: str, *, bag: bool = False, gear: bool = False, escape: bool = False) -> None:
        self.call(role, "input_windows", bag=bag, gear=gear, escape=escape)

    def input_key(self, role: str, key: str, pressed: bool | None = None, **values) -> None:
        if pressed is not None:
            values["pressed"] = pressed
        self.call(role, "input_key", key=key, **values)

    def start_input_movement(self, role: str, *, left: bool = False) -> dict:
        origin = self.authority_input(role)
        self.input_key(role, "left" if left else "right", True)
        return self.authority_input(role, -1 if left else 1, after=origin["sequence"], from_x=origin["x"])

    def verify_input_isolation(self, *, third: bool) -> None:
        self.input_windows("B")
        self.input_windows("A", gear=True)
        for role, position in (("A", 1100), ("B", 800), ("D", 180)):
            if role in self.worlds:
                self.call("A", "input_place", player=self.roles[role]["player_id"], x=position,
                          effect=role == "B" and third)
        self.input_key("A", "left", True)
        host_blocked = self.authority_input("A")
        moving = self.start_input_movement("B")
        self.authority_input("A", after=host_blocked["sequence"])
        if third:
            self.start_input_movement("D")
            self.input_key("D", "right", False)
            self.authority_input("D")
        self.input_key("A", "left", False)

        self.input_windows("B", bag=True)
        if third:
            # The buff's clock starts here, next to the sample it is compared with, instead of
            # several steps earlier: how long those steps take is the runner's business.
            self.call("A", "input_effect", player=self.roles["B"]["player_id"])
        neutral = self.authority_input("B", after=moving["sequence"])
        self.call("B", "input_blocked_edges")
        self.input_windows("A", escape=True)
        self.start_input_movement("A")
        self.input_key("A", "right", False)
        self.authority_input("A")
        if third:
            self.call("A", "input_place", player=self.roles["D"]["player_id"], x=670)
            self.start_input_movement("D", left=True)
            self.input_key("D", "left", False)
            self.authority_input("D")
            self.call("A", "item_seed", player=self.roles["B"]["player_id"], instance="input-isolation-vest")
            self.call("B", "item_ui", operation="equip")
            self.call("B", "input_storage")
            self.call("D", "slot_privacy")
            self.input_key("D", "interact", expect_interact=True)
            self.input_key("D", "attack")
            self.authority_input("D", attack=0, attack_executed=1, ready_action=True)
            self.input_key("D", "dodge")
            self.authority_input("D", dodge=0, dodge_executed=1, ready_action=True)

        self.input_windows("B", bag=True, gear=True)
        self.input_windows("B", gear=True)
        if third and self.inject.get("buff-delay"):
            time.sleep(self.inject["buff-delay"])     # a slow runner: the blocked window outlasts the buff
        still_neutral = self.authority_input("B", after=neutral["sequence"])
        if any(still_neutral[edge] != moving[edge] for edge in ("jump", "attack", "dodge")):
            raise RuntimeError("Blocked B reached an authoritative action receiver")
        if third:
            problem = blocked_tick_problem(neutral, still_neutral)
            self.tick_checks.append({"before": neutral, "after": still_neutral, "problem": problem})
            (self.directory / "tick_checks.json").write_text(json.dumps(self.tick_checks, indent=2), encoding="utf-8")
            if problem:
                raise RuntimeError("B's blocked UI stopped authority, survival, or buff ticks: " + problem)
        self.input_windows("B", escape=True)
        self.authority_input("B", after=still_neutral["sequence"])
        if third:
            self.input_key("B", "jump")
            self.authority_input("B", jump=still_neutral["jump"] + 1)
        self.input_key("B", "right", False)
        self.start_input_movement("B", left=True)
        self.input_key("B", "left", False)
        self.authority_input("B")
        if third:
            self.authority_input("B", ready_action=True)
            self.input_key("B", "attack")
            self.authority_input("B", attack=still_neutral["attack"] + 1, attack_executed=1, ready_action=True)
            self.input_key("B", "dodge")
            self.authority_input("B", dodge=still_neutral["dodge"] + 1, dodge_executed=1, ready_action=True)
        self.input_windows("A", bag=True, gear=True)
        self.input_windows("B", bag=True, gear=True)

    def travel(self, role: str, action: str) -> None:
        self.call("A", "place", player=self.roles[role]["player_id"], destination=action)
        self.call(role, action)
        self.worlds[role] = "adventure:sewer_region" if action == "enter" else "settlement"
        self.check(role + " " + action)

    def run(self, world_drop_only: bool = False) -> None:
        try:
            if world_drop_only:
                self._run_world_drop()
            else:
                self._run_sequence()
        except (OSError, RuntimeError, subprocess.SubprocessError):
            states = {}
            for role, item in self.roles.items():
                if not item["log_file"].closed:
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
            ) != (20, 5, 1):
                raise RuntimeError("Craft race changed process, profile or version contract")
            if result["field_gear_won"]:
                winners.append(role)
            self.steps.append({"role": role, "action": "field_gear_race", "result": result})
            print(role, "field_gear_race PASS", flush=True)
        (self.directory / "steps.json").write_text(json.dumps(self.steps, indent=2), encoding="utf-8")
        if len(winners) != 1:
            raise RuntimeError(f"Exactly one request may spend the shared field gear inputs: {winners}")
        return winners[0]

    def _check_world_drop(self) -> None:
        self.call("A", "slot_seed", player=self.roles["B"]["player_id"])
        self.call("B", "slot_ready")
        self.call("B", "slot_ui", world_drop=True)
        self.call("A", "slot_drop_observe", player=self.roles["B"]["player_id"])

    def _run_world_drop(self) -> None:
        self.launch("A")
        self.call("A", "host")
        self.worlds["A"] = "settlement"
        self.launch("B")
        self.call("B", "join", address=self.loopback.primary)
        self.worlds["B"] = "settlement"
        self.check("two-player drop fixture")
        self._check_world_drop()
        self.call("A", "disconnect")
        self.worlds.clear()
        self.call("B", "check_menu")
        self._finish_processes()

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
        self.call("A", "save_fixture", require_input_block=True)
        self.call("A", "to_menu")
        self.call("A", "load_game")
        self.call("A", "item_display")
        self.launch("B")
        first_host = self.call("A", "host")  # Loaded single-player -> Host in the same process.
        self.worlds["A"] = "settlement"
        self.call("B", "join", address=self.loopback.primary)
        self.worlds["B"] = "settlement"
        self.check("two-player join")
        if self.inject.get("hold-result"):
            # B answers the next command while its previous result file is held open.
            item = self.roles["B"]
            item["sequence"] += 1
            publish_command(item["folder"], {"sequence": item["sequence"], "action": "noop"})
            self.hold_result("B", self.inject["hold-result"])
            self.wait("B", item["sequence"])
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
        self.verify_input_isolation(third=False)
        self.launch("D")
        self.call("D", "join", address=self.loopback.primary)
        self.worlds["D"] = "settlement"
        self.check("three-player late join")
        self.verify_input_isolation(third=True)
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
            self.call(role, "join", address=self.loopback.primary)
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
        self.input_windows("A", gear=True)
        self.call("A", "input_world_tick", player=self.roles["B"]["player_id"])
        self.input_windows("A", escape=True)
        self.call("B", "item_display")
        self.call("B", "slot_remember")
        self.travel("B", "return")
        self.call("B", "disconnect")
        del self.worlds["B"]
        self.call("B", "join", address=self.loopback.primary)
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
            self.call(role, "join", address=self.loopback.primary)
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
        self.call("B", "join", address=self.loopback.primary)
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
        self.input_key("B", "right", True)
        self.call("B", "disconnect")
        del self.worlds["B"]
        self.check("manual client leave")
        self.call("D", "check_menu")
        self.call("B", "new_game")
        self.call("B", "input_authority", held_right=True)
        self.input_key("B", "right", False)
        self.call("B", "item_windows")
        self.movement("B")
        self.call("B", "to_menu")
        self.call("D", "check_menu")
        self.call("B", "join", address=self.loopback.primary)
        self.worlds["B"] = "settlement"
        self.check("same-process client rejoin")
        self.start_input_movement("B")
        self.input_key("B", "right", False)
        self.authority_input("B")
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
        # Second address form: IPv6 loopback where available (loopback_policy).
        self.call("B", "join", address=self.loopback.alternate)
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
        self.call("B", "join", address=self.loopback.primary)
        self.worlds["B"] = "settlement"
        self.check("original host rehosts after offline New Game")
        self._check_world_drop()
        self.call("A", "disconnect")
        self.worlds.clear()
        self._finish_processes()

    def _finish_processes(self) -> None:
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
                   "manual_two_pc_test": False, "audio_playback_verified": False,
                   "loopback": self.loopback.to_summary()}
        (self.directory / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
        print(f"SESSION LIFECYCLE RECOVERY PASS ({len(self.roles)} unchanged processes; {self.loopback.describe()})", flush=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--exe", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--rendered", action="store_true")
    parser.add_argument("--world-drop-only", action="store_true", help="Exercise a Client GUI drop and the Host replica.")
    parser.add_argument("--rendering-method", choices=("gl_compatibility", "forward_plus"))
    parser.add_argument("--inject", action="append", default=[], metavar="NAME=VALUE",
                        help="Reproduction aid, repeatable: buff-delay=<seconds> (wait before the second blocked-UI "
                             "sample), stall-observer=<msec> (the watching process runs no frame while the other "
                             "player moves), hold-result=<seconds> (hold B's result file open while B publishes).")
    loopback_policy.add_arguments(parser)
    args = parser.parse_args()
    if args.exe and sys.platform != "win32":
        parser.error("Actual Windows EXE execution requires Windows")
    inject = {}
    for entry in args.inject:
        name, _, value = entry.partition("=")
        if name not in INJECTIONS or not value:
            parser.error(f"--inject takes one of {', '.join(INJECTIONS)} as NAME=VALUE")
        inject[name] = float(value)
    artifacts = args.artifacts or Path(tempfile.mkdtemp(prefix="rtc_lifecycle_")) / "checks"
    try:
        checks = LifecycleChecks(args.godot, args.exe, artifacts, args.rendered, args.rendering_method,
                                 args.address, args.ipv6, inject)
    except (RuntimeError, ValueError) as error:
        print("Session lifecycle validation failed:", error, file=sys.stderr)
        return 1
    try:
        checks.run(world_drop_only=args.world_drop_only)
        return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print("Session lifecycle validation failed:", error, file=sys.stderr)
        return 1
    finally:
        checks.close()


if __name__ == "__main__":
    raise SystemExit(main())
