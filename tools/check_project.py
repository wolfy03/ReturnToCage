"""Run the same bounded Godot checks locally and in CI (Python 3.10+)."""
import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
from process_diagnostics import run_logged

ROOT = Path(__file__).resolve().parents[1]
ERRORS = re.compile(r"SCRIPT ERROR:|(?:^|\n)(?:ERROR|WARNING):|Parse Error|orphan|CowData|ObjectDB instances leaked|resources still in use", re.I)


def run(executable, arguments, expected=None):
    command = [executable, "--headless", "--path", str(ROOT), *arguments]
    print("RUN", subprocess.list2cmdline(command), flush=True)
    result = run_logged(command, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=120)
    output = result.stdout + result.stderr
    print(output, flush=True)
    if result.returncode or ERRORS.search(output) or (expected and expected not in output):
        raise RuntimeError(f"Godot check failed (exit={result.returncode}): " + " ".join(arguments))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--expected-version", help="Test an explicit upgrade candidate without changing the project pin")
    args = parser.parse_args()
    version = (ROOT / ".godot-version").read_text().strip()
    expected_version = args.expected_version or version
    actual = subprocess.check_output([args.godot, "--version"], text=True, timeout=15).strip()
    if not actual.startswith(expected_version + ".") and not (args.expected_version and actual == expected_version):
        raise RuntimeError(f"Expected Godot {expected_version}; found {actual}")
    feature = ".".join(version.split(".")[:2])
    if f'"{feature}"' not in (ROOT / "project.godot").read_text(encoding="utf-8"):
        raise RuntimeError("Engine pin does not match project.godot features")
    run(args.godot, ["--editor", "--quit"])
    run(args.godot, ["res://core/validation/validate_content.tscn"], "CONTENT VALIDATION PASS")
    run(args.godot, ["res://presentation/tools/validate_player_sprite_pipeline.tscn"], "SPRITE PIPELINE VALIDATION PASS")
    run(args.godot, ["res://tests/test_runner.tscn"], "TEST PASS:")
    for mode in ("--restart-write", "--restart-read"):
        run(args.godot, ["res://tests/test_runner.tscn", "--", mode], "TEST PASS:")
    run(args.godot, ["--quit-after", "60"])
    print("ALL PROJECT CHECKS PASS")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
