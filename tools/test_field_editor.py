"""Run the Field Editor in an isolated Godot project and save a disposable field."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from process_diagnostics import run_logged, engine_error


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
        imported = run_logged(command + ["--headless", "--import"], env=env,
                                  capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=180)
        if imported.returncode or engine_error(imported.stdout + imported.stderr):
            print(imported.stdout + imported.stderr)
            return 1
        plugin.write_text(probe_config, encoding="utf-8")
        # External verification waits on wall time, not editor render frames.
        # Keep the 90-second deadline and require the complete probe marker.
        result = run_logged(command + mode + ["res://tests/field_editor_probe_scene.tscn"], env=env, capture_output=True,
                                text=True, encoding="utf-8", errors="replace", timeout=90)
        output = result.stdout + result.stderr
        print(output)
        print(f"FIELD EDITOR PROCESS exit={result.returncode}")
        jobs = project / ".godot" / "rtc_traversal"
        if jobs.exists():
            retained = Path(tempfile.mkdtemp(prefix="rtc-traversal-editor-logs-"))
            shutil.copytree(jobs, retained, dirs_exist_ok=True)
            print(f"TRAVERSAL EDITOR LOGS {retained}")
            for status_path in sorted(jobs.glob("*/status.json")):
                try:
                    status = json.loads(status_path.read_text(encoding="utf-8"))
                    print(f"TRAVERSAL CHILD {status_path.parent.name} state={status.get('state')} exit={status.get('return_code')}")
                except (ValueError, OSError) as error:
                    print(f"TRAVERSAL CHILD status unreadable: {error}")
        if result.returncode or "FIELD EDITOR PROBE PASS" not in output or engine_error(output):
            return 1
        config = project / "project.godot"
        config.write_text(config.read_text(encoding="utf-8").replace(
            'enabled=PackedStringArray("res://addons/rtc_field_editor/plugin.cfg")',
            'enabled=PackedStringArray()'), encoding="utf-8")
        runtime = run_logged([args.godot, "--headless", "--path", str(project),
                                  "res://tests/editor/field_runtime_probe.tscn"],
                                 env=env, capture_output=True, text=True, encoding="utf-8",
                                 errors="replace", timeout=45)
        output = runtime.stdout + runtime.stderr
        print(output)
        print(f"AUTHORED RUNTIME PROCESS exit={runtime.returncode}")
        if runtime.returncode or "AUTHORED FIELD RUNTIME PASS" not in output or engine_error(output):
            return 1
        playtest = run_logged(
            [args.godot, "--headless", "--path", str(project),
             "res://tests/editor/field_runtime_probe.tscn", "--", "--region", "step5_flat"],
            env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45,
        )
        output = playtest.stdout + playtest.stderr
        print(output)
        print(f"REGION PLAYTEST PROCESS exit={playtest.returncode}")
        if playtest.returncode or "AUTHORED FIELD RUNTIME PASS" not in output or "isolated temporary exit" not in output or engine_error(output):
            return 1
        for fixture in ("normal", "warn", "blocked", "slot"):
            result = run_logged(
                [args.godot, "--headless", "--path", str(project),
                 "res://tests/editor/region_report_probe.tscn", "--", fixture],
                env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45,
            )
            output = result.stdout + result.stderr
            print(output)
            print(f"REGION REPORT PROCESS {fixture} exit={result.returncode}")
            if result.returncode or f"REGION REPORT FIXTURE {fixture} PASS" not in output or engine_error(output):
                return 1
            summaries = [line.removeprefix("REGION_PLAYTEST_JSON ") for line in output.splitlines()
                         if line.startswith("REGION_PLAYTEST_JSON ")]
            if len(summaries) != 1:
                return 1
            summary = json.loads(summaries[0])
            if summary["overall"] != ("PASS" if fixture == "normal" else "PASS_WITH_WARNINGS" if fixture == "warn" else "FAIL"):
                return 1
            if fixture == "warn" and not any(item["stage"] == "Spawn Capacity" and item["status"] == "WARN"
                                             for item in summary["results"]):
                return 1
        traversal = run_logged(
            [args.godot, "--headless", "--path", str(project), "res://tests/editor/traversal_tests.tscn"],
            env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=100,
        )
        output = traversal.stdout + traversal.stderr
        print(output)
        print(f"TRAVERSAL SUITE PROCESS exit={traversal.returncode}")
        if jobs.exists():
            shutil.copytree(jobs, retained, dirs_exist_ok=True)
        if traversal.returncode or "TRAVERSAL TEST PASS" not in output or engine_error(output):
            return 1
        if args.rendered:
            result = run_logged(
                [args.godot, "--path", str(project), "--rendering-method", "gl_compatibility",
                 "res://tests/editor/region_interactive.tscn", "--", "--region", "sewer_region", "--smoke"],
                env=env, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=45,
            )
            output = result.stdout + result.stderr
            print(output)
            print(f"INTERACTIVE REGION PROCESS exit={result.returncode}")
            if result.returncode or "INTERACTIVE REGION SMOKE PASS" not in output or engine_error(output):
                return 1
        return 0



if __name__ == "__main__":
    raise SystemExit(main())
