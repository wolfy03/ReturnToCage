"""Sequential fresh-process repetitions. Preserve every result, including failures.

Each run records two independent answers (docs/known_issues.md):
  functional_result  PASS / FAIL / TIMEOUT - did the checks themselves pass
  process_result     PASS / FAIL / TIMEOUT / KNOWN_ENGINE_CRASH / UNKNOWN_NATIVE_CRASH
A run passes only when both are PASS. Nothing here turns a crash into a pass.
"""
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
NATIVE_CRASH = 3221225477  # 0xC0000005 STATUS_ACCESS_VIOLATION
FUNCTIONAL_FAILURE = re.compile(r"(?:^|\n)(?:SCRIPT )?ERROR:|PROBE FAIL|timed out|command timeout|idle timeout|AssertionError|Traceback"
                                r"|ObjectDB instances leaked|resources still in use")


def classify(record, text):
    """Functional and process results, judged separately.

    The engine's documented shutdown use-after-free (docs/known_issues.md) is only
    recognised when the checks had already finished: the success marker is present
    and nothing functional failed. Any other access violation is unknown.
    """
    native = record["code"] == NATIVE_CRASH or str(NATIVE_CRASH) in text
    if record["timeout"]:
        functional = "TIMEOUT"
    elif record["marker"] and FUNCTIONAL_FAILURE.search(text) is None and not record["cowdata"]:
        functional = "PASS"
    else:
        functional = "TIMEOUT" if re.search(r"timed out|command timeout|idle timeout", text) else "FAIL"
    if record["timeout"]:
        process = "TIMEOUT"
    elif native:
        process = "KNOWN_ENGINE_CRASH" if functional == "PASS" else "UNKNOWN_NATIVE_CRASH"
    elif record["code"] == 0 and record["remaining_children"] in (0, None):
        process = "PASS"
    else:
        process = "FAIL"
    return functional, process


def commit():
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--repeat", type=int, default=10)
    parser.add_argument("--case", action="append", choices=["physics", "player", "project", "traversal", "headless", "rendered", "enet2", "enet3", "local2", "local3", "lifecycle", "release", "export"])
    parser.add_argument("--output", type=Path, help="keep logs and results.json here instead of a temporary directory")
    args = parser.parse_args()
    if not 1 <= args.repeat <= 100:
        parser.error("repeat must be between 1 and 100")
    if args.output:
        args.output.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix="rtc-stability-", dir=args.output))
    revision = commit()
    print("STABILITY LOGS", output, flush=True)
    python = [sys.executable, "-X", "utf8"]
    editor = python + ["tools/test_field_editor.py", "--godot", args.godot]
    enet = python + ["tools/test_multiplayer_world_runtime.py", "--godot", args.godot]
    local = python + ["tools/test_multiplayer_local.py", "--godot", args.godot]
    commands = {
        "physics": ([args.godot, "--headless", "--path", str(ROOT), "res://tests/integration/native_lifecycle_probe.tscn", "--", "--native-probe=physics"], "NATIVE LIFECYCLE PASS", 20),
        "player": ([args.godot, "--headless", "--path", str(ROOT), "res://tests/integration/native_lifecycle_probe.tscn", "--", "--native-probe=player"], "NATIVE LIFECYCLE PASS", 20),
        "project": (python + ["tools/check_project.py", "--godot", args.godot], "ALL PROJECT CHECKS PASS", 180),
        "traversal": ([args.godot, "--headless", "--path", str(ROOT), "res://tests/editor/traversal_tests.tscn"], "TRAVERSAL TEST PASS", 100),
        "headless": (editor, "TRAVERSAL TEST PASS", 240),
        "rendered": (editor + ["--rendered"], "INTERACTIVE REGION SMOKE PASS", 285),
        "enet2": (enet + ["--players", "2"], "WORLD RUNTIME PROBE PASS", 65),
        "enet3": (enet + ["--players", "3"], "WORLD RUNTIME PROBE PASS", 65),
        "local2": (local + ["--players", "2"], "MULTIPLAYER PROBE PASS", 65),
        "local3": (local + ["--players", "3"], "MULTIPLAYER PROBE PASS", 65),
        "lifecycle": (python + ["tools/test_session_recovery.py", "--godot", args.godot, "--artifacts", str(output / "lifecycle"),
                                "--ipv6", "auto"], "SESSION LIFECYCLE PROBE PASS", 280),
        # Builds the release EXE, then runs content, mixed editor/EXE ENet and both lifecycles against it.
        "release": (python + ["tools/build_windows_demo.py", "--godot", args.godot, "--rendered"], "SESSION LIFECYCLE RECOVERY PASS", 900),
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
            record["functional_result"], record["process_result"] = classify(record, text)
            record.update(commit=revision, exit_code=f"0x{record['code'] & 0xFFFFFFFF:08X}" if record["code"] is not None else None)
            results.append(record)
            (output / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
            print(f"STABILITY {case} {index + 1}/{args.repeat} pass={record['pass']} functional={record['functional_result']} "
                  f"process={record['process_result']} code={record['code']} children={record['remaining_children']} ms={record['wall_ms']}", flush=True)
    for case in dict.fromkeys(row["case"] for row in results):
        rows = [row for row in results if row["case"] == case]
        count = lambda field, value: sum(row[field] == value for row in rows)
        print(f"STABILITY SUMMARY {case} commit={revision[:7]} runs={len(rows)} pass={sum(row['pass'] for row in rows)} "
              f"functional_pass={count('functional_result', 'PASS')} functional_fail={count('functional_result', 'FAIL')} "
              f"functional_timeout={count('functional_result', 'TIMEOUT')} known_engine_crash={count('process_result', 'KNOWN_ENGINE_CRASH')} "
              f"unknown_native_crash={count('process_result', 'UNKNOWN_NATIVE_CRASH')}", flush=True)
    return int(any(not row["pass"] for row in results))


if __name__ == "__main__":
    raise SystemExit(main())
