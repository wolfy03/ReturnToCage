"""Rendered Forest Trail walk: real window, real input, enemy clips and screenshots."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--artifacts", type=Path, required=True, help="directory that receives the screenshots")
    parser.add_argument("--rendering-method", default="gl_compatibility")
    args = parser.parse_args()
    shots = args.artifacts.resolve()
    shots.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rtc-forest-visual-") as directory:
        env = os.environ.copy()
        for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "GODOT_USER_HOME", "HOME"):
            isolated = Path(directory) / name
            isolated.mkdir()
            env[name] = str(isolated)
        command = [args.godot, "--path", str(ROOT), "--rendering-method", args.rendering_method,
                   "res://tests/editor/forest_visual_probe.tscn", "--", "--screenshots", str(shots)]
        result = subprocess.run(command, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=240)
    output = result.stdout + result.stderr
    print(output, end="")
    saved = sorted(path.name for path in shots.glob("*.png"))
    print(f"FOREST VISUAL PROCESS exit={result.returncode} screenshots={len(saved)}")
    if result.returncode or "FOREST VISUAL PROBE PASS" not in output or "ERROR:" in output or "SCRIPT ERROR" in output or len(saved) < 10:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
