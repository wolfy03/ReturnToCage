from __future__ import annotations

import argparse
import socket
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENE = "res://tests/integration/multiplayer_world_runtime_probe.tscn"


def free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def wait_for_marker(process: subprocess.Popen[bytes], path: Path, marker: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"host exited before {marker} (exit {process.returncode})")
        if path.exists() and marker in path.read_text(encoding="utf-8", errors="replace"):
            return
        time.sleep(0.05)
    raise RuntimeError(f"timeout waiting for {marker}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run world-scoped runtime ENet processes.")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--players", type=int, choices=(2, 3), default=2)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--timeout", type=float, default=50.0)
    args = parser.parse_args()
    port = args.port if args.port > 0 else free_port()
    common = [
        args.godot, "--headless", "--path", str(ROOT), SCENE, "--",
        f"--port={port}", f"--players={args.players}",
    ]
    processes: list[tuple[str, subprocess.Popen[bytes], Path, object]] = []
    with tempfile.TemporaryDirectory(prefix="return_to_cage_world_runtime_") as temporary:
        try:
            def launch(name: str, role: str, index: int) -> None:
                log_path = Path(temporary) / f"{name}.log"
                profile_path = Path(temporary) / f"{name}-profile.json"
                log_file = log_path.open("wb")
                process = subprocess.Popen(
                    common + [f"--role={role}", f"--index={index}", f"--local-profile-path={profile_path}"],
                    stdout=log_file,
                    stderr=subprocess.STDOUT,
                )
                processes.append((name, process, log_path, log_file))

            launch("host", "host", 0)
            wait_for_marker(processes[0][1], processes[0][2], "WORLD RUNTIME HOST LISTENING", 10.0)
            for index in range(1, args.players):
                launch(f"client-{index}", "client", index)
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline and any(p.poll() is None for _, p, _, _ in processes):
                time.sleep(0.1)
            failures: list[str] = []
            for name, process, log_path, log_file in processes:
                if process.poll() is None:
                    process.kill()
                    failures.append(f"{name} timed out")
                process.wait(timeout=5)
                log_file.close()
                output = log_path.read_text(encoding="utf-8", errors="replace")
                print(f"[{name}]\n{output}")
                if process.returncode != 0 or "WORLD RUNTIME PROBE PASS" not in output \
                        or "ERROR:" in output or "SCRIPT ERROR:" in output:
                    failures.append(f"{name} failed with exit code {process.returncode}")
            if failures:
                raise RuntimeError("; ".join(failures))
            return 0
        except Exception as error:
            print(f"world runtime probe failed: {error}")
            return 1
        finally:
            for _, process, _, log_file in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if not log_file.closed:
                    log_file.close()


if __name__ == "__main__":
    raise SystemExit(main())
