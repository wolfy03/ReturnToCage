"""Run the Field Editor in an isolated Godot project and save a disposable field."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--rendered", action="store_true")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    paths = subprocess.check_output(
        ["git", "ls-files", "-c", "-o", "--exclude-standard", "-z"], cwd=root
    ).decode("utf-8").split("\0")
    with tempfile.TemporaryDirectory(prefix="rtc-field-editor-") as directory:
        project = Path(directory) / "project"
        for name in sorted(set(filter(None, paths))):
            source = root / name
            if source.is_file() and name != "tests/field_editor_gui_probe.tscn":
                target = project / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, target)
        shutil.copyfile(project / "world/adventure/sewer_region.tscn",
                        project / "tests/field_editor_probe_scene.tscn")
        plugin = project / "addons/rtc_field_editor/plugin.cfg"
        shutil.copyfile(project / "tests/editor/field_editor_probe.gd", plugin.parent / "probe.gd")
        plugin.write_text(plugin.read_text(encoding="utf-8").replace(
            'script="plugin.gd"', 'script="probe.gd"'), encoding="utf-8")
        env = os.environ.copy()
        for name in ("APPDATA", "LOCALAPPDATA", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_CACHE_HOME"):
            target = Path(directory) / name
            target.mkdir()
            env[name] = str(target)
        command = [args.godot, "--path", str(project), "--editor", "--rendering-method", "gl_compatibility"]
        mode = [] if args.rendered else ["--headless"]
        # The probe starts only after the imported project is ready.
        probe_config = plugin.read_text(encoding="utf-8")
        plugin.write_text(probe_config.replace('script="probe.gd"', 'script="plugin.gd"'), encoding="utf-8")
        imported = subprocess.run(command + ["--headless", "--import"], env=env,
                                  capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        if imported.returncode or "SCRIPT ERROR" in imported.stdout + imported.stderr:
            print(imported.stdout + imported.stderr)
            return 1
        plugin.write_text(probe_config, encoding="utf-8")
        result = subprocess.run(command + mode + ["--quit-after", "1800", "res://tests/field_editor_probe_scene.tscn"], env=env, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=90)
        output = result.stdout + result.stderr
        print(output)
        if result.returncode or "FIELD EDITOR PROBE PASS" not in output or "ERROR:" in output:
            return 1
        config = project / "project.godot"
        config.write_text(config.read_text(encoding="utf-8").replace(
            'enabled=PackedStringArray("res://addons/rtc_field_editor/plugin.cfg")',
            'enabled=PackedStringArray()'), encoding="utf-8")
        runtime = subprocess.run([args.godot, "--headless", "--path", str(project),
                                  "res://tests/editor/field_runtime_probe.tscn"],
                                 env=env, capture_output=True, text=True, encoding="utf-8",
                                 errors="replace", timeout=45)
        output = runtime.stdout + runtime.stderr
        print(output)
        return int(runtime.returncode != 0 or "AUTHORED FIELD RUNTIME PASS" not in output
                   or "ERROR:" in output or "ObjectDB instances leaked" in output)


if __name__ == "__main__":
    raise SystemExit(main())
