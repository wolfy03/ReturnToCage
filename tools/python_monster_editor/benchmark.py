"""Measure the core on synthetic monsters of three sizes. Numbers, not promises.

    python tools/python_monster_editor/benchmark.py [--output result.json] [--package-root <dir>]

``--package-root`` points at another copy of ``rtcmonster`` (for example an
older commit extracted with ``git archive``), so two implementations can be
compared with the same script. Only API that both have is used; where the
older one lacks ``apply`` the edits are applied one ``replace`` at a time.

Everything here is a measurement on the machine it ran on. There is no GUI
yet, so nothing below says anything about UI responsiveness.
"""

import argparse
import gc
import json
import platform
from pathlib import Path
import statistics
import sys
import tempfile
import time
import tracemalloc

SIZES = {
    # name: (clips, frames per clip, attack patterns, states)
    "small": (5, 10, 2, 10),
    "medium": (20, 15, 10, 30),
    "large": (50, 20, 30, 64),      # 64 states is the schema limit; the plan's 100 is rejected (see tests)
}
REPEATS = {"small": 30, "medium": 15, "large": 7}


def build(clips, frames, patterns, states):
    images = [{"id": f"sheet_{c}", "path": f"art/sheet_{c}.png", "width": 64 * frames, "height": 64}
              for c in range(clips)]
    clip_rows = [{"id": f"clip_{c}", "fps": 12, "loop": c % 2 == 0,
                  "frames": [{"image": f"sheet_{c}", "rect": [64 * f, 0, 64, 64]} for f in range(frames)]}
                 for c in range(clips)]
    hitboxes = [{"id": f"hit_{p}", "shape": {"type": "rectangle", "center": [20, 0], "size": [24, 16]}}
                for p in range(patterns)]
    pattern_rows = [{
        "id": f"pattern_{p}", "duration": 0.6, "clip": f"clip_{p % clips}",
        "phases": [{"kind": "windup", "start": 0, "end": 0.2}, {"kind": "active", "start": 0.2, "end": 0.4},
                   {"kind": "recovery", "start": 0.4, "end": 0.6}],
        "events": [{"type": "EnableHitbox", "time": 0.2, "hitbox": f"hit_{p}"},
                   {"type": "DisableHitbox", "time": 0.4, "hitbox": f"hit_{p}"}]} for p in range(patterns)]
    done = {"type": "ActionCompleted"}
    state_rows = [{"id": "idle", "module": "Wait", "transitions": [{"to": "wait_0", "condition": done}]},
                  {"id": "hurt", "module": "HurtReaction", "transitions": [{"to": "idle", "condition": done}]},
                  {"id": "dead", "module": "Death"}]
    extra = states - 3
    for s in range(extra):
        state_rows.append({"id": f"wait_{s}", "module": "Wait", "params": {"seconds": 0.5}, "transitions": [
            {"to": f"wait_{(s + 1) % extra}", "condition": done},
            {"to": "idle", "priority": 5,
             "condition": {"all": [{"type": "HasTarget"},
                                   {"type": "TargetDistance", "op": "<=",
                                    "value": {"stat": "chase_range", "scale": 1, "offset": 0}}]}}]})
    return {
        "monster_id": "bench_monster", "metadata": {"display_name": "Benchmark"},
        "assets": {"images": images}, "animations": {"clips": clip_rows},
        "collision": {"body": {"shape": {"type": "rectangle", "center": [0, 0], "size": [32, 22]}},
                      "hurtboxes": [{"id": "body", "shape": {"type": "rectangle", "center": [0, 0],
                                                             "size": [38, 28]}}],
                      "hitboxes": hitboxes},
        "attack_patterns": pattern_rows,
        "behavior": {"initial_state": "idle", "states": state_rows},
    }


def timed(function, repeats):
    """Median and minimum wall time in milliseconds over ``repeats`` runs."""
    samples = []
    for _ in range(repeats):
        gc.collect()
        start = time.perf_counter()
        function()
        samples.append((time.perf_counter() - start) * 1000)
    return {"median_ms": round(statistics.median(samples), 3), "min_ms": round(min(samples), 3)}


def measure(name, package):
    clips, frames, patterns, states = SIZES[name]
    repeats = REPEATS[name]
    raw = build(clips, frames, patterns, states)
    document = package.MonsterDocument(raw)
    payload = package.encode(document)
    has_apply = hasattr(document, "apply")

    def multi_edit():
        if has_apply:
            from rtcmonster import set_value
            return document.apply(set_value(("stats", "max_health"), 40), set_value(("stats", "move_speed"), 70),
                                  set_value(("animations", "clips", 0, "fps"), 10),
                                  set_value(("attack_patterns", 0, "cooldown"), 1),
                                  set_value(("behavior", "states", 0, "params", "seconds"), 2))
        step = document.replace(("stats", "max_health"), 40).replace(("stats", "move_speed"), 70)
        step = step.replace(("animations", "clips", 0, "fps"), 10).replace(("attack_patterns", 0, "cooldown"), 1)
        return step.replace(("behavior", "states", 0, "params", "seconds"), 2)

    def save_and_reopen():
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bench.rtcmonster"
            revision = package.write_document(path, document)
            assert package.read_document(path) == (document, revision)

    def repeated_edits(count=100):
        current = document
        for step in range(count):
            current = current.replace(("stats", "max_health"), 1 + step)
        return current

    result = {
        "size": {"clips": clips, "frames": clips * frames, "attack_patterns": patterns, "states": states,
                 "canonical_bytes": len(payload)},
        "create": timed(lambda: package.MonsterDocument(raw), repeats),
        "read_data_100_times": timed(lambda: [document.data["stats"]["max_health"] for _ in range(100)], repeats),
        "copy_to_dict": timed(document.to_dict, repeats),
        "single_edit": timed(lambda: document.replace(("stats", "max_health"), 40), repeats),
        "five_field_edit": timed(multi_edit, repeats),
        "encode": timed(lambda: package.encode(document), repeats),
        "decode": timed(lambda: package.decode(payload), repeats),
        "validate": timed(lambda: package.validate(document), repeats),
        "save_and_reopen": timed(save_and_reopen, max(3, repeats // 3)),
        "edits_100_in_a_row": timed(repeated_edits, max(3, repeats // 5)),
    }
    if hasattr(document, "fingerprint"):
        result["fingerprint_first_use"] = timed(lambda: package.MonsterDocument(raw).fingerprint, max(3, repeats // 3))
        from rtcmonster.validation.context import Context
        result["reference_index"] = timed(lambda: Context(document, None, 60).index, repeats)
    # Memory held by an undo history of 50 single-field edits (peak traced allocation, snapshots kept alive).
    gc.collect()
    tracemalloc.start()
    history = [document]
    for step in range(50):
        history.append(history[-1].replace(("stats", "max_health"), 1 + step))
    current, _peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    result["undo_history_50_snapshots"] = {"kib": round(current / 1024, 1),
                                           "kib_per_snapshot": round(current / 1024 / 50, 1)}
    del history
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--package-root", type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument("--label", default="current")
    args = parser.parse_args()
    sys.path.insert(0, str(args.package_root.resolve()))
    import rtcmonster as package

    report = {
        "label": args.label,
        "environment": {"python": platform.python_version(), "implementation": platform.python_implementation(),
                        "machine": platform.machine(), "system": f"{platform.system()} {platform.release()}",
                        "processor": platform.processor()},
        "method": "wall time with time.perf_counter, garbage collected before each sample; median and minimum of "
                  "the repeat counts below; memory with tracemalloc",
        "repeats": REPEATS,
        "results": {name: measure(name, package) for name in SIZES},
    }
    text = json.dumps(report, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text + "\n", encoding="utf-8")
    for name, rows in report["results"].items():
        print(f"{name}: {rows['size']}")
        for key, value in rows.items():
            if key != "size":
                print(f"  {key:28} {value}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
