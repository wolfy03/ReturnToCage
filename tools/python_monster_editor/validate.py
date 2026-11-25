"""Validate .rtcmonster files from the command line.

    python tools/python_monster_editor/validate.py examples/frog.rtcmonster --project .

Exit code 1 when any file has a FAIL in a domain this static check can decide
(schema, references, assets, animation, collision, attack, ai, compatibility).
Runtime and network are always NOT_EVALUATED here: this never runs Godot.
"""

import argparse
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from rtcmonster import DOMAINS, FAIL, PASS, duplicate_monster_ids, validate_payload  # noqa: E402
from rtcmonster.document import decode  # noqa: E402
from rtcmonster.spec import DocumentError  # noqa: E402
from rtcmonster.timing import DEFAULT_TICK_RATE  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--project", type=Path, help="ReturnToCage project folder for asset and catalog checks")
    parser.add_argument("--tick-rate", type=int, default=DEFAULT_TICK_RATE)
    parser.add_argument("--quiet", action="store_true", help="print only the per-domain summary")
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    failed, opened = False, []
    for path in args.files:
        try:
            payload = path.read_bytes()
        except OSError as error:
            print(f"{path}: cannot read ({error})")
            failed = True
            continue
        report = validate_payload(payload, project=args.project, tick_rate=args.tick_rate)
        print(f"{path}: static {report.static_status}")
        print("  " + "  ".join(f"{domain}={report.status(domain)}" for domain in DOMAINS))
        if not args.quiet:
            for item in report.findings:
                if item.status != PASS:
                    print(f"  {item.status:13} {item.domain:13} {item.code}"
                          + (f"  @ {item.path}" if item.path else "") + (f"  ({item.detail})" if item.detail else ""))
        failed = failed or report.static_status == FAIL
        try:
            opened.append((str(path), decode(payload)))
        except DocumentError:
            pass
    for item in duplicate_monster_ids(opened):
        print(f"{item.path}: FAIL duplicate_monster_id ({item.detail})")
        failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
