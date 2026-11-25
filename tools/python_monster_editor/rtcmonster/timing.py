"""One time axis for clips, attack timelines and physics ticks.

Authored times are seconds. The authoritative runtime advances in whole
physics ticks, so every authored time is mapped to a tick with one rule:

    tick_of(t) = ceil(t * tick_rate - EPSILON), never below 0

An instant event at ``t`` fires on tick ``tick_of(t)`` (tick 0 is the tick the
pattern or state starts). A window ``[start, end)`` is live on the ticks
``tick_of(start) <= n < tick_of(end)``. This is the legacy behaviour of
"subtract delta, then compare" written with integer ticks, which removes the
float drift that makes ``0.7 - 12 * (1 / 60) <= 0.5`` depend on rounding.

Clip times never feed this module's tick functions from the game side: a clip
only decides what is *drawn*. Changing a clip's FPS therefore cannot move a hit.
"""

import math

DEFAULT_TICK_RATE = 60
EPSILON = 1e-6


def tick_of(seconds, tick_rate=DEFAULT_TICK_RATE):
    return max(0, math.ceil(seconds * tick_rate - EPSILON))


def quantize(seconds, tick_rate=DEFAULT_TICK_RATE):
    """The time the runtime actually acts on."""
    return tick_of(seconds, tick_rate) / tick_rate


def window_ticks(start, end, tick_rate=DEFAULT_TICK_RATE):
    """Number of ticks on which the half-open window ``[start, end)`` is live."""
    return max(0, tick_of(end, tick_rate) - tick_of(start, tick_rate))


def frame_seconds(clip):
    """Seconds each frame is shown: SpriteFrames relative duration divided by the clip FPS."""
    return [frame["duration"] / clip["fps"] for frame in clip["frames"]]


def clip_seconds(clip):
    return math.fsum(frame_seconds(clip))


def frame_start_seconds(clip, index):
    """Seconds from the start of the clip to the start of frame ``index`` (as EnemyAnimationProfile does)."""
    return math.fsum(frame_seconds(clip)[:max(0, index)])


def frame_at(clip, seconds):
    """Frame index shown ``seconds`` into the clip. One-shot clips hold their last frame."""
    durations = frame_seconds(clip)
    total = math.fsum(durations)
    if not durations or total <= 0:
        return 0
    if clip["loop"]:
        seconds %= total
    elapsed = 0.0
    for index, duration in enumerate(durations):
        elapsed += duration
        if seconds < elapsed - 1e-9:
            return index
    return len(durations) - 1


def timeline(pattern, tick_rate=DEFAULT_TICK_RATE):
    """Rows an editor can show next to the authored values: what, authored seconds, tick, effective seconds."""
    rows = []
    for phase in pattern["phases"]:
        rows.append((f"{phase['kind']} start", phase["start"]))
        rows.append((f"{phase['kind']} end", phase["end"]))
    rows.extend((event["type"], event["time"]) for event in pattern["events"])
    rows.append(("pattern end", pattern["duration"]))
    return [{"what": what, "seconds": seconds, "tick": tick_of(seconds, tick_rate),
             "effective_seconds": quantize(seconds, tick_rate)}
            for what, seconds in sorted(rows, key=lambda row: row[1])]
