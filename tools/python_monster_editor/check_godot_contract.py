"""Check the Godot project and the .rtcmonster examples against each other.

Runs tools/monster_bridge/contract_probe.tscn in the pinned Godot, then
evaluates five separate contracts (see godot_contract.py):

    environment   engine version, tick rate, protocol, clean log
    registry      every registered enemy, with or without an example document
    legacy        the baseline monsters' examples against the real values
    data_driven   NOT_EVALUATED: no data-driven runtime exists
    behavior      what this probe can say about runtime behaviour, and what it cannot

    python tools/python_monster_editor/check_godot_contract.py --godot <Godot 4.7.2> [--artifacts <dir>]

A Godot exit code of 0 is not a pass: the probe must have written a valid
result, printed its completion line, and the engine log must be clean.
With --artifacts the probe JSON, the engine log and a structured
contract_report.json are kept.
"""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import godot_contract  # noqa: E402
from rtcmonster import read_document, write_document  # noqa: E402
from rtcmonster.project import bind_sources, published_monsters  # noqa: E402

EXAMPLES = HERE / "examples"
ENGINE_ERRORS = re.compile(
    r"SCRIPT ERROR:|(?:^|\n)(?:ERROR|WARNING):|Parse Error|orphan|CowData|ObjectDB instances leaked|"
    r"resources still in use", re.I)
COMPLETED = "MONSTER CONTRACT PROBE PASS"
PROBE_TIMEOUT = 180


def run_probe(godot, project, output):
    """Returns ``(probe, log, clean, command)``. Raises RuntimeError when no usable result exists."""
    command = [str(godot), "--headless", "--path", str(project), "res://tools/monster_bridge/contract_probe.tscn",
               "--", str(output)]
    print("RUN", subprocess.list2cmdline(command), flush=True)
    try:
        result = subprocess.run(command, cwd=project, capture_output=True, text=True, encoding="utf-8",
                                errors="replace", timeout=PROBE_TIMEOUT, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(f"contract probe did not finish within {PROBE_TIMEOUT} s") from error
    log = (result.stdout or "") + (result.stderr or "")
    # Negative or huge codes are native crashes (for example 0xC0000005 on Windows).
    if result.returncode != 0:
        print(log)
        raise RuntimeError(f"contract probe exited with {result.returncode} "
                           f"(0x{result.returncode & 0xffffffff:08X})")
    if COMPLETED not in log or not output.is_file():
        print(log)
        raise RuntimeError("contract probe exited with 0 but did not complete or wrote no result")
    try:
        probe = json.loads(output.read_text(encoding="utf-8"))
    except ValueError as error:
        raise RuntimeError(f"contract probe wrote an unreadable result: {error}") from error
    if not isinstance(probe, dict) or probe.get("protocol") != 1 or not isinstance(probe.get("enemies"), dict):
        raise RuntimeError("contract probe result has an unexpected shape or protocol")
    clean = not ENGINE_ERRORS.search(log)
    if not clean:
        print(log)
    return probe, log, clean, command


def git_commit(project):
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=project, capture_output=True, text=True,
                              timeout=15).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def load_examples(folder):
    documents, files = {}, {}
    for path in sorted(folder.glob("*.rtcmonster")):
        document, revision = read_document(path)
        documents[document.monster_id] = document
        files[document.monster_id] = (path, revision)
    return documents, files


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--project", type=Path, default=ROOT)
    parser.add_argument("--examples", type=Path, default=EXAMPLES)
    parser.add_argument("--artifacts", type=Path, help="keep probe.json, godot.log and contract_report.json here")
    parser.add_argument("--refresh-bindings", action="store_true",
                        help="after every value check passes, rewrite source_binding.files hashes in the examples")
    args = parser.parse_args()
    project = args.project.resolve()
    started = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="rtc-monster-contract-") as temporary:
        folder = args.artifacts.resolve() if args.artifacts else Path(temporary)
        folder.mkdir(parents=True, exist_ok=True)
        probe, log, clean, command = run_probe(args.godot, project, folder / "probe.json")
        (folder / "godot.log").write_text(log, encoding="utf-8")

        pinned = (project / ".godot-version").read_text(encoding="utf-8").strip()
        documents, files = load_examples(args.examples)
        report, stale = godot_contract.evaluate(probe, documents, project, pinned, clean,
                                                published_monsters(project))
        if args.refresh_bindings:
            only_stale = [row for row in report.failed if not row.name.startswith("source files")]
            if not only_stale:
                for monster_id, changed in stale.items():
                    if changed:
                        path, revision = files[monster_id]
                        document = documents[monster_id]
                        names = [row["path"] for row in document.data["source_binding"]["files"]]
                        write_document(path, bind_sources(document, project, names), revision)
                        print(f"REFRESHED {path.name}: {', '.join(changed)}")
                documents, files = load_examples(args.examples)
                report, stale = godot_contract.evaluate(probe, documents, project, pinned, clean,
                                                        published_monsters(project))

        for row in report.results:
            label = f"{row.section}{' / ' + row.monster if row.monster else ''}: {row.name}"
            print(f"{row.status:13} {label}" + (f" :: {row.detail}" if row.detail else ""), flush=True)
        summary = report.summary()
        print("SECTIONS " + "  ".join(f"{name}={summary[name]}" for name in godot_contract.SECTIONS))
        evidence = {
            "commit": git_commit(project),
            "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "godot_version": probe.get("godot_version"),
            "physics_ticks_per_second": probe.get("physics_ticks_per_second"),
            "network_protocol_version": probe.get("network_protocol_version"),
            "command": command,
            "engine_log_clean": clean,
            "sections": summary,
            "counts": {"pass": len(report.passed), "fail": len(report.failed),
                       "not_evaluated": len(report.results) - len(report.passed) - len(report.failed)},
            "registered_monsters": sorted(probe["enemies"]),
            "legacy_baselines": sorted(godot_contract.LEGACY_PROFILES),
            "example_documents": {monster_id: {"fingerprint": document.fingerprint,
                                               "bound": document.data["source_binding"] is not None}
                                  for monster_id, document in sorted(documents.items())},
            "source_files": {monster_id: {row["path"]: row["sha256"]
                                          for row in document.data["source_binding"]["files"]}
                             for monster_id, document in sorted(documents.items())
                             if document.data["source_binding"] is not None},
            "duration_seconds": round(time.monotonic() - started, 2),
            "results": [{"section": row.section, "monster": row.monster, "name": row.name, "status": row.status,
                         "detail": row.detail} for row in report.results],
        }
        (folder / "contract_report.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2) + "\n",
                                                     encoding="utf-8")
    counts = evidence["counts"]
    if not report.ok:
        print(f"MONSTER CONTRACT CHECK FAIL ({counts['fail']} failed, {counts['pass']} passed, "
              f"{counts['not_evaluated']} not evaluated)")
        return 1
    print(f"MONSTER CONTRACT CHECK PASS ({counts['pass']} checks, {counts['not_evaluated']} not evaluated)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(error, file=sys.stderr)
        sys.exit(1)
