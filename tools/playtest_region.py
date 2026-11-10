"""Run the saved region through the existing runtime probe with isolated user data."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--region", required=True)
    args = parser.parse_args()
    if re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", args.region) is None:
        parser.error("expected a snake_case region ID")
    project = Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix="rtc-region-playtest-") as directory:
        env = os.environ.copy()
        for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME",
                     "GODOT_USER_HOME", "HOME"):
            isolated = Path(directory) / name
            isolated.mkdir()
            env[name] = str(isolated)
        result = subprocess.run(
            [args.godot, "--headless", "--path", str(project),
             "res://tests/editor/field_runtime_probe.tscn", "--", "--region", args.region],
            env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60,
        )
    output = result.stdout + result.stderr
    print(output, end="")
    return int(result.returncode != 0 or "AUTHORED FIELD RUNTIME PASS" not in output or "ERROR:" in output)


if __name__ == "__main__":
    raise SystemExit(main())
