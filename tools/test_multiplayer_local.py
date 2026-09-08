from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCENE = "res://tests/integration/multiplayer_probe.tscn"


def main() -> int:
    parser = argparse.ArgumentParser(description="Run a timeout-bounded ENet localhost multiplayer probe.")
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--players", type=int, choices=(2, 3, 4), default=2)
    parser.add_argument("--port", type=int, default=17777)
    parser.add_argument("--host-disconnect", action="store_true")
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()

    common = [args.godot, "--headless", "--path", str(ROOT), SCENE, "--", f"--port={args.port}", f"--players={args.players}"]
    extra = ["--disconnect-host"] if args.host_disconnect else []
    processes: list[tuple[str, subprocess.Popen[bytes], Path, object]] = []
    with tempfile.TemporaryDirectory(prefix="return_to_cage_net_") as temporary:
        try:
            def launch(name: str, role: str) -> None:
                log_path = Path(temporary) / f"{name}.log"
                log_file = log_path.open("wb")
                process = subprocess.Popen(common + [f"--role={role}"] + extra, stdout=log_file, stderr=subprocess.STDOUT)
                processes.append((name, process, log_path, log_file))

            launch("host", "host")
            time.sleep(0.8)
            for index in range(args.players - 1):
                launch(f"client-{index + 1}", "client")
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline and any(process.poll() is None for _name, process, _path, _file in processes):
                time.sleep(0.1)
            failed: list[str] = []
            for name, process, log_path, log_file in processes:
                if process.poll() is None:
                    process.kill()
                    failed.append(f"{name} timed out")
                process.wait(timeout=5)
                log_file.close()
                output = log_path.read_text(encoding="utf-8", errors="replace")
                print(f"[{name}]\n{output}")
                requires_pass_marker = (name == "host" and not args.host_disconnect) or (name.startswith("client-") and args.host_disconnect)
                if process.returncode != 0 or requires_pass_marker and "MULTIPLAYER PROBE PASS" not in output:
                    failed.append(f"{name} failed with exit code {process.returncode}")
            if failed:
                raise RuntimeError("; ".join(failed))
            return 0
        except Exception as exc:
            print(f"localhost multiplayer probe failed: {exc}", file=sys.stderr)
            return 1
        finally:
            for _name, process, _path, log_file in processes:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
                if not log_file.closed:
                    log_file.close()


if __name__ == "__main__":
    raise SystemExit(main())
