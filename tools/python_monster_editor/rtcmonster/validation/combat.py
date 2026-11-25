"""Collision shapes and attack timelines.

The rules read event *flags* from the registry (``damaging``, ``arms``,
``disarms``, ``instant_strike``, ``leaves_ground``). A new event type gets the
right checks by declaring its flags; nothing here names an event.
"""

from ..schema import resolve
from ..timing import tick_of, window_ticks
from .context import rule
from .report import ATTACK, COLLISION, FAIL, WARNING, define

TIME_TOLERANCE = 1e-6

define(COLLISION, WARNING, {
    "no_enabled_hurtbox": "No default hurtbox is enabled: nothing can hit this monster.",
    "nonstandard_body_layer": "The body's collision layer or mask differs from the project convention (1 / 1).",
    "unused_hitbox": "A hitbox is defined but no attack pattern arms it.",
})
define(ATTACK, FAIL, {
    "phases_missing": "An attack pattern has no phases.",
    "phase_ends_before_it_starts": "A phase ends at or before its start.",
    "phases_not_contiguous": "Phases leave a gap or overlap.",
    "phases_do_not_fill_duration": "The phases do not end where the pattern ends.",
    "event_after_pattern_end": "An event is scheduled after the pattern has ended.",
    "strike_outside_active_phase": "An instant strike is neither in an active phase nor at the end of a windup.",
    "hitbox_already_enabled": "A hitbox is armed again while it is still armed.",
    "hitbox_disabled_before_enabled": "A hitbox is disarmed without having been armed.",
    "hitbox_outside_active_phase": "A hitbox is armed outside a single active phase.",
    "window_shorter_than_one_tick": "A phase or hitbox window contains no physics tick at this tick rate.",
    "multi_hit_interval_below_one_tick": "The multi-hit interval is shorter than one physics tick.",
    "range_order": "The pattern's minimum range is larger than its maximum range.",
})
define(ATTACK, WARNING, {
    "no_active_phase": "The pattern has neither an active phase nor an instant strike.",
    "pattern_without_hit": "No event of the pattern can hurt anything.",
    "pattern_deals_no_damage": "The pattern can hit, but its damage multiplier is 0.",
    "multi_hit_without_hitbox": "Multi-hit is selected, but only an armed hitbox can hit repeatedly.",
    "landing_without_impulse": "The pattern waits for a landing but nothing lifts the actor off the ground.",
    "event_order_differs_from_time": "Two events run in the same tick in an order that contradicts their times.",
})


@rule
def collision(context):
    data = context.data["collision"]
    body = data["body"]
    if (body["layer"], body["mask"]) != (1, 1):
        context.add("nonstandard_body_layer", "collision.body",
                    f"layer {body['layer']} / mask {body['mask']}; the project convention is 1 / 1")
    if not any(row["enabled"] for row in data["hurtboxes"]):
        context.add("no_enabled_hurtbox", "collision.hurtboxes", "Nothing can hit this monster by default.")
    events = context.registry.events
    used = {event[events[event["type"]].arms] for pattern in context.data["attack_patterns"]
            for event in pattern["events"] if events[event["type"]].arms}
    for index, row in enumerate(data["hitboxes"]):
        if row["id"] not in used:
            context.add("unused_hitbox", f"collision.hitboxes[{index}]", row["id"], subject=row["id"])


def _phases(context, pattern, path, instant):
    phases = pattern["phases"]
    if not phases:
        context.add("phases_missing", f"{path}.phases", subject=pattern["id"])
        return []
    ordered = True
    for index, phase in enumerate(phases):
        if phase["end"] <= phase["start"]:
            ordered = False
            context.add("phase_ends_before_it_starts", f"{path}.phases[{index}]",
                        f"start {phase['start']}, end {phase['end']}", subject=pattern["id"])
    expected = 0
    for index, phase in enumerate(phases):
        if ordered and abs(phase["start"] - expected) > TIME_TOLERANCE:
            context.add("phases_not_contiguous", f"{path}.phases[{index}].start",
                        f"expected {expected}, found {phase['start']}", subject=pattern["id"])
        expected = phase["end"]
    if ordered and abs(expected - pattern["duration"]) > TIME_TOLERANCE:
        context.add("phases_do_not_fill_duration", f"{path}.phases",
                    f"phases end at {expected} s, the pattern lasts {pattern['duration']} s",
                    related=(f"{path}.duration",), subject=pattern["id"])
    actives = [(phase["start"], phase["end"]) for phase in phases if phase["kind"] == "active"]
    if not actives and not instant:
        context.add("no_active_phase", f"{path}.phases", subject=pattern["id"])
    for index, phase in enumerate(phases):
        if phase["end"] > phase["start"] and window_ticks(phase["start"], phase["end"], context.tick_rate) == 0:
            context.add("window_shorter_than_one_tick", f"{path}.phases[{index}]",
                        f"{phase['kind']} {phase['start']}..{phase['end']} s has no physics tick at "
                        f"{context.tick_rate} Hz", subject=pattern["id"])
    return actives


def _hitbox_window(context, pattern, start, event_path, end, actives):
    if not any(low - TIME_TOLERANCE <= start and end <= high + TIME_TOLERANCE for low, high in actives):
        context.add("hitbox_outside_active_phase", event_path, f"armed {start}..{end} s", subject=pattern["id"])
    elif window_ticks(start, end, context.tick_rate) == 0:
        context.add("window_shorter_than_one_tick", event_path, f"armed {start}..{end} s", subject=pattern["id"])


@rule
def attack_patterns(context):
    stats, registry = context.data["stats"], context.registry.events
    for index, pattern in enumerate(context.data["attack_patterns"]):
        path, duration, subject = f"attack_patterns[{index}]", pattern["duration"], pattern["id"]
        kinds = [registry[event["type"]] for event in pattern["events"]]
        actives = _phases(context, pattern, path, any(kind.instant_strike for kind in kinds))
        # A legacy strike is an instant between wind-up and recovery, so it needs no active window.
        windup_ends = [(phase["end"], phase["end"]) for phase in pattern["phases"] if phase["kind"] == "windup"]
        live = {}
        for event_index, event in sorted(enumerate(pattern["events"]), key=lambda row: row[1]["time"]):
            event_path, kind, time = f"{path}.events[{event_index}]", registry[event["type"]], event["time"]
            if time > duration + TIME_TOLERANCE:
                context.add("event_after_pattern_end", f"{event_path}.time",
                            f"{time} s is after the pattern's {duration} s", subject=subject)
                continue
            if kind.instant_strike and not any(start - TIME_TOLERANCE <= time <= end + TIME_TOLERANCE
                                               for start, end in actives + windup_ends):
                context.add("strike_outside_active_phase", f"{event_path}.time", time, subject=subject)
            if kind.arms:
                hitbox = event[kind.arms]
                if hitbox in live:
                    context.add("hitbox_already_enabled", event_path, hitbox, subject=subject)
                else:
                    live[hitbox] = (time, event_path)
            if kind.disarms:
                hitbox = event[kind.disarms]
                if hitbox not in live:
                    context.add("hitbox_disabled_before_enabled", event_path, hitbox, subject=subject)
                else:
                    _hitbox_window(context, pattern, *live.pop(hitbox), time, actives)
        for start, event_path in live.values():
            # Never disarmed: the hitbox is released when the pattern ends.
            _hitbox_window(context, pattern, start, event_path, duration, actives)
        # Events of one tick run in document order. Warn when that order contradicts the authored times.
        events = pattern["events"]
        for later in range(1, len(events)):
            for earlier in range(later):
                first, second = events[earlier], events[later]
                if second["time"] < first["time"] - TIME_TOLERANCE and (
                        tick_of(first["time"], context.tick_rate) == tick_of(second["time"], context.tick_rate)):
                    context.add("event_order_differs_from_time", f"{path}.events[{later}]",
                                f"{second['type']} at {second['time']} s is listed after {first['type']} at "
                                f"{first['time']} s; both run in tick "
                                f"{tick_of(first['time'], context.tick_rate)}, in listed order",
                                related=(f"{path}.events[{earlier}]",), subject=subject)
        damage = pattern["damage"]
        if not any(kind.damaging for kind in kinds):
            context.add("pattern_without_hit", path, subject, subject=subject)
        elif damage["multiplier"] == 0:
            context.add("pattern_deals_no_damage", f"{path}.damage.multiplier", subject=subject)
        if damage["hit_policy"] == "multi_hit":
            if tick_of(damage["multi_hit_interval"], context.tick_rate) < 1:
                context.add("multi_hit_interval_below_one_tick", f"{path}.damage.multi_hit_interval", subject=subject)
            if not any(kind.arms for kind in kinds):
                context.add("multi_hit_without_hitbox", f"{path}.damage.hit_policy",
                            "Only a hitbox that stays armed can hit repeatedly.", subject=subject)
        low, high = resolve(pattern["range"]["min"], stats), resolve(pattern["range"]["max"], stats)
        if low > high:
            context.add("range_order", f"{path}.range", f"min {low} > max {high}", subject=subject)
        if pattern["completion"]["mode"] == "duration_and_landed" and not any(kind.leaves_ground for kind in kinds):
            context.add("landing_without_impulse", f"{path}.completion",
                        "The pattern waits for a landing but never leaves the ground.", subject=subject)
