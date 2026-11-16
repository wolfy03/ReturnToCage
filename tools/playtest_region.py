"""Run the saved region through the existing runtime probe with isolated user data."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--region", required=True)
    parser.add_argument("--interactive", action="store_true", help="open a playable region with isolated user data")
    parser.add_argument("--smoke", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", args.region) is None:
        parser.error("expected a snake_case region ID")
    if args.smoke and not args.interactive:
        parser.error("--smoke requires --interactive")
    project = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="rtc-region-playtest-") as directory:
        env = os.environ.copy()
        for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                     "GODOT_USER_HOME", "HOME"):
            isolated = Path(directory) / name
            isolated.mkdir()
            env[name] = str(isolated)
        scene = "res://tests/editor/region_interactive.tscn" if args.interactive else "res://tests/editor/field_runtime_probe.tscn"
        command = [args.godot, "--path", str(project), "--rendering-method", "gl_compatibility"]
        if not args.interactive:
            command.append("--headless")
        command += [scene, "--", "--region", args.region]
        if args.smoke:
            command.append("--smoke")
        try:
            result = subprocess.run(
                command, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace",
                timeout=60 if not args.interactive or args.smoke else None,
            )
        except subprocess.TimeoutExpired as error:
            print("REGION PLAYTEST TIMEOUT")
            for output in (error.stdout, error.stderr):
                if output:
                    print(output.decode("utf-8", errors="replace") if isinstance(output, bytes) else output)
            return 1
    output = result.stdout + result.stderr
    print(output, end="")
    print(f"REGION PLAYTEST PROCESS exit={result.returncode}")
    expected = "INTERACTIVE REGION SMOKE PASS" if args.smoke else ("INTERACTIVE REGION CLOSED" if args.interactive else "AUTHORED FIELD RUNTIME PASS")
    if result.returncode or expected not in output or "ERROR:" in output:
        return 1
    if not args.interactive:
        summaries = [line.removeprefix("REGION_PLAYTEST_JSON ") for line in output.splitlines()
                     if line.startswith("REGION_PLAYTEST_JSON ")]
        if len(summaries) != 1 or json.loads(summaries[0]).get("overall") not in ("PASS", "PASS_WITH_WARNINGS"):
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
