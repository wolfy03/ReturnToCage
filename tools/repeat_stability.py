"""Sequential fresh-process repetitions. Preserve every result, including failures."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
from traversal_process import ProcessScope

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--repeat", type=int, default=10)
    parser.add_argument("--case", action="append", choices=["physics", "player", "project", "traversal", "headless", "rendered", "enet2", "enet3", "export"])
    args = parser.parse_args()
    if not 1 <= args.repeat <= 100:
        parser.error("repeat must be between 1 and 100")
    output = Path(tempfile.mkdtemp(prefix="rtc-stability-"))
    print("STABILITY LOGS", output, flush=True)
    python = [sys.executable, "-X", "utf8"]
    editor = python + ["tools/test_field_editor.py", "--godot", args.godot]
    enet = python + ["tools/test_multiplayer_world_runtime.py", "--godot", args.godot]
    commands = {
        "physics": ([args.godot, "--headless", "--path", str(ROOT), "res://tests/integration/native_lifecycle_probe.tscn", "--", "--native-probe=physics"], "NATIVE LIFECYCLE PASS", 20),
        "player": ([args.godot, "--headless", "--path", str(ROOT), "res://tests/integration/native_lifecycle_probe.tscn", "--", "--native-probe=player"], "NATIVE LIFECYCLE PASS", 20),
        "project": (python + ["tools/check_project.py", "--godot", args.godot], "ALL PROJECT CHECKS PASS", 180),
        "traversal": ([args.godot, "--headless", "--path", str(ROOT), "res://tests/editor/traversal_tests.tscn"], "TRAVERSAL TEST PASS", 100),
        "headless": (editor, "TRAVERSAL TEST PASS", 240),
        "rendered": (editor + ["--rendered"], "INTERACTIVE REGION SMOKE PASS", 285),
        "enet2": (enet + ["--players", "2"], "WORLD RUNTIME PROBE PASS", 65),
        "enet3": (enet + ["--players", "3"], "WORLD RUNTIME PROBE PASS", 65),
        "export": ([args.godot, "--headless", "--path", str(ROOT), "--export-release", "Windows Desktop", str(output / "ReturnToCage.exe"), "--quit"], "", 120),
    }
    results = []
    for case in args.case or list(commands):
        command, marker, timeout = commands[case]
        for index in range(args.repeat):
            started = time.monotonic()
            scope = ProcessScope()
            process = None
            record = {"case": case, "run": index + 1, "command": command, "profile": "fresh process, sequential", "timeout": False}
            try:
                process = subprocess.Popen(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                record["pid"] = process.pid
                scope.attach(process)
                stdout, stderr = process.communicate(timeout=timeout)
            except subprocess.TimeoutExpired:
                record["timeout"] = True
                scope.close()  # Kill this job's descendants only.
                process.kill()
                stdout, stderr = process.communicate(timeout=5)
            except OSError as error:
                stdout, stderr = b"", str(error).encode()
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait(timeout=5)
            finally:
                cleanup_deadline = time.monotonic() + 7
                while scope.active_processes() not in (0, None) and time.monotonic() < cleanup_deadline:
                    time.sleep(.05)
                record["remaining_children"] = scope.active_processes()
                scope.close()
            prefix = output / f"{case}-{index + 1:02}"
            prefix.with_suffix(".stdout.log").write_bytes(stdout)
            prefix.with_suffix(".stderr.log").write_bytes(stderr)
            text = (stdout + stderr).decode("utf-8", "replace")
            record.update(code=process.returncode if process else None, wall_ms=round((time.monotonic() - started) * 1000),
                          marker=not marker or marker in text, native="3221225477" in text or (process is not None and process.returncode == 3221225477),
                          cowdata="CowData" in text, log=str(prefix))
            record["pass"] = (record["code"] == 0 and not record["timeout"] and record["marker"]
                              and record["remaining_children"] in (0, None) and not record["cowdata"]
                              and re.search(r"(?:^|\n)(?:SCRIPT )?ERROR:|ObjectDB instances leaked|resources still in use", text) is None)
            results.append(record)
            (output / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
            print(f"STABILITY {case} {index + 1}/{args.repeat} pass={record['pass']} code={record['code']} children={record['remaining_children']} ms={record['wall_ms']}", flush=True)
    return int(any(not row["pass"] for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
