"""One time axis for clips, attack timelines and physics ticks.

Authored times are seconds. The authoritative runtime advances in whole
physics ticks, so every authored time is mapped to a tick with one rule:

    tick_of(t) = ceil(t * tick_rate - EPSILON), never below 0

* **Tick 0** is the tick in which the pattern or state starts. An event at
  ``t <= 0`` runs in that tick.
* An **instant event** at ``t`` runs in tick ``tick_of(t)``, once.
* A **window** ``[start, end)`` is live on the ticks ``tick_of(start) <= n < tick_of(end)``:
  the start tick is included, the end tick is not. ``window_ticks`` counts them; 0 means the window is
  shorter than one tick and nothing would ever happen in it.
* Events that fall into the **same tick** run in the order they are listed in the document
  (``schedule`` returns exactly that order). Their authored times do not break the tie.
* A pattern **ends** in tick ``tick_of(duration)``. Events of that tick run before the pattern completes.
* A long frame does not skip ticks: the engine runs the missed physics ticks one after another, so every
  tick number is visited in order.

This is the legacy behaviour of "subtract delta, then compare" written with
integer ticks, which removes the float drift that makes
``0.7 - 12 * (1 / 60) <= 0.5`` depend on rounding.

Clip times never feed the tick functions from the game side: a clip only
decides what is *drawn*. Changing a clip's FPS therefore cannot move a hit.

The tick rate is always an argument. 60 is only the default, and it is checked
against the real project by check_godot_contract.py. Nothing here has been
compared with a data-driven Godot runtime, because none exists yet.
"""

import math

DEFAULT_TICK_RATE = 60
EPSILON = 1e-6
MAX_TICK_RATE = 1000


def check_tick_rate(tick_rate):
    """Raise ValueError unless ``tick_rate`` is a usable physics rate."""
    if isinstance(tick_rate, bool) or not isinstance(tick_rate, (int, float)) or not math.isfinite(tick_rate) \
            or not 0 < tick_rate <= MAX_TICK_RATE:
        raise ValueError(f"tick rate must be a finite number in (0, {MAX_TICK_RATE}], got {tick_rate!r}")
    return tick_rate


def _seconds(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"time must be a finite number of seconds, got {value!r}")
    return value


def tick_of(seconds, tick_rate=DEFAULT_TICK_RATE):
    """The tick in which a time is reached. Negative times belong to tick 0."""
    return max(0, math.ceil(_seconds(seconds) * check_tick_rate(tick_rate) - EPSILON))


def quantize(seconds, tick_rate=DEFAULT_TICK_RATE):
    """The time the runtime actually acts on."""
    return tick_of(seconds, tick_rate) / tick_rate


def window_ticks(start, end, tick_rate=DEFAULT_TICK_RATE):
    """Number of ticks on which the half-open window ``[start, end)`` is live."""
    return max(0, tick_of(end, tick_rate) - tick_of(start, tick_rate))


def frame_seconds(clip):
    """Seconds each frame is shown: SpriteFrames relative duration divided by the clip FPS."""
    if not clip["fps"] > 0:
        raise ValueError(f"clip fps must be positive, got {clip['fps']!r}")
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
    seconds = max(0.0, _seconds(seconds))
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


def schedule(pattern, tick_rate=DEFAULT_TICK_RATE):
    """Events in execution order: by tick, then by position in the document.

    Returns ``[{"tick", "index", "event"}]`` where ``index`` is the event's
    position in ``pattern["events"]``.
    """
    rows = [{"tick": tick_of(event["time"], tick_rate), "index": index, "event": event}
            for index, event in enumerate(pattern["events"])]
    return sorted(rows, key=lambda row: (row["tick"], row["index"]))


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
