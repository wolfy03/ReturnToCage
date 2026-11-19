"""Run the Windows engine-upgrade gate in a dedicated Git worktree."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

from process_diagnostics import run_logged

ROOT = Path(__file__).resolve().parents[1]
VERSION = re.compile(r"(?P<release>\d+\.\d+(?:\.\d+)?\.(?:beta\d+|rc\d+|stable))\.official\.(?P<build>[0-9a-f]{7,40})")
NATIVE = re.compile(r"\b(?:0xc0000005|3221225477|2147483651|0x80000003|use-after-free)\b|(?<!\d)-1073741819\b", re.I)
ERRORS = re.compile(
    r"^(?:SCRIPT |ENGINE )?ERROR:|Parse Error|CowData|ObjectDB instances leaked"
    r"|resources? still in use|\bRIDs?\b[^\n]*\bleaked\b|resource leaks?",
    re.I | re.M,
)
LOG_PATH = re.compile(r"^(?:WORLD RUNTIME LOGS |TRAVERSAL EDITOR LOGS |Export validation artifacts: )(.+)$", re.M)
ANSI_COLOR = re.compile(r"\x1b\[[\d;]*m")
PROTECTED_FILES = (
    "export_presets.cfg",
    "world/adventure/test_region.tscn",
    "data/content/regions/test_region.tres",
)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def protected_files(worktree):
    return {
        name: sha256(worktree / name) if (worktree / name).is_file() else None
        for name in PROTECTED_FILES
    }


def run_case(name, index, command, markers, timeout, output, engine, env):
    directory = output / "logs" / f"{name}-{index:02d}"
    directory.mkdir(parents=True)
    prefix = directory / "process"
    issue = None
    try:
        run_logged(command, artifact_prefix=prefix, cwd=ROOT, env=env, timeout=timeout)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        issue = str(error)
    metadata = prefix.with_suffix(".json")
    record = json.loads(metadata.read_text(encoding="utf-8")) if metadata.exists() else {}
    stdout = prefix.with_suffix(".stdout.log")
    stderr = prefix.with_suffix(".stderr.log")
    log = ANSI_COLOR.sub("", "\n".join(
        path.read_text(encoding="utf-8", errors="replace") for path in (stdout, stderr) if path.exists()))
    record.update(case=name, run=index, engine=engine, command=command, issue=issue,
                  stdout=str(stdout), stderr=str(stderr),
                  nested_logs=[path.strip() for path in LOG_PATH.findall(log)] +
                  re.findall(r"^PROCESS LOG (.+?) pid=", log, re.M),
                  missing_markers=[marker for marker in markers if not re.search(marker, log)],
                  native_crash=bool(NATIVE.search(log)) or record.get("return_code") in (3221225477, -1073741819, 2147483651),
                  engine_error=bool(ERRORS.search(log)))
    record["pass"] = (issue is None and record.get("return_code") == 0 and record.get("timeout") is False
                      and record.get("remaining_children") == 0 and not record["missing_markers"]
                      and not record["native_crash"] and not record["engine_error"])
    print(f"{name} {index}: {'PASS' if record['pass'] else 'FAIL'} "
          f"exit={record.get('return_code')} children={record.get('remaining_children')}", flush=True)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--templates", type=Path, help="Official extracted template directory containing version.txt")
    parser.add_argument("--artifacts", type=Path, help="Parent for unique result directories")
    parser.add_argument("--case", action="append", choices=(
        "parse", "project", "physics", "player", "traversal", "headless", "rendered",
        "test_traversal_process", "test_traversal_jobs", "enet2", "enet3", "export"),
        help="Run selected checks after import. A partial run cannot approve an upgrade.")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("the full upgrade gate requires Windows")
    worktrees = subprocess.check_output(["git", "worktree", "list", "--porcelain", "-z"], cwd=ROOT)
    primary = Path(worktrees.split(b"\0", 1)[0].decode("utf-8").removeprefix("worktree ")).resolve()
    if ROOT == primary:
        parser.error("run the upgrade gate from a dedicated linked Git worktree")

    godot = args.godot.resolve(strict=True)
    engine_command = [str(godot)]
    actual = subprocess.check_output(engine_command + ["--version"], text=True, timeout=15).strip()
    match = VERSION.fullmatch(actual)
    if not match or args.expected_version not in (actual, match["release"]):
        parser.error(f"expected official Godot {args.expected_version}; found {actual}")
    engine = {"path": str(godot), "version": actual, "build": match["build"], "sha256": sha256(godot)}
    if godot.stem.endswith("_console"):
        executable = godot.with_name(godot.stem.removesuffix("_console") + godot.suffix)
        engine.update(native_executable=str(executable), native_sha256=sha256(executable))

    artifact_root = args.artifacts.resolve() if args.artifacts else None
    if artifact_root:
        if artifact_root.is_relative_to(ROOT):
            parser.error("keep artifacts outside the source worktree")
        artifact_root.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=f"rtc-upgrade-{match['release']}-", dir=artifact_root))
    env = os.environ.copy()
    for variable in ("APPDATA", "LOCALAPPDATA"):
        path = output / variable.lower()
        path.mkdir()
        env[variable] = str(path)
    env["LANG"] = "en_US"
    env["GODOT"] = str(godot)
    env["PYTHONUTF8"] = "1"
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    dirty = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).splitlines()
    protected_before = protected_files(primary)
    result = {"engine": engine, "project_commit": revision, "project_status_before": dirty,
              "primary_worktree": str(primary), "protected_files_before": protected_before,
              "decision": "NOT VERIFIED", "runs": []}
    report = output / "results.json"

    def save():
        summary = {}
        for record in result["runs"]:
            case = summary.setdefault(record["case"], {"passed": 0, "failed": 0})
            case["passed" if record["pass"] else "failed"] += 1
        result["summary"] = summary
        result["native_crash_runs"] = sum(record["native_crash"] for record in result["runs"])
        result["runs_with_remaining_children"] = sum(bool(record.get("remaining_children")) for record in result["runs"])
        temporary = report.with_suffix(".tmp")
        temporary.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        temporary.replace(report)

    def finish(export_verified=False):
        result["project_status_after"] = subprocess.check_output(
            ["git", "status", "--porcelain"], cwd=ROOT, text=True,
        ).splitlines()
        result["protected_files_after"] = protected_files(primary)
        result["protected_files_preserved"] = result["protected_files_after"] == protected_before
        if not result["protected_files_preserved"]:
            result["decision"] = "BLOCKED"
        elif result["decision"] != "BLOCKED" and not args.case and export_verified:
            result["decision"] = "APPROVED"
        save()
        print(f"Decision: {result['decision']}", flush=True)
        return int(result["decision"] != "APPROVED")

    print(f"ENGINE {json.dumps(engine)}\nUPGRADE LOGS {output}", flush=True)
    save()

    def run(name, command, markers=(), timeout=120, repeat=1):
        if args.case and name not in ("import", "export_boot", *args.case):
            return None
        clean = True
        for index in range(1, repeat + 1):
            print(f"START {name} {index}/{repeat} {engine['version']} {engine['sha256']} {engine['path']}", flush=True)
            record = run_case(name, index, command, markers, timeout, output, engine, env)
            result["runs"].append(record)
            clean &= record["pass"]
            if not clean:
                result["decision"] = "BLOCKED"
            save()
        return clean

    python = [sys.executable, "-X", "utf8"]
    common = engine_command + ["--headless", "--path", str(ROOT)]
    import_ok = run("import", common + ["--editor", "--import"], timeout=180)
    if not import_ok:
        return finish()
    if not args.case or "parse" in args.case:
        sources = subprocess.check_output(
            ["git", "ls-files", "-z", "--", "*.gd"], cwd=ROOT,
        ).decode("utf-8").rstrip("\0").split("\0")
        source_paths = json.dumps([f"res://{source}" for source in sources], ensure_ascii=False)
        audit = output / "parse_audit.gd"
        audit.write_text(
            "extends SceneTree\n\n"
            "func _initialize() -> void:\n"
            f"\tvar sources: Array[String] = {source_paths}\n"
            "\tvar failed := 0\n"
            "\tfor path in sources:\n"
            "\t\tif ResourceLoader.load(path, \"GDScript\") == null:\n"
            "\t\t\tpush_error(\"PARSE AUDIT LOAD FAILED \" + path)\n"
            "\t\t\tfailed += 1\n"
            "\tprint(\"PARSE AUDIT loaded=%d failed=%d\" % [sources.size(), failed])\n"
            "\tquit(int(failed > 0))\n",
            encoding="utf-8",
        )
        run("parse", common + ["--script", str(audit)], (f"PARSE AUDIT loaded={len(sources)} failed=0",))
    run("project", python + ["tools/check_project.py", "--godot", str(godot), "--expected-version", actual],
        (r"ALL PROJECT CHECKS PASS", r"TEST PASS: (?:639[5-9]|6[4-9]\d\d|[7-9]\d{3}|[1-9]\d{4,}) assertions",
         r"TEST PASS: 1 assertions", r"TEST PASS: 25 assertions"), timeout=9 * 120)
    fixture = common + ["res://tests/integration/native_lifecycle_probe.tscn", "--"]
    for mode in ("physics", "player"):
        run(mode, fixture + [f"--native-probe={mode}"], (f"NATIVE LIFECYCLE PASS mode={mode}",), timeout=20, repeat=10)
    traversal = r"TRAVERSAL TEST PASS assertions=(?:9[3-9]|[1-9]\d{2,})\b"
    run("traversal", common + ["res://tests/editor/traversal_tests.tscn"], (traversal,), timeout=100, repeat=10)
    editor = python + ["tools/test_field_editor.py", "--godot", str(godot)]
    editor_markers = ("FIELD EDITOR PROBE PASS", traversal)
    run("headless", editor, editor_markers, timeout=240, repeat=3)
    run("rendered", editor + ["--rendered"], editor_markers + ("INTERACTIVE REGION SMOKE PASS",), timeout=285, repeat=3)
    for script in ("test_traversal_process.py", "test_traversal_jobs.py"):
        run(Path(script).stem, python + [f"tools/{script}"], (r"Ran [1-9]\d* tests?", r"(?m)^OK\s*$"))
    for players in (2, 3):
        markers = (f"WORLD RUNTIME PROBE PASS players={players}",) + tuple(
            f"WORLD RUNTIME PROBE PASS client={index}" for index in range(1, players))
        run(f"enet{players}", python + ["tools/test_multiplayer_world_runtime.py", "--godot", str(godot),
                                       "--players", str(players)], markers, timeout=65, repeat=10)

    export_verified = False
    if args.templates and (not args.case or "export" in args.case):
        try:
            templates = args.templates.resolve(strict=True)
            if (templates / "version.txt").read_text(encoding="utf-8").strip() != match["release"]:
                raise ValueError("Template version does not match the editor")
            target = Path(env["APPDATA"]) / "Godot" / "export_templates" / match["release"]
            target.mkdir(parents=True)
            release = templates / "windows_release_x86_64.exe"
            result["template"] = {"version": match["release"], "source": str(release), "sha256": sha256(release)}
            for binary in templates.glob("windows_*_x86_64*.exe"):
                shutil.copyfile(binary, target / binary.name)
        except (OSError, ValueError) as error:
            result.update(decision="BLOCKED", template_error=str(error))
            save()
        else:
            save()
            export = output / "ReturnToCage.exe"
            built = run("export", common + ["--export-release", "Windows Desktop", str(export)],
                        (r"\[ DONE \] savepack",))
            if built and export.is_file() and export.stat().st_size:
                export_verified = run("export_boot", python + ["tools/test_windows_export.py", "--godot", str(godot),
                    "--exe", str(export), "--artifacts", str(output / "export-checks")],
                    ("WINDOWS RELEASE EXPORT CHECKS PASS",), timeout=600)
            else:
                result.update(decision="BLOCKED", export_error="Release executable was not verified")
    return finish(export_verified)


if __name__ == "__main__":
    raise SystemExit(main())
