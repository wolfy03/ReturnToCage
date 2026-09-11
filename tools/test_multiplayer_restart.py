from __future__ import annotations

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
SCENE = "res://tests/integration/multiplayer_restart_probe.tscn"


@dataclass
class ProcessRecord:
    name: str
    process: subprocess.Popen[bytes]
    log_path: Path
    log_file: Any
    pid: int


class RestartProbe:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        suffix = f"_{args.artifact_label}" if args.artifact_label else ""
        self.root = Path(tempfile.mkdtemp(prefix=f"return_to_cage_restart{suffix}_"))
        self.processes: list[ProcessRecord] = []
        self.port = args.port or self._free_port()
        self.labels = [chr(ord("B") + index) for index in range(args.players - 1)]
        self.user_dirs = {"A": self.root / "users" / "host_A"}
        self.user_dirs.update({label: self.root / "users" / f"client_{label}" for label in self.labels})
        for directory in self.user_dirs.values():
            directory.mkdir(parents=True)

    def run(self) -> None:
        seed_host_result = self.root / "two_phase_seed_host.json"
        seed_client_results = {label: self.root / f"seed_client_{label}.json" for label in self.labels}
        release_path = self.root / "resume_release.json"

        seed_host = self.launch(
            "seed-host",
            "A",
            "seed_host",
            seed_host_result,
        )
        self.wait_status(seed_host_result, "host_seed_ready", [seed_host])
        seed_clients = [
            self.launch(
                f"seed-client-{label}",
                label,
                "seed_client",
                seed_client_results[label],
                label=label,
            )
            for label in self.labels
        ]
        self.wait_processes([seed_host, *seed_clients], "phase-one seed/save")
        seed = self.read_status(seed_host_result, "seed_saved")
        client_seed = {
            label: self.read_status(seed_client_results[label], "seed_complete")
            for label in self.labels
        }
        self.validate_seed(seed, client_seed)

        duplicate_user_dir = self.root / "users" / "duplicate_B"
        if "B" in self.user_dirs:
            shutil.copytree(self.user_dirs["B"], duplicate_user_dir)

        resume_host_result = self.root / "resume_host.json"
        resume_client_results = {label: self.root / f"resume_client_{label}.json" for label in self.labels}
        resume_host = self.launch(
            "resume-host",
            "A",
            "resume_host",
            resume_host_result,
            expected=seed_host_result,
            release=release_path,
        )
        self.wait_status(resume_host_result, "host_restore_ready", [resume_host])
        resume_clients = [
            self.launch(
                f"resume-client-{label}",
                label,
                "resume_client",
                resume_client_results[label],
                label=label,
                expected=seed_host_result,
            )
            for label in self.labels
        ]
        for label, process in zip(self.labels, resume_clients):
            self.wait_status(resume_client_results[label], "client_ready", [resume_host, process])

        duplicate_result: dict[str, Any] | None = None
        duplicate_process: ProcessRecord | None = None
        if self.args.duplicate_identity and "B" in self.labels:
            duplicate_path = self.root / "duplicate_B.json"
            duplicate_process = self.launch(
                "duplicate-client-B",
                "duplicate",
                "duplicate_client",
                duplicate_path,
                label="B2",
                user_dir=duplicate_user_dir,
            )
            self.wait_processes([duplicate_process], "duplicate identity rejection")
            duplicate_result = self.read_status(duplicate_path, "duplicate_rejected")

        release_path.write_text(json.dumps({"release": True}), encoding="utf-8")
        self.wait_processes(
            [resume_host, *resume_clients],
            "phase-two host shutdown and client cleanup",
        )
        resumed_host = self.read_status(resume_host_result, "host_final")
        resumed_clients = {
            label: self.read_status(resume_client_results[label], "client_host_disconnect_clean")
            for label in self.labels
        }
        self.validate_resume(
            seed,
            client_seed,
            resumed_host,
            resumed_clients,
            duplicate_result,
            seed_host,
            resume_host,
        )
        self.print_tables(seed, resumed_host, resumed_clients)

    def launch(
        self,
        name: str,
        user_label: str,
        mode: str,
        result: Path,
        *,
        label: str = "",
        expected: Path | None = None,
        release: Path | None = None,
        user_dir: Path | None = None,
    ) -> ProcessRecord:
        selected_user_dir = user_dir or self.user_dirs[user_label]
        log_path = self.root / f"{name}.log"
        log_file = log_path.open("wb")
        command = [
            self.args.godot,
            "--headless",
            "--path",
            str(ROOT),
            SCENE,
            "--",
            f"--mode={mode}",
            f"--port={self.port}",
            f"--players={self.args.players}",
            f"--scenario={self.args.scenario}",
            f"--result={result}",
            f"--timeout={self.args.process_timeout}",
        ]
        if label:
            command.append(f"--label={label}")
        if expected is not None:
            command.append(f"--expected={expected}")
        if release is not None:
            command.append(f"--release={release}")
        environment = os.environ.copy()
        # Godot has no portable --user-data-dir option. These are the native
        # platform roots it uses for user://; each process gets an independent
        # installation directory, reused unchanged across phase one and two.
        environment["APPDATA"] = str(selected_user_dir / "appdata")
        environment["XDG_DATA_HOME"] = str(selected_user_dir / "xdg")
        environment["RTC_TEST_USER_ROOT"] = str(selected_user_dir)
        process = subprocess.Popen(
            command,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=environment,
        )
        record = ProcessRecord(name, process, log_path, log_file, process.pid)
        self.processes.append(record)
        return record

    def wait_status(
        self,
        path: Path,
        expected_status: str,
        watched: list[ProcessRecord],
    ) -> dict[str, Any]:
        deadline = time.monotonic() + self.args.phase_timeout
        last_status = "missing"
        while time.monotonic() < deadline:
            if path.exists():
                try:
                    value = json.loads(path.read_text(encoding="utf-8"))
                    last_status = str(value.get("status", "missing"))
                    if last_status == expected_status:
                        return value
                    if last_status == "failed":
                        raise RuntimeError(f"{path.name}: {value.get('error', 'probe failure')}")
                except json.JSONDecodeError:
                    pass  # Atomic rename should avoid this; tolerate one observation.
            for record in watched:
                if record.process.poll() is not None:
                    self.close_log(record)
                    raise RuntimeError(
                        f"{record.name} exited {record.process.returncode} while waiting for "
                        f"{expected_status} (last status: {last_status})"
                    )
            time.sleep(0.05)
        raise TimeoutError(f"Timeout waiting for {expected_status} in {path.name}; last status={last_status}")

    def wait_processes(self, records: list[ProcessRecord], phase: str) -> None:
        deadline = time.monotonic() + self.args.phase_timeout
        pending = set(record.name for record in records)
        while pending and time.monotonic() < deadline:
            for record in records:
                if record.name in pending and record.process.poll() is not None:
                    self.close_log(record)
                    if record.process.returncode != 0:
                        raise RuntimeError(f"{record.name} failed with exit code {record.process.returncode} during {phase}")
                    pending.remove(record.name)
            time.sleep(0.05)
        if pending:
            raise TimeoutError(f"Timeout during {phase}: still running {', '.join(sorted(pending))}")

    def validate_seed(
        self,
        host: dict[str, Any],
        clients: dict[str, dict[str, Any]],
    ) -> None:
        identities = [host["player_id"], *(clients[label]["player_id"] for label in self.labels)]
        user_paths = [host["profile"]["user_path"], *(clients[label]["profile"]["user_path"] for label in self.labels)]
        process_ids = [host["process_id"], *(clients[label]["process_id"] for label in self.labels)]
        self.require(len(set(identities)) == self.args.players, "phase-one identities are non-empty and distinct")
        self.require(all(identities), "phase-one persistent identities are present")
        self.require(len(set(user_paths)) == self.args.players, "phase-one roles use independent native user directories")
        self.require(len(set(process_ids)) == self.args.players, "phase-one roles run in independent Godot processes")
        self.require(host["canonical_count"] == self.args.players, "Save v4 contains every canonical player")
        self.require(host["active_count"] == self.args.players, "all seed players are attached before Save")
        self.require(host["save_exists"] and bool(host["save_sha256"]), "primary Save v4 was written")
        self.require(not host["registry_errors"], "seed runtime mappings are symmetric")
        self.require(host["profile"]["primary_exists"] and host["profile"]["backup_exists"], "host profile primary/backup exist")
        for label in self.labels:
            client = clients[label]
            self.require(client["profile"]["primary_exists"] and client["profile"]["backup_exists"], f"client {label} profile primary/backup exist")
            record = host["players"].get(client["player_id"], {})
            self.require(record.get("label") == label, f"host Save binds client {label} by persistent player_id")
        save_path = Path(host["profile"]["user_path"]) / "return_to_cage_save.json"
        save_data = json.loads(save_path.read_text(encoding="utf-8"))
        self.require(save_data.get("format_version") == 4, "process seed uses Save v4")
        self.require(len(save_data.get("players", {})) == self.args.players, "Save v4 player count matches process topology")
        forbidden = ("peer_id", "peer_to_player", "player_to_peer", "world_ready_peers")
        serialized = json.dumps(save_data)
        self.require(not any(name in serialized for name in forbidden), "Save v4 excludes runtime peer/cache fields")

    def validate_resume(
        self,
        seed: dict[str, Any],
        client_seed: dict[str, dict[str, Any]],
        host: dict[str, Any],
        clients: dict[str, dict[str, Any]],
        duplicate: dict[str, Any] | None,
        seed_host_process: ProcessRecord,
        resume_host_process: ProcessRecord,
    ) -> None:
        self.require(seed_host_process.pid != resume_host_process.pid, "Host Saved Game runs in a new OS process")
        self.require(host["process_id"] != seed["process_id"], "host probe process ID changes across restart")
        self.require(host["profile"]["user_path"] == seed["profile"]["user_path"], "host restart reuses the same native user directory")
        self.require(host["player_id"] == seed["player_id"], "host persistent player_id survives process restart")
        self.require(host["session_id"] == seed["session_id"], "Saved Host preserves session_id")
        self.require(
            self.values_equal(host["restored_play_time_seconds"], seed["play_time_seconds"]),
            "Saved Host restores play_time_seconds before authoritative ticking resumes",
        )
        self.require(
            self.values_equal(host["restored_host_private"], seed["players"][seed["player_id"]]),
            "Saved Host restores host A private state before gameplay resumes",
        )
        self.require(host["canonical_count"] == self.args.players, "Saved Host preserves canonical registry count")
        self.require(host["active_count"] == self.args.players, "all restarted clients are actively attached")
        self.require(host["world_ready_count"] == self.args.players, "world-ready roster includes exactly active players")
        self.require(host["registry_valid"], "final host runtime registry invariants pass")
        self.require(host["shared"] == seed["shared"], "shared Settlement/quest state survives restart")
        for label in self.labels:
            client = clients[label]
            old = client_seed[label]
            player_id = old["player_id"]
            expected = seed["players"][player_id]
            actual = client["private"]
            self.require(client["player_id"] == player_id, f"client {label} persistent player_id survives process restart")
            self.require(client["process_id"] != old["process_id"], f"client {label} reconnects from a new Godot process")
            self.require(client["profile"]["user_path"] == old["profile"]["user_path"], f"client {label} restart reuses only its own user directory")
            self.require(client["profile"]["primary_exists"] and client["profile"]["backup_exists"], f"client {label} reuses redundant profile files")
            self.require(client["private_sync_complete"] and client["spawn_sync_complete"], f"client {label} completed private/spawn sync")
            self.require(client["session_ready"] and client["world_ready"], f"client {label} becomes ready only after world placement")
            self.require(client["privacy_valid"] and client["registry_valid"], f"client {label} privacy and registry checks pass")
            for field in (
                "health",
                "stats",
                "survival",
                "effects",
                "inventory",
                "protected_inventory",
                "equipment",
                "personal_quest",
            ):
                self.require(self.values_equal(expected[field], actual[field]), f"client {label} restores {field}")
            assignment = client["assignment"]
            self.require(assignment["player_id"] == player_id, f"client {label} spawn assignment is owner-bound")
            self.require(self.values_equal(assignment["position"], client["actor_initial_position"]), f"client {label} actor is placed at authoritative spawn")
            if self.args.scenario == "invalid" and label == "B":
                restart_assignment = client["process_restart_assignment"]
                self.require(restart_assignment["spawn_kind"] == "SETTLEMENT_FALLBACK", "world-invalid B uses deterministic Settlement fallback")
                self.require(restart_assignment["fallback_used"] and restart_assignment["reason"] == "OUT_OF_BOUNDS", "fallback records out-of-bounds reason")
                self.require(self.values_equal(restart_assignment["position"], client["process_restart_actor_position"]), "fallback position is applied to the restarted actor")
                self.require(actual["last_safe_position"] == restart_assignment["position"], "fallback heals B last_safe_position")
                self.require(actual["last_safe_position"] != expected["last_safe_position"], "invalid saved position is not applied")
                self.require(host["players"][player_id]["last_safe_position"] == restart_assignment["position"], "healed fallback reaches host canonical state")
                self.require(assignment["spawn_kind"] == "RETURNING_SAFE_POSITION", "same-session reconnect reuses the healed safe position")
                self.require(assignment["position"] == restart_assignment["position"], "healed fallback is stable on repeated reconnect")
                self.require(host["healed_save_verified"], "healed fallback is persisted by the subsequent Save v4 write")
            else:
                self.require(assignment["spawn_kind"] == "RETURNING_SAFE_POSITION", f"client {label} uses returning safe-position spawn")
                self.require(self.values_equal(assignment["position"], expected["last_safe_position"]), f"client {label} returns to its saved position")
            self.require(host["reattach_counts"][player_id] >= 2, f"client {label} reuses one canonical object across repeated reconnect")
            self.require(client["host_disconnect_clean"], f"client {label} clears session/cache state after host exit")
            self.require(client["post_disconnect_player_ids"] == [player_id], f"client {label} retains only its local identity after host loss")
        if duplicate is not None:
            self.require(duplicate["error"] == "Player identity is already connected", "duplicate active persistent identity is rejected")
            self.require(duplicate["registry_valid"], "duplicate rejection leaves client runtime maps empty")

    def print_tables(
        self,
        seed: dict[str, Any],
        host: dict[str, Any],
        clients: dict[str, dict[str, Any]],
    ) -> None:
        print(f"\nProcess-restart {self.args.players}-player ({self.args.scenario}) PASS")
        print("Field                         Phase1 Save                    Phase2 Reconnect")
        print("----------------------------  -----------------------------  -----------------------------")
        for label in self.labels:
            client = clients[label]
            player_id = client["player_id"]
            expected = seed["players"][player_id]
            fields = [
                ("player_id", player_id[-12:], client["player_id"][-12:]),
                ("canonical object reuse", "saved detached", f"{host['reattach_counts'][player_id]} attaches / one object"),
                ("stats", expected["stats"].get("move_speed"), client["private"]["stats"].get("move_speed")),
                ("survival", expected["survival"], client["private"]["survival"]),
                ("effects", expected["effects"], client["private"]["effects"]),
                ("inventory", expected["inventory"], client["private"]["inventory"]),
                ("protected inventory", expected["protected_inventory"], client["private"]["protected_inventory"]),
                ("equipment", expected["equipment"], client["private"]["equipment"]),
                ("PERSONAL quest", expected["personal_quest"], client["private"]["personal_quest"]),
                ("last_safe", expected["last_safe_position"], client["private"]["last_safe_position"]),
                ("spawn kind", "-", client["assignment"]["spawn_kind"]),
                ("actor placement", "-", client["actor_initial_position"]),
                ("session ready", True, client["session_ready"]),
            ]
            print(f"\nClient {label}")
            for field, before, after in fields:
                print(f"{field:28}  {self.compact(before):29}  {self.compact(after):29}")
        if len(self.labels) >= 2:
            print("\nPrivacy matrix")
            print("B receives B private: PASS | B does not receive C private: PASS")
            print("C receives C private: PASS | C does not receive B private: PASS")

    @staticmethod
    def compact(value: Any, limit: int = 29) -> str:
        text = json.dumps(value, sort_keys=True) if isinstance(value, (dict, list)) else str(value)
        return text if len(text) <= limit else text[: limit - 3] + "..."

    @staticmethod
    def values_equal(left: Any, right: Any) -> bool:
        if isinstance(left, (int, float)) and isinstance(right, (int, float)):
            return abs(float(left) - float(right)) < 0.05
        if isinstance(left, dict) and isinstance(right, dict):
            return left.keys() == right.keys() and all(RestartProbe.values_equal(left[key], right[key]) for key in left)
        if isinstance(left, list) and isinstance(right, list):
            return len(left) == len(right) and all(RestartProbe.values_equal(a, b) for a, b in zip(left, right))
        return left == right

    @staticmethod
    def require(condition: bool, message: str) -> None:
        if not condition:
            raise AssertionError(message)

    @staticmethod
    def _free_port() -> int:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("127.0.0.1", 0))
            return int(sock.getsockname()[1])

    @staticmethod
    def read_status(path: Path, expected_status: str) -> dict[str, Any]:
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("status") != expected_status:
            raise RuntimeError(f"{path.name}: expected {expected_status}, got {value}")
        return value

    @staticmethod
    def close_log(record: ProcessRecord) -> None:
        if not record.log_file.closed:
            record.log_file.close()

    def cleanup_processes(self) -> None:
        for record in self.processes:
            if record.process.poll() is None:
                record.process.terminate()
                try:
                    record.process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    record.process.kill()
                    record.process.wait(timeout=5)
            self.close_log(record)

    def print_failure_logs(self) -> None:
        for record in self.processes:
            self.close_log(record)
            output = record.log_path.read_text(encoding="utf-8", errors="replace") if record.log_path.exists() else ""
            print(f"\n[{record.name}]\n{output[-12000:]}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description="Run real process-restart Saved Host/reconnect E2E probes.")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--players", type=int, choices=(2, 3), default=2)
    parser.add_argument("--scenario", choices=("valid", "invalid"), default="valid")
    parser.add_argument("--port", type=int, default=0, help="Use 0 for a dynamically allocated localhost port.")
    parser.add_argument("--phase-timeout", type=float, default=45.0)
    parser.add_argument("--process-timeout", type=float, default=40.0)
    parser.add_argument("--duplicate-identity", action=argparse.BooleanOptionalAction, default=True)
    parser.add_argument("--keep-artifacts", action="store_true")
    parser.add_argument("--artifact-label", default="")
    args = parser.parse_args()

    probe = RestartProbe(args)
    success = False
    try:
        probe.run()
        success = True
        print(f"Artifacts: {probe.root}" if args.keep_artifacts else "Restart E2E artifacts cleaned after success")
        return 0
    except Exception as exc:
        print(f"Process-restart multiplayer probe failed: {exc}", file=sys.stderr)
        probe.print_failure_logs()
        print(f"Failure artifacts preserved at: {probe.root}", file=sys.stderr)
        return 1
    finally:
        probe.cleanup_processes()
        if success and not args.keep_artifacts:
            shutil.rmtree(probe.root, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
