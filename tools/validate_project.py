"""Run the Field Editor, field runtime, or full engine-upgrade checks."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from development_environment import ROOT, git, identify, local_settings, user_environment, worktree
from process_diagnostics import run_logged

UPGRADE_CASES = (
    "parse", "project", "physics", "player", "traversal", "headless", "rendered",
    "test_traversal_process", "test_traversal_jobs", "enet2", "enet3", "export",
)
NATIVE = re.compile(r"\b(?:0xc0000005|3221225477|0x80000003|2147483651|CowData|use-after-free)\b|(?<!\d)-1073741819\b", re.I)
ERRORS = re.compile(r"^(?:SCRIPT |ENGINE )?ERROR:|Parse Error|ObjectDB instances leaked|resources? still in use|\bRIDs?\b[^\n]*\bleaked\b", re.I | re.M)
ANSI_COLOR = re.compile(r"\x1b\[[\d;]*m")
LOG_PATH = re.compile(r"^(?:WORLD RUNTIME LOGS |TRAVERSAL EDITOR LOGS |Export validation artifacts: )(.+)$", re.M)
FAILURE_EVIDENCE = (
    ("TEST_HARNESS_FAILURE", r"GUI input did not reach the target Control|^Traceback \(most recent call last\):"),
    ("TRAVERSAL_FAILURE", r"^ERROR: TRAVERSAL TEST\b|^TRAVERSAL TEST FAIL\b"),
    ("NETWORK_FAILURE", r"^ERROR: WORLD RUNTIME PROBE FAIL:.*(?:replicat|mirror|connect|session sync)"),
    ("RUNTIME_FAILURE", r"^ERROR: AUTHORED FIELD RUNTIME\b"),
    ("EDITOR_FAILURE", r"^ERROR: Field editor probe:"),
)


def failure_category(log, record):
    if record.get("native_crash") or record.get("return_code") in (3221225477, -1073741819, 2147483651) or NATIVE.search(log):
        return "ENGINE_NATIVE_FAILURE"
    for category, pattern in FAILURE_EVIDENCE:
        if re.search(pattern, log, re.I | re.M):
            return category
    return "UNKNOWN"


def profile_commands(profile, godot, players, version, templates, cases, output):
    python = [sys.executable, "-X", "utf8"]

    def test(name, script, args, markers, timeout):
        return name, python + [f"tools/{script}.py", *args], markers, timeout

    engine = ["--godot", godot]
    if profile == "editor":
        return [
            test(name, name, [], (r"Ran [1-9]\d* tests?", r"(?m)^OK\s*$"), 75)
            for name in ("test_traversal_process", "test_traversal_jobs")
        ] + [
            test("headless-editor", "test_field_editor", engine,
                 ("FIELD EDITOR PROBE PASS", "TRAVERSAL TEST PASS"), 240),
            test("rendered-editor", "test_field_editor", engine + ["--rendered"],
                 ("FIELD EDITOR PROBE PASS", "TRAVERSAL TEST PASS", "INTERACTIVE REGION SMOKE PASS"), 285),
        ]
    if profile == "runtime":
        return [test("project", "check_project", engine, ("ALL PROJECT CHECKS PASS",), 9 * 120)] + [
            test(f"enet{count}", "test_multiplayer_world_runtime", engine + ["--players", str(count)],
                 (f"WORLD RUNTIME PROBE PASS players={count}",) + tuple(
                     f"WORLD RUNTIME PROBE PASS client={index}" for index in range(1, count)), 65)
            for count in sorted(set(players))
        ]
    arguments = engine + ["--expected-version", version, "--artifacts", str(output)]
    if templates:
        arguments += ["--templates", str(templates)]
    for case in cases:
        arguments += ["--case", case]
    return [test("engine-upgrade", "validate_godot_upgrade", arguments, (), 3600)]


def read_logs(stdout, stderr):
    return ANSI_COLOR.sub("", "\n".join(
        path.read_text(encoding="utf-8", errors="replace") for path in (stdout, stderr) if path.exists()
    ))


def run_case(spec, output, env):
    name, command, markers, timeout = spec
    prefix = output / name
    issue = None
    try:
        run_logged(command, artifact_prefix=prefix, cwd=ROOT, env=env, timeout=timeout)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        issue = str(error)
    metadata = prefix.with_suffix(".json")
    result = json.loads(metadata.read_text(encoding="utf-8")) if metadata.exists() else {}
    stdout, stderr = prefix.with_suffix(".stdout.log"), prefix.with_suffix(".stderr.log")
    log = read_logs(stdout, stderr)
    missing = [marker for marker in markers if not re.search(marker, log)]
    clean = (issue is None and result.get("return_code") == 0 and result.get("timeout") is False
             and result.get("remaining_children") == 0 and not missing and not ERRORS.search(log))
    category = failure_category(log, result)
    clean = clean and category != "ENGINE_NATIVE_FAILURE"
    result.update(name=name, command=command, status="PASS" if clean else "FAIL", issue=issue,
                  failure_category=None if clean else category, missing_markers=missing,
                  stdout=str(stdout), stderr=str(stderr),
                  nested_logs=[path.strip() for path in LOG_PATH.findall(log)] +
                  re.findall(r"^PROCESS LOG (.+?) pid=", log, re.M))
    if name == "engine-upgrade":
        gate_reports = list(output.glob("rtc-upgrade-*/results.json"))
        if len(gate_reports) == 1:
            gate_path = gate_reports[0]
            gate = json.loads(gate_path.read_text(encoding="utf-8"))
            result["gate_report"] = str(gate_path)
            result["gate_decision"] = gate["decision"]
            if gate["decision"] == "BLOCKED":
                result["status"] = "BLOCKED"
            elif gate["decision"] == "NOT VERIFIED" and "Decision: NOT VERIFIED" in log:
                result["status"] = "NOT VERIFIED"
            elif gate["decision"] != "APPROVED":
                result["status"] = "FAIL"
            if gate.get("native_crash_runs"):
                category = "ENGINE_NATIVE_FAILURE"
            result["gate_failure_categories"] = sorted({
                row["failure_category"] for row in gate["runs"] if row.get("failure_category")
            })
            if category == "ENGINE_NATIVE_FAILURE" or issue or result.get("remaining_children") != 0:
                result["status"] = "BLOCKED"
            result["failure_category"] = None if result["status"] in ("PASS", "NOT VERIFIED") else category
    print(f"{name} {result['status']} exit={result.get('return_code')} "
          f"category={result['failure_category'] or '-'}", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True, choices=("editor", "runtime", "engine-upgrade"))
    parser.add_argument("--godot", type=Path)
    parser.add_argument("--players", type=int, choices=(2, 3), action="append", default=[])
    parser.add_argument("--templates", type=Path)
    parser.add_argument("--upgrade-case", action="append", choices=UPGRADE_CASES, default=[])
    parser.add_argument("--artifacts", type=Path, help="Parent directory for a unique run folder.")
    parser.add_argument("--plan", action="store_true", help="Verify the engine and show the commands without running tests.")
    args = parser.parse_args()
    upgrade = args.profile == "engine-upgrade"
    if args.players and args.profile != "runtime":
        parser.error("--players applies to the runtime profile")
    if (args.templates or args.upgrade_case) and not upgrade:
        parser.error("--templates and --upgrade-case apply to the engine-upgrade profile")
    if sys.platform != "win32":
        parser.error("these profiles require Windows process tracking")
    try:
        if Path(git(Path.cwd(), "rev-parse", "--show-toplevel")).resolve() != ROOT:
            parser.error("run this tool from its own worktree")
        branch, is_upgrade, expected, state = worktree(ROOT)
        if upgrade != is_upgrade or (not upgrade and branch not in ("master", "feature/field-editor")
                                     and not branch.startswith("feature/field-editor-")):
            parser.error(f"profile {args.profile} is unavailable in worktree branch {branch or '(detached)'}")
        if upgrade and not (ROOT / "tools/validate_godot_upgrade.py").is_file():
            parser.error("missing the engine-upgrade gate in this worktree")
        settings = local_settings(state)
        executable = args.godot or settings.get("godot")
        if not executable:
            parser.error("configure this worktree's Godot path or supply --godot")
        engine = identify(executable, expected)
        templates = args.templates or settings.get("templates")
        parent = args.artifacts.resolve() if args.artifacts else state / "validation"
        if (upgrade or args.artifacts) and parent.is_relative_to(ROOT):
            parser.error("keep validation artifacts outside the worktree")
        if args.plan:
            commands = profile_commands(args.profile, engine["path"], args.players, engine["version"],
                                        templates, args.upgrade_case, parent)
            print(json.dumps({"status": "NOT VERIFIED", "branch": branch, "engine": engine,
                              "commands": [command for _, command, _, _ in commands]}, indent=2))
            return 0
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(prefix=args.profile + "-", dir=parent))
        env = user_environment(output / "user")
        commands = profile_commands(args.profile, engine["path"], args.players, engine["version"],
                                    templates, args.upgrade_case, output)
        result = {"status": "NOT VERIFIED", "profile": args.profile, "branch": branch, "worktree": str(ROOT),
                  "commit": git(ROOT, "rev-parse", "HEAD"), "engine": engine, "runs": []}
        print(f"ENGINE {json.dumps(engine)}\nPROFILE LOGS {output}", flush=True)
        report = output / "results.json"
        for spec in commands:
            result["runs"].append(run_case(spec, output, env))
            report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        statuses = {row["status"] for row in result["runs"]}
        result["status"] = next(status for status in ("BLOCKED", "FAIL", "NOT VERIFIED", "PASS") if status in statuses)
        report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        return int(result["status"] != "PASS")
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    raise SystemExit(main())
