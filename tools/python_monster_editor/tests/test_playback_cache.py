"""Playback contract (no Qt) and the byte-budget frame cache (MONSTER-STEP 3 stabilization, FIX-07 / FIX-08)."""

import shutil

import pytest

from conftest import PROJECT
from application.playback import MAX_STEP_SECONDS, PAUSED, PLAYING, STOPPED, Playback
from rtcmonster.timing import clip_seconds, frame_at, frame_start_seconds

BEETLE = "assets/characters/enemies/sewer_beetle"


def clip(durations, fps=10, loop=False):
    return {"id": "c", "fps": fps, "loop": loop,
            "frames": [{"image": "i", "rect": None, "duration": value, "offset": [0, 0]} for value in durations]}


# -------------------------------------------------------------------------------------------------- playback
def test_frame_boundaries_follow_relative_durations_over_fps():
    playback = Playback(clip([1, 2, 0.5, 1], fps=10))
    assert playback.duration == pytest.approx(0.45) and playback.state == STOPPED and playback.frame == 0
    # Seconds per frame = duration / fps: 0.1, 0.2, 0.05, 0.1 -> boundaries at 0.1, 0.3, 0.35.
    for seconds, frame in ((0, 0), (0.0999, 0), (0.1, 1), (0.1001, 1), (0.2999, 1), (0.3, 2), (0.3499, 2), (0.35, 3),
                           (0.4499, 3), (0.45, 3), (9, 3)):
        playback.seek(seconds)
        assert playback.frame == frame == frame_at(playback.clip, seconds), seconds
    playback.seek_frame(2)
    assert playback.time == pytest.approx(0.3) and playback.frame_window == pytest.approx((0.3, 0.35))
    playback.seek_frame(99)
    assert playback.frame == 3
    playback.seek(-5)
    assert playback.time == 0


def test_a_one_shot_clip_pauses_on_its_last_frame_and_play_starts_over():
    playback = Playback(clip([1, 1, 1]))
    assert playback.play() and playback.state == PLAYING
    assert not playback.advance(0.05) and playback.advance(0.06)          # crossed into frame 1
    playback.pause()
    assert playback.state == PAUSED and not playback.advance(10) and playback.frame == 1
    playback.play()
    assert playback.time == pytest.approx(0.11)                           # resumed, not restarted
    playback.advance(0.5)
    assert playback.finished and playback.state == PAUSED and playback.frame == 2
    assert playback.time == pytest.approx(playback.duration) and playback.position == pytest.approx(0.3)
    playback.play()
    assert playback.time == 0 and playback.state == PLAYING
    playback.stop()
    assert playback.state == STOPPED and playback.time == 0 and not playback.advance(1)


def test_a_looping_clip_wraps_and_counts_passes():
    playback = Playback(clip([1, 1], fps=4, loop=True))
    playback.play()
    for _ in range(9):
        playback.advance(0.25)
    assert playback.time == pytest.approx(2.25) and playback.loop_count == 4
    assert playback.position == pytest.approx(0.25) and playback.frame == 1 and not playback.finished
    assert playback.frame_window == pytest.approx((0.25, 0.5))


def test_a_long_pause_between_ticks_is_not_caught_up():
    playback = Playback(clip([1] * 10, loop=True))
    playback.play()
    playback.advance(3600)
    assert playback.time == MAX_STEP_SECONDS
    for bad in (0, -1, float("nan")):
        assert not playback.advance(bad)
    assert playback.time == MAX_STEP_SECONDS


@pytest.mark.parametrize("fps", [0.5, 1, 12, 60, 120])
def test_fast_and_slow_clips_use_the_same_rule(fps):
    source = clip([1, 3, 2], fps=fps)
    playback = Playback(source)
    assert playback.duration == pytest.approx(clip_seconds(source)) == pytest.approx(6 / fps)
    for index in range(3):
        playback.seek_frame(index)
        assert playback.frame == index and playback.frame_window[0] == pytest.approx(frame_start_seconds(source, index))


def test_a_clip_that_cannot_play_is_not_available():
    for unusable in (None, clip([]), clip([1], fps=0)):
        playback = Playback(unusable)
        assert not playback.available and not playback.play() and playback.duration == 0
        assert playback.frame == 0 and playback.frame_window == (0.0, 0.0) and not playback.finished
        playback.seek(3)
        playback.seek_frame(2)
        assert playback.time == 0
    playback = Playback(clip([1, 1]))
    playback.play()
    playback.advance(0.15)
    playback.set_clip(clip([1, 1, 1]), keep_time=True)
    assert playback.state == PLAYING and playback.time == pytest.approx(0.15)
    playback.set_clip(clip([1]))
    assert playback.state == STOPPED and playback.time == 0


# ----------------------------------------------------------------------------------------------- frame cache
qt = pytest.importorskip("PySide6")

from gui import frame_cache  # noqa: E402
from gui.frame_cache import MiB, FrameCache, load_frame, pixel_bytes  # noqa: E402


def test_the_budget_is_bytes_not_a_number_of_frames():
    assert pixel_bytes(256, 256) * 128 == 32 * MiB and pixel_bytes(2048, 2048) * 128 == 2048 * MiB
    cache = FrameCache(max_bytes=10 * MiB, max_entries=100)
    for index in range(12):
        assert cache.put(index, f"frame {index}", MiB)
    assert len(cache) == 10 and cache.bytes == 10 * MiB and cache.evictions == 2
    assert 0 not in cache and 1 not in cache and 2 in cache                # the oldest went first
    assert cache.get(2) == "frame 2"                                       # a hit makes it the newest
    cache.put("new", "x", MiB)
    assert 2 in cache and 3 not in cache
    cache.put("big", "y", 4 * MiB)                                         # several entries make room at once
    assert cache.bytes <= cache.max_bytes and "big" in cache
    assert cache.stats()["hits"] == 1


def test_one_huge_frame_is_shown_but_not_kept():
    cache = FrameCache(max_bytes=8 * MiB)
    cache.put("small", "s", MiB)
    assert not cache.put("huge", "h", 5 * MiB)                             # more than half the budget
    assert "huge" not in cache and "small" in cache and cache.uncached == 1
    assert cache.put("half", "h", 4 * MiB) and cache.bytes == 5 * MiB


def test_the_entry_limit_still_applies_to_tiny_frames():
    cache = FrameCache(max_bytes=MiB, max_entries=3)
    for index in range(5):
        cache.put(index, index, 16)
    assert len(cache) == 3 and cache.bytes == 48
    cache.put(4, "again", 32)                                              # replacing does not double count
    assert len(cache) == 3 and cache.bytes == 64
    assert cache.discard_where(lambda key: key in (2, 3)) == 2 and cache.bytes == 32
    cache.clear()
    assert len(cache) == 0 and cache.bytes == 0 and cache.get(4) is None and cache.misses == 1


def test_frames_are_keyed_by_project_path_content_and_rect(app, tmp_path):
    cache = FrameCache()
    projects = []
    for name in ("first", "second"):
        project = tmp_path / name
        (project / "art").mkdir(parents=True)
        shutil.copy(PROJECT / BEETLE / "idle.png", project / "art/sheet.png")
        projects.append(project)
    first, second = projects
    one, state = load_frame(first, "art/sheet.png", [0, 0, 64, 48], cache)
    assert state == "ok" and (one.width(), one.height()) == (64, 48) and cache.bytes == pixel_bytes(64, 48)
    assert load_frame(first, "art/sheet.png", [0, 0, 64, 48], cache)[0] is one and cache.hits == 1
    assert load_frame(first, "art/sheet.png", [64, 0, 64, 48], cache)[0] is not one       # another rect
    assert load_frame(second, "art/sheet.png", [0, 0, 64, 48], cache)[0] is not one       # another project
    assert len(cache) == 3
    shutil.copy(PROJECT / BEETLE / "move.png", first / "art/sheet.png")                    # the file was replaced
    changed, state = load_frame(first, "art/sheet.png", [0, 0, 64, 48], cache)
    assert state == "ok" and changed is not one
    assert frame_cache.forget_image(first, "art/sheet.png", cache) == 3 and len(cache) == 1
    assert frame_cache.forget_project(second, cache) == 1 and len(cache) == 0


def test_a_failed_decode_is_tried_again_instead_of_being_remembered(app, tmp_path, monkeypatch):
    from gui import panels
    cache = FrameCache()
    project = tmp_path / "project"
    (project / "art").mkdir(parents=True)
    shutil.copy(PROJECT / BEETLE / "idle.png", project / "art/sheet.png")
    monkeypatch.setattr(frame_cache, "DECODE_LIMIT_MB", 1)
    monkeypatch.setattr(frame_cache.QImageReader, "read", lambda self: frame_cache.QPixmap().toImage())
    assert load_frame(project, "art/sheet.png", None, cache) == (None, "decode_failed") and len(cache) == 0
    monkeypatch.undo()
    assert load_frame(project, "art/sheet.png", None, cache)[1] == "ok" and len(cache) == 1
    assert load_frame(project, "art/absent.png", None, cache) == (None, "missing")
    assert load_frame(None, "art/sheet.png", None, cache) == (None, "unchecked")
    assert load_frame(project, "", None, cache) == (None, "none")
    panels.forget_image_checks(project)


def test_an_explicit_refresh_rereads_a_file_whose_size_and_time_did_not_move(app, tmp_path):
    import os
    from gui import panels
    cache = FrameCache()
    project = tmp_path / "project"
    (project / "art").mkdir(parents=True)
    target = project / "art/sheet.png"
    payload = (PROJECT / BEETLE / "idle.png").read_bytes()
    target.write_bytes(payload)
    stat = target.stat()
    digest = panels.image_digest(project, "art/sheet.png")[0]
    load_frame(project, "art/sheet.png", None, cache)
    # Same length, same modification time, different pixels: the cheap detector cannot see it.
    other = bytearray(payload)
    other[-20] ^= 0xFF
    target.write_bytes(bytes(other))
    os.utime(target, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    assert panels.image_digest(project, "art/sheet.png")[0] == digest          # still the remembered answer
    frame_cache.forget_image(project, "art/sheet.png", cache)
    assert panels.image_digest(project, "art/sheet.png")[0] != digest          # really read again
    assert len(cache) == 0


def test_the_shared_cache_is_bounded_while_a_large_clip_plays(app, tmp_path):
    cache = FrameCache(max_bytes=64 * 48 * 4 * 3)                              # room for three small frames
    for index in range(40):
        load_frame(PROJECT, f"{BEETLE}/move.png", [64 * (index % 6 if index % 2 else 0), 0, 64, 48], cache)
        assert cache.bytes <= cache.max_bytes and len(cache) <= 3
    assert cache.evictions > 0 and cache.hits > 0


def test_a_sheet_is_decoded_once_for_all_the_frames_cut_from_it(app, tmp_path, monkeypatch):
    cache = FrameCache()
    for index in range(6):
        pixmap, state = load_frame(PROJECT, f"{BEETLE}/move.png", [64 * index, 0, 64, 48], cache)
        assert state == "ok" and (pixmap.width(), pixmap.height()) == (64, 48)
    assert cache.sheet_decodes == 1 and len(cache) == 6 and cache.sheet_bytes == pixel_bytes(384, 48)
    assert cache.stats()["sheet_bytes"] == cache.sheet_bytes
    load_frame(PROJECT, f"{BEETLE}/idle.png", [0, 0, 64, 48], cache)             # another sheet takes the slot
    assert cache.sheet_decodes == 2 and cache.sheet_key[1] == f"{BEETLE}/idle.png"
    load_frame(PROJECT, f"{BEETLE}/idle.png", None, cache)                       # a whole image is not a sheet read
    assert cache.sheet_decodes == 2
    assert frame_cache.forget_image(PROJECT, f"{BEETLE}/idle.png", cache) == 2 and cache.sheet is None
    load_frame(PROJECT, f"{BEETLE}/move.png", [0, 0, 64, 48], cache)
    load_frame(PROJECT, f"{BEETLE}/attack.png", [0, 0, 64, 48], cache)
    assert frame_cache.forget_project(PROJECT, cache) == 7 and cache.sheet is None and cache.sheet_bytes == 0
    # A sheet too large to keep is still read, frame by frame, and never kept.
    monkeypatch.setattr(frame_cache, "SHEET_LIMIT", 1024)
    large = FrameCache()
    assert load_frame(PROJECT, f"{BEETLE}/move.png", [64, 0, 64, 48], large)[1] == "ok"
    assert large.sheet is None and large.sheet_decodes == 0 and len(large) == 1
    large.clear()
    assert large.sheet is None
