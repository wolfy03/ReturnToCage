"""Exercise read-only item windows through real Godot GUI input and capture them."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from test_windows_export import ERRORS

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--rendered", action="store_true")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "build/validation/inventory-ui")
    args = parser.parse_args()
    folder = args.artifacts.resolve()
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "inventory-ui.png").unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="rtc_item_ui_") as isolated:
        env = os.environ.copy()
        env.update(APPDATA=isolated, XDG_DATA_HOME=isolated, RTC_TEST_USER_ROOT=isolated)
        command = [args.godot, "--path", str(ROOT)]
        if not args.rendered:
            command.append("--headless")
        if os.environ.get("RTC_VALIDATION_AUDIO_DRIVER"):
            command += ["--audio-driver", os.environ["RTC_VALIDATION_AUDIO_DRIVER"]]
        command += ["res://tests/test_runner.tscn", "--", "--inventory-ui-only",
                    f"--inventory-ui-screenshot={folder / 'inventory-ui.png'}"]
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                                encoding="utf-8", errors="replace", timeout=90)
        output = result.stdout + result.stderr
        (folder / "engine.log").write_text(output, encoding="utf-8")
        print(output)
        if result.returncode or ERRORS.search(output) or "TEST PASS:" not in output:
            raise RuntimeError(f"Item UI validation failed (exit={result.returncode})")
        if args.rendered and (not (folder / "inventory-ui.png").exists() or " - Using Device" not in output):
            raise RuntimeError("Rendered inventory verification did not capture the game viewport")


if __name__ == "__main__":
    main()
