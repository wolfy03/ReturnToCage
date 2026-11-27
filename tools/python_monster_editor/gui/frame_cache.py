"""Decoded frames, kept by memory budget (MONSTER-STEP 3 stabilization, FIX-08).

``FrameCache`` is a least-recently-used cache limited three ways: a number of entries, a total of
estimated pixel bytes (width x height x 4), and a per-frame share of that total. A count alone is no
bound at all - 128 frames are 32 MiB at 256x256 and 2 GiB at 2048x2048.

**One budget.** ``max_bytes`` is everything the cache holds: the frames *and* the one decoded sheet it
keeps between frames (``total_bytes = bytes + sheet_bytes <= max_bytes``, always). The default is
``DEFAULT_BUDGET`` = 160 MiB = ``FRAME_BUDGET`` (96 MiB, what frames get while a full-size sheet is held)
+ ``SHEET_LIMIT`` (64 MiB, the largest sheet that is kept). With no sheet held, frames may use all of it.

The estimate is the decoded RGBA size. Qt keeps some bookkeeping per pixmap and the process does not
return freed memory to the system at once, so the process's working set is larger than ``bytes`` and
falls later; ``check_frame_cache.py`` measures both.

One cache (``FRAMES``) is shared by every workspace, so an animation view and an attack-timeline view of
the same sheet decode it once.

A PNG cannot be read from the middle: cutting one frame out of a sheet decodes the whole sheet. Doing that
once per frame made a 256-frame strip of a 4096x4096 sheet cost about 160 ms *per frame* (measured). The
cache therefore also holds the one sheet decoded last (``SHEET_LIMIT`` at most, counted inside the same
budget) and cuts further frames out of it in memory. A sheet that would not leave room for even one of
its own frames is not kept; its frames are then read one at a time, slowly but within the budget.
"""

from collections import OrderedDict
from pathlib import Path

from PySide6.QtCore import QRect
from PySide6.QtGui import QImageReader, QPixmap

from .panels import DECODE_LIMIT_MB, forget_image_checks, image_digest

MiB = 1024 * 1024
FRAME_BUDGET = 96 * MiB
# The decoded sheet kept between frames. A larger sheet is read frame by frame instead, slowly but bounded.
SHEET_LIMIT = 64 * MiB
DEFAULT_BUDGET = FRAME_BUDGET + SHEET_LIMIT       # the whole cache: frames and the kept sheet together
DEFAULT_ENTRIES = 512
# A frame larger than this share of the budget is shown but not kept: it would push everything else out.
LARGEST_SHARE = 0.5
BYTES_PER_PIXEL = 4


def pixel_bytes(width, height):
    return int(width) * int(height) * BYTES_PER_PIXEL


class FrameCache:
    def __init__(self, max_bytes=DEFAULT_BUDGET, max_entries=DEFAULT_ENTRIES):
        self.max_bytes, self.max_entries = int(max_bytes), int(max_entries)
        self._rows = OrderedDict()              # key -> (value, bytes); the first row is the oldest
        self.bytes = 0
        self.hits = self.misses = self.evictions = self.uncached = 0
        self.sheet_key, self.sheet, self.sheet_bytes = None, None, 0     # the sheet decoded last, if small enough
        self.sheet_decodes = 0

    @property
    def total_bytes(self):
        """Everything held: frames and the kept sheet. Never more than ``max_bytes``."""
        return self.bytes + self.sheet_bytes

    def keep_sheet(self, key, image, size, room_for=0):
        """Keep a decoded sheet, making room among the frames. Returns False (and keeps nothing) when the
        sheet plus ``room_for`` bytes - one frame cut from it - would not fit the budget at all."""
        size = max(0, int(size))
        if size > SHEET_LIMIT or size + max(0, int(room_for)) > self.max_bytes:
            self.drop_sheet()
            return False
        self.sheet_key, self.sheet, self.sheet_bytes = key, image, size
        self._trim()
        return True

    def drop_sheet(self):
        self.sheet_key, self.sheet, self.sheet_bytes = None, None, 0

    def _trim(self):
        """Evict the oldest frames until the whole cache fits; the sheet goes last."""
        while self._rows and (self.total_bytes > self.max_bytes or len(self._rows) > self.max_entries):
            _old, (_value, freed) = self._rows.popitem(last=False)
            self.bytes -= freed
            self.evictions += 1
        if self.total_bytes > self.max_bytes:
            self.drop_sheet()

    def __len__(self):
        return len(self._rows)

    def __contains__(self, key):
        return key in self._rows

    def get(self, key):
        row = self._rows.get(key)
        if row is None:
            self.misses += 1
            return None
        self._rows.move_to_end(key)
        self.hits += 1
        return row[0]

    def put(self, key, value, size):
        """Keep ``value``. Returns False when it is too large to keep (the caller still uses it)."""
        size = max(0, int(size))
        self.discard(key)
        if size > self.max_bytes * LARGEST_SHARE:
            self.uncached += 1
            return False
        self._rows[key] = (value, size)
        self.bytes += size
        self._trim()
        return key in self._rows

    def discard(self, key):
        row = self._rows.pop(key, None)
        if row is not None:
            self.bytes -= row[1]

    def discard_where(self, predicate):
        """Drop every entry whose key satisfies ``predicate``. Returns how many went."""
        doomed = [key for key in self._rows if predicate(key)]
        for key in doomed:
            self.discard(key)
        if self.sheet_key is not None and predicate(self.sheet_key + (None,)):
            self.drop_sheet()
        return len(doomed)

    def clear(self):
        self._rows.clear()
        self.bytes = 0
        self.drop_sheet()

    def stats(self):
        return {"entries": len(self._rows), "bytes": self.bytes, "total_bytes": self.total_bytes,
                "max_bytes": self.max_bytes,
                "max_entries": self.max_entries, "hits": self.hits, "misses": self.misses,
                "evictions": self.evictions, "uncached": self.uncached, "sheet_bytes": self.sheet_bytes,
                "sheet_decodes": self.sheet_decodes}


FRAMES = FrameCache()


def load_frame(project_root, relative, rect=None, cache=None):
    """``(QPixmap or None, state)`` of one frame at full resolution. Never raises.

    Two checks, kept apart in ``state``: the core's structural PNG check, then a real decode by Qt with a
    memory limit, reading only the requested rectangle. The key holds the project, the path, the file's
    content hash and the rectangle, so another project, a replaced file or another rect can never return
    this frame. A failed decode is not cached: the file may be mid-write and is tried again next time.
    """
    cache = FRAMES if cache is None else cache
    if not relative:
        return None, "none"
    if project_root is None:
        return None, "unchecked"
    digest, state = image_digest(project_root, relative)
    if digest is None:
        return None, state
    key = (str(project_root), relative, digest, tuple(rect) if rect else None)
    pixmap = cache.get(key)
    if pixmap is not None:
        return pixmap, "ok"
    image = _decode(Path(project_root) / relative, key[:3], rect, cache)
    if image is None or image.isNull():
        return None, "decode_failed"
    pixmap = QPixmap.fromImage(image)
    cache.put(key, pixmap, pixel_bytes(pixmap.width(), pixmap.height()))
    return pixmap, "ok"


def _decode(path, sheet_key, rect, cache):
    """The frame's pixels: cut from the sheet decoded last when that is this file, else read from disk."""
    if rect and cache.sheet_key == sheet_key:
        return cache.sheet.copy(QRect(*rect))
    reader = QImageReader(str(path))
    reader.setAllocationLimit(DECODE_LIMIT_MB)
    size = reader.size()
    sheet_size = pixel_bytes(size.width(), size.height()) if size.isValid() else 0
    if rect and 0 < sheet_size <= SHEET_LIMIT and sheet_size + pixel_bytes(rect[2], rect[3]) <= cache.max_bytes:
        sheet = reader.read()                       # the whole sheet, once
        if sheet.isNull():
            return None
        cache.sheet_decodes += 1
        cache.keep_sheet(sheet_key, sheet, pixel_bytes(sheet.width(), sheet.height()), pixel_bytes(rect[2], rect[3]))
        return sheet.copy(QRect(*rect))
    if rect:
        reader.setClipRect(QRect(*rect))            # too large to keep: decode, cut, forget
    return reader.read()


def forget_project(project_root, cache=None):
    """Drop the frames of one project (it was closed or replaced)."""
    return (FRAMES if cache is None else cache).discard_where(lambda key: key[0] == str(project_root))


def forget_image(project_root, relative, cache=None):
    """Drop every frame cut from one file and have the file hashed again on its next use.

    The cheap change detector is the file's size and modification time; this is the explicit path
    ("refresh") for a file that changed without either moving.
    """
    forget_image_checks(project_root, relative)
    return (FRAMES if cache is None else cache).discard_where(
        lambda key: key[0] == str(project_root) and key[1] == relative)
