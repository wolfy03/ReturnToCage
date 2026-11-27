"""Measure the frame cache against real memory (MONSTER-STEP 3 stabilization, FIX-08).

    python tools/python_monster_editor/check_frame_cache.py [--output <json>] [--budget-mib 160]

For 256, 512 and 1024 pixel frames, and for one large sheet cut into frames, this decodes many more
frames than the budget holds and records, side by side:

* ``cache bytes``: the cache's own estimate (width x height x 4 per kept frame, plus the one decoded
  sheet it holds), which must never exceed the budget - one budget for both, 160 MiB by default;
* ``working set``: what the operating system says the process uses, read before the run, at its peak and
  after the cache is emptied.

The two are different things and are reported as such. Qt keeps bookkeeping per pixmap, the allocator
does not hand freed pages back at once, and the first decode loads code and tables - so the working set
is larger than the estimate and falls later and less than it rose. The pass / fail lines are only about
what the cache promises: the estimate stays inside the budget, a frame too large for it is never kept,
replaying a clip for a long time does not grow the process, and switching project empties its frames.

The numbers are from the machine this runs on. They are measurements, not guarantees.
"""

import argparse
import ctypes
import gc
import json
import os
from pathlib import Path
import sys
import tempfile
import time

TOOL = Path(__file__).resolve().parent
sys.path.insert(0, str(TOOL))

MiB = 1024 * 1024


def working_set():
    """Bytes of physical memory the process holds now (0 when the platform offers no cheap answer)."""
    if os.name == "nt":
        class Counters(ctypes.Structure):
            _fields_ = [("cb", ctypes.c_ulong), ("PageFaultCount", ctypes.c_ulong),
                        ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                        ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                        ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                        ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t)]
        counters = Counters()
        counters.cb = ctypes.sizeof(Counters)
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        psapi = ctypes.WinDLL("psapi", use_last_error=True)
        kernel.GetCurrentProcess.restype = ctypes.c_void_p
        psapi.GetProcessMemoryInfo.argtypes = [ctypes.c_void_p, ctypes.POINTER(Counters), ctypes.c_ulong]
        if psapi.GetProcessMemoryInfo(kernel.GetCurrentProcess(), ctypes.byref(counters), counters.cb):
            return int(counters.WorkingSetSize)
        return 0
    try:
        with open("/proc/self/statm", encoding="ascii") as stream:
            return int(stream.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")
    except (OSError, ValueError, IndexError):
        return 0


def make_sheet(path, frame, columns, rows):
    """A PNG sheet of ``columns x rows`` frames, each a different colour, so no two decodes are equal."""
    from PySide6.QtGui import QColor, QImage, QPainter
    image = QImage(frame * columns, frame * rows, QImage.Format.Format_ARGB32)
    image.fill(QColor(0, 0, 0, 0))
    painter = QPainter(image)
    for index in range(columns * rows):
        x, y = (index % columns) * frame, (index // columns) * frame
        painter.fillRect(x + 4, y + 4, frame - 8, frame - 8, QColor((index * 37) % 256, (index * 91) % 256, 160))
    painter.end()
    if not image.save(str(path)):
        raise RuntimeError(f"cannot write {path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--budget-mib", type=int, default=160,
                        help="the whole cache: frames and the kept sheet together (default: the editor's)")
    args = parser.parse_args()
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")       # nothing is shown; pixmaps only need an application

    from PySide6.QtWidgets import QApplication
    from gui import frame_cache
    from gui.frame_cache import FrameCache, load_frame, pixel_bytes
    app = QApplication.instance() or QApplication([])
    budget = args.budget_mib * MiB
    failures, rows = [], []

    def check(name, passed, detail=""):
        print(f"{'PASS' if passed else 'FAIL':5} {name}" + (f" :: {detail}" if detail and not passed else ""), flush=True)
        if not passed:
            failures.append(name)

    with tempfile.TemporaryDirectory(prefix="rtc-frame-cache-") as folder:
        project = Path(folder)
        (project / "art").mkdir()
        # Two 4096x4096 sheets per frame size: 128 MiB of frames, more than the budget holds.
        for frame, columns, grid_rows in ((256, 16, 16), (512, 8, 8), (1024, 4, 4)):
            sheets = [f"art/sheet_{frame}_{number}.png" for number in range(2)]
            for relative in sheets:
                make_sheet(project / relative, frame, columns, grid_rows)
            per_sheet = columns * grid_rows
            count = per_sheet * len(sheets)

            def source(index, sheets=sheets, per_sheet=per_sheet, columns=columns, frame=frame):
                local = index % per_sheet
                return sheets[index // per_sheet], [(local % columns) * frame, (local // columns) * frame, frame, frame]
            cache = FrameCache(max_bytes=budget)
            gc.collect()
            before = working_set()
            peak_bytes = peak_set = 0
            started = time.perf_counter()
            for index in range(count):
                relative, rect = source(index)
                pixmap, state = load_frame(project, relative, rect, cache)
                if pixmap is None:
                    check(f"{frame}px: frame {index} decodes", False, state)
                    break
                peak_bytes = max(peak_bytes, cache.total_bytes)
                if index % 8 == 0:
                    peak_set = max(peak_set, working_set())
            decode_seconds = time.perf_counter() - started
            peak_set = max(peak_set, working_set())
            kept = len(cache)
            started = time.perf_counter()
            for index in range(count - min(kept, count), count):          # the frames still cached
                relative, rect = source(index)
                load_frame(project, relative, rect, cache)
            hit_seconds = time.perf_counter() - started
            demanded = pixel_bytes(frame, frame) * count
            check(f"{frame}px: {count} frames ({demanded // MiB} MiB of pixels) stay inside the {args.budget_mib} MiB budget",
                  peak_bytes <= budget and cache.total_bytes <= budget, f"peak {peak_bytes}")
            room = (budget - cache.sheet_bytes) // pixel_bytes(frame, frame)       # what is left beside the sheet
            check(f"{frame}px: frames beyond the budget were evicted, oldest first, the kept sheet counted in",
                  (cache.evictions > 0) == (count > room) and kept == min(count, room),
                  f"kept {kept}, room {room}, evictions {cache.evictions}")
            sheet_decodes, sheet_kept = cache.sheet_decodes, cache.sheet_bytes
            check(f"{frame}px: each sheet was decoded once, not once per frame", sheet_decodes == len(sheets),
                  f"{sheet_decodes} decodes")
            cache.clear()
            del pixmap
            gc.collect()
            app.processEvents()
            after = working_set()
            rows.append({"frame": frame, "frames": count, "pixels_demanded_mib": round(demanded / MiB, 1),
                         "cache_peak_mib": round(peak_bytes / MiB, 1), "frames_kept": kept, "evictions": cache.evictions,
                         "sheet_decodes": sheet_decodes, "sheet_kept_mib": round(sheet_kept / MiB, 1),
                         "working_set_before_mib": round(before / MiB, 1), "working_set_peak_mib": round(peak_set / MiB, 1),
                         "working_set_after_clear_mib": round(after / MiB, 1),
                         "decode_ms_per_frame": round(decode_seconds * 1000 / count, 2),
                         "cached_ms_per_frame": round(hit_seconds * 1000 / max(1, min(kept, count)), 3)})
            if before and peak_set:
                # Not a promise of the cache, but a sanity bound: frames and the decoded sheet inside the budget
                # and Qt's own overhead - the process should not hold several times that because of the cache.
                check(f"{frame}px: the process grew by less than twice the budget while the cache was full",
                      peak_set - before < 2 * budget, f"grew {(peak_set - before) // MiB} MiB")

        # ---- one frame that is larger than half the budget
        make_sheet(project / "art/huge.png", 2048, 2, 1)
        small = FrameCache(max_bytes=24 * MiB)
        pixmap, state = load_frame(project, "art/huge.png", [0, 0, 2048, 2048], small)
        check("a 2048px frame (16 MiB) is drawn but not kept by a 24 MiB cache",
              state == "ok" and pixmap is not None and len(small) == 0 and small.uncached == 1, f"{state}, {small.stats()}")
        del pixmap

        # ---- a clip replayed for a long time
        cache = FrameCache(max_bytes=budget)
        relative, frame, columns = "art/sheet_256_0.png", 256, 16
        for index in range(32):
            load_frame(project, relative, [(index % columns) * frame, (index // columns) * frame, frame, frame], cache)
        gc.collect()
        settled = working_set()
        started = time.perf_counter()
        loops = 400
        for _loop in range(loops):
            for index in range(32):
                load_frame(project, relative, [(index % columns) * frame, (index // columns) * frame, frame, frame], cache)
        replay = time.perf_counter() - started
        gc.collect()
        grown = working_set() - settled
        check(f"replaying a 32-frame clip {loops} times decodes nothing again and does not grow the process",
              cache.misses == 32 and cache.evictions == 0 and (not settled or grown < 8 * MiB),
              f"misses {cache.misses}, grew {grown // 1024} KiB")
        rows.append({"replay_loops": loops, "frames": 32, "ms_per_frame": round(replay * 1000 / (loops * 32), 4),
                     "working_set_growth_kib": grown // 1024, "cache": cache.stats()})

        # ---- project switch and explicit refresh
        other = Path(folder) / "other"
        (other / "art").mkdir(parents=True)
        make_sheet(other / "art/sheet_256.png", 256, 4, 4)
        load_frame(other, "art/sheet_256.png", [0, 0, 256, 256], cache)
        dropped = frame_cache.forget_project(project, cache)
        check("leaving a project drops its frames and keeps the other project's", dropped == 32 and len(cache) == 1)
        check("refreshing an image drops the frames cut from it",
              frame_cache.forget_image(other, "art/sheet_256.png", cache) == 1 and cache.bytes == 0)

    report = {"budget_mib": args.budget_mib, "platform": sys.platform, "python": sys.version.split()[0],
              "measured": rows, "failures": failures,
              "note": "cache bytes are an estimate of decoded pixels; the working set is the whole process as the "
                      "operating system reports it. They are different quantities and are not expected to be equal."}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for row in rows:
        print(json.dumps(row))
    print(f"FRAME CACHE CHECK {'FAIL' if failures else 'PASS'} ({len(failures)} failed)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
