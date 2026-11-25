"""GATE F: the coordinate and time contracts over their whole input space, not a few samples.

Nothing here runs Godot. These tests fix the *Python* side of the contract;
whether a data-driven runtime follows it stays NOT_EVALUATED until one exists.
"""

import itertools
import math

import pytest

from conftest import edit, load
from rtcmonster import validate
from rtcmonster.geometry import (SHAPES, ShapeKind, actor_to_sprite, bottom_center_offset, mirror_point,
                                 mirror_shape, shape_bounds, slice_grid, sprite_to_actor, to_godot_shape)
from rtcmonster.timing import (check_tick_rate, clip_seconds, frame_at, frame_start_seconds, quantize, schedule,
                               tick_of, timeline, window_ticks)

RATES = (30, 60, 120)


# ------------------------------------------------------------------------------------------------ geometry
FACINGS = (1, -1)
ART_DIRECTIONS = (True, False)
SCALES = ([1, 1], [2, 2], [0.5, 3], [1.5, 0.25])
OFFSETS = ([0, 0], [4, -19], [-7.5, 12], [0, -64])
FRAMES = ((64, 48), (64, 64), (256, 256), (33, 17))
FRAME_OFFSETS = ((0, 0), (3, -2))
POINTS = ((0, 0), (32, 24), (63, 47), (10.5, 200), (-5, -5))


@pytest.mark.parametrize("facing, faces_right, scale, offset", list(
    itertools.product(FACINGS, ART_DIRECTIONS, SCALES, OFFSETS)))
def test_sprite_to_actor_round_trips(facing, faces_right, scale, offset):
    presentation = {"faces_right_by_default": faces_right, "visual_scale": scale, "visual_offset": offset}
    for frame, frame_offset, point in itertools.product(FRAMES, FRAME_OFFSETS, POINTS):
        actor = sprite_to_actor(point, frame, presentation, facing, frame_offset)
        back = actor_to_sprite(actor, frame, presentation, facing, frame_offset)
        assert back == pytest.approx(point, abs=1e-9)
        # Flipping the facing mirrors X around the actor origin and leaves Y alone.
        flipped = sprite_to_actor(point, frame, presentation, -facing, frame_offset)
        assert flipped == pytest.approx([-actor[0], actor[1]], abs=1e-9)
        # The frame centre always lands on the scaled visual offset.
        centre = sprite_to_actor((frame[0] / 2, frame[1] / 2), frame, presentation, 1)
        direction = 1 if faces_right else -1
        assert centre == pytest.approx([offset[0] * scale[0] * direction, offset[1] * scale[1]], abs=1e-9)


@pytest.mark.parametrize("frame, scale, margin", list(itertools.product(FRAMES, SCALES, (0, 2))))
def test_the_bottom_centre_preset_puts_the_feet_on_the_body_bottom(frame, scale, margin):
    body = {"type": "rectangle", "center": [0, 3], "size": [30, 22]}
    presentation = {"faces_right_by_default": True, "visual_scale": scale,
                    "visual_offset": bottom_center_offset(frame, scale, body, margin)}
    feet = sprite_to_actor((frame[0] / 2, frame[1] - margin), frame, presentation)
    assert feet == pytest.approx([0, shape_bounds(body)[3]], abs=1e-9)


def test_asymmetric_and_multiple_boxes_mirror_consistently():
    boxes = [{"type": "rectangle", "center": [24, -6], "size": [26, 18]},
             {"type": "circle", "center": [16, -4], "radius": 8},
             {"type": "rectangle", "center": [-10, 5], "size": [4, 40]}]
    for box in boxes:
        left, top, right, bottom = shape_bounds(box)
        mirrored = shape_bounds(mirror_shape(box, -1))
        assert mirrored == (-right, top, -left, bottom)
        assert mirror_shape(mirror_shape(box, -1), -1) == box and mirror_shape(box, 1) == box
        assert mirror_shape(box, -1) is not box and box["center"][0] != -box["center"][0]
        godot = to_godot_shape(box, -1)
        assert godot["position"] == [-box["center"][0], box["center"][1]]
        assert {key: value for key, value in godot.items() if key in ("size", "radius")} == {
            key: value for key, value in box.items() if key in ("size", "radius")}


def test_collision_is_never_scaled_by_the_visual_scale(beetle):
    big = edit(beetle, lambda d: d["presentation"].update(visual_scale=[3, 3]))
    assert big.data["collision"] == beetle.data["collision"]
    for document in (beetle, big):
        assert to_godot_shape(document.data["collision"]["body"]["shape"])["size"] == [34, 22]
        assert shape_bounds(document.data["collision"]["hurtboxes"][0]["shape"]) == (-20, -14, 20, 14)


@pytest.mark.parametrize("call", [
    lambda: shape_bounds({"type": "capsule", "center": [0, 0]}),
    lambda: to_godot_shape({"type": "polygon", "center": [0, 0], "points": []}),
    lambda: mirror_shape({"center": [0, 0]}, 1),
    lambda: shape_bounds({"type": "rectangle", "center": [float("nan"), 0], "size": [1, 1]}),
    lambda: mirror_point([1, 1], float("nan")),
    lambda: sprite_to_actor((float("inf"), 0), (64, 64), {"faces_right_by_default": True, "visual_scale": [1, 1],
                                                          "visual_offset": [0, 0]}),
    lambda: actor_to_sprite((0, 0), (64, 64), {"faces_right_by_default": True, "visual_scale": [-1, 1],
                                               "visual_offset": [0, 0]}),
    lambda: sprite_to_actor((0, 0), (64, 64), {"faces_right_by_default": True, "visual_scale": [1, 1],
                                               "visual_offset": [float("nan"), 0]}),
    lambda: bottom_center_offset((64, 64), [1, 0], {"type": "rectangle", "center": [0, 0], "size": [1, 1]}),
    lambda: slice_grid("s", 64, 64, 4, origin=(-1, 0)),
])
def test_degenerate_geometry_input_raises_a_value_error(call):
    with pytest.raises(ValueError):
        call()


def test_a_new_shape_is_one_registry_entry(monkeypatch):
    capsule = ShapeKind("CapsuleShape2D",
                        lambda shape: (shape["radius"], shape["height"] / 2),
                        lambda shape: {"radius": shape["radius"], "height": shape["height"]})
    monkeypatch.setitem(SHAPES, "capsule", capsule)
    shape = {"type": "capsule", "center": [5, -2], "radius": 6, "height": 30}
    assert shape_bounds(shape) == (-1, -17, 11, 13)
    assert shape_bounds(mirror_shape(shape, -1)) == (-11, -17, 1, 13)
    assert to_godot_shape(shape, -1) == {"shape_class": "CapsuleShape2D", "position": [-5, -2], "radius": 6,
                                         "height": 30}
    monkeypatch.undo()
    with pytest.raises(ValueError):
        shape_bounds(shape)                                   # outside the fixture the schema still rejects it


def test_the_shape_registry_matches_the_schema():
    from rtcmonster.schema import RESERVED_SHAPES, SHAPE
    assert set(SHAPES) == set(SHAPE.variants) and not set(SHAPES) & set(RESERVED_SHAPES)


# -------------------------------------------------------------------------------------------------- timing
@pytest.mark.parametrize("rate", RATES)
def test_tick_boundaries_at_every_rate(rate):
    step = 1 / rate
    for n in range(0, 400):
        exact = n * step
        assert tick_of(exact, rate) == n                       # exactly on the boundary
        assert tick_of(exact + step * 0.01, rate) == n + 1     # just after: the next tick is the first to reach it
        if n:
            assert tick_of(exact - step * 0.01, rate) == n     # just before: still this tick
        assert quantize(exact, rate) == pytest.approx(exact)
    assert tick_of(0, rate) == 0 and tick_of(-3, rate) == 0
    assert tick_of(3600, rate) == 3600 * rate                  # an hour-long timeline stays exact


@pytest.mark.parametrize("rate", RATES)
def test_accumulated_float_time_reaches_the_same_tick_as_the_exact_time(rate):
    for seconds in (0.2, 0.25, 0.45, 0.7, 1.2, 2.5):
        elapsed, ticks = 0.0, 0
        while elapsed < seconds - 1e-6:                         # the legacy "add delta, then compare" loop
            elapsed += 1 / rate
            ticks += 1
        assert ticks == tick_of(seconds, rate)


@pytest.mark.parametrize("rate, expected", [(30, 3), (60, 6), (120, 12)])
def test_a_window_is_half_open_and_scales_with_the_rate(rate, expected):
    assert window_ticks(0.15, 0.25, rate) == expected
    start, end = tick_of(0.15, rate), tick_of(0.25, rate)
    live = [n for n in range(0, 2 * rate) if start <= n < end]
    assert len(live) == expected and live[0] == start and end not in live
    assert window_ticks(0.2, 0.2, rate) == 0 and window_ticks(0.3, 0.2, rate) == 0


def test_a_window_shorter_than_one_tick_exists_only_at_a_high_enough_rate():
    assert [window_ticks(0.201, 0.209, rate) for rate in RATES] == [0, 0, 1]
    assert [window_ticks(0.20, 0.21, rate) for rate in RATES] == [1, 1, 2]


@pytest.mark.parametrize("bad", [0, -60, float("nan"), float("inf"), 1001, "60", None, True])
def test_unusable_tick_rates_are_rejected_everywhere(bad):
    for call in (lambda: check_tick_rate(bad), lambda: tick_of(0.2, bad), lambda: quantize(0.2, bad),
                 lambda: window_ticks(0, 1, bad), lambda: schedule(load("sewer_beetle").data["attack_patterns"][0], bad),
                 lambda: timeline(load("sewer_beetle").data["attack_patterns"][0], bad)):
        with pytest.raises(ValueError):
            call()


@pytest.mark.parametrize("bad", [float("nan"), float("inf"), -float("inf"), "0.2", None, True])
def test_unusable_times_are_rejected(bad):
    with pytest.raises(ValueError):
        tick_of(bad)
    with pytest.raises(ValueError):
        frame_at({"fps": 10, "loop": False, "frames": [{"duration": 1}]}, bad)


def test_fractional_rates_are_allowed():
    assert check_tick_rate(59.94) == 59.94 and tick_of(1, 59.94) == 60 and tick_of(1, 0.5) == 1


@pytest.mark.parametrize("rate", RATES)
def test_same_tick_events_run_in_document_order(rate, rat):
    pattern = rat.data["attack_patterns"][1]                    # LockFacing 0, then three events at 0.3, two at 0.55
    order = schedule(pattern, rate)
    assert [row["index"] for row in order] == [0, 1, 2, 3, 4]
    assert [row["event"]["type"] for row in order] == ["LockFacing", "ApplyMovement", "EnableHitbox",
                                                       "DisableHitbox", "UnlockFacing"]
    assert order[1]["tick"] == order[2]["tick"] == tick_of(0.3, rate)
    assert order[0]["tick"] == 0                                # a 0-second event runs in the starting tick
    shuffled = dict(pattern, events=[pattern["events"][index] for index in (2, 1, 0, 4, 3)])
    assert [row["event"]["type"] for row in schedule(shuffled, rate)] == [
        "LockFacing", "EnableHitbox", "ApplyMovement", "UnlockFacing", "DisableHitbox"]


def test_an_order_that_contradicts_the_authored_times_is_warned_about(rat):
    def swap(data):
        events = data["attack_patterns"][1]["events"]
        events[1]["time"], events[2]["time"] = 0.305, 0.301     # both tick 19 at 60 Hz; listed late-then-early
    report = validate(edit(rat, swap))
    finding, = report.select("WARNING", "attack", "event_order_differs_from_time")
    assert finding.path == "attack_patterns[1].events[2]" and finding.related == ("attack_patterns[1].events[1]",)
    assert not validate(rat).select(code="event_order_differs_from_time")
    assert not validate(edit(rat, swap), tick_rate=1000).select(code="event_order_differs_from_time")


@pytest.mark.parametrize("rate", RATES)
def test_the_pattern_end_is_the_last_tick_and_events_there_still_run(rate, rat):
    pattern = rat.data["attack_patterns"][0]
    rows = timeline(pattern, rate)
    assert rows[-1]["what"] == "pattern end" and rows[-1]["tick"] == tick_of(pattern["duration"], rate)
    assert max(row["tick"] for row in schedule(pattern, rate)) <= rows[-1]["tick"]
    at_end = edit(rat, lambda d: d["attack_patterns"][0]["events"].append({"type": "CompleteAttack", "time": 0.5}))
    assert "event_after_pattern_end" not in validate(at_end, tick_rate=rate).codes()
    after = edit(rat, lambda d: d["attack_patterns"][0]["events"].append({"type": "CompleteAttack", "time": 0.51}))
    assert "event_after_pattern_end" in validate(after, tick_rate=rate).codes()


@pytest.mark.parametrize("fps", [1, 5, 10, 12, 24, 60])
def test_clip_fps_changes_what_is_drawn_and_nothing_else(fps, beetle):
    changed = edit(beetle, lambda d: [clip.update(fps=fps) for clip in d["animations"]["clips"]])
    for rate in RATES:
        assert schedule(changed.data["attack_patterns"][0], rate) == schedule(beetle.data["attack_patterns"][0], rate)
        assert timeline(changed.data["attack_patterns"][0], rate) == timeline(beetle.data["attack_patterns"][0], rate)
    assert validate(changed).status("attack") == "PASS" and validate(changed).status("ai") == "PASS"
    attack = next(clip for clip in changed.data["animations"]["clips"] if clip["id"] == "attack")
    assert clip_seconds(attack) == pytest.approx(7 / fps) and frame_start_seconds(attack, 2) == pytest.approx(2 / fps)


def test_looping_and_one_shot_clips_at_their_ends():
    one_shot = {"fps": 10, "loop": False, "frames": [{"duration": 1}, {"duration": 2}, {"duration": 1}]}
    assert [frame_at(one_shot, t) for t in (-1, 0, 0.099, 0.1, 0.299, 0.3, 0.399, 0.4, 99)] == [
        0, 0, 0, 1, 1, 2, 2, 2, 2]
    looping = dict(one_shot, loop=True)
    assert [frame_at(looping, t) for t in (0.4, 0.45, 0.5, 0.8, 4.05)] == [0, 0, 1, 0, 0]
    assert frame_at({"fps": 10, "loop": True, "frames": []}, 3) == 0
    with pytest.raises(ValueError, match="fps"):
        clip_seconds({"fps": 0, "loop": False, "frames": [{"duration": 1}]})
    assert math.isclose(clip_seconds(one_shot), 0.4)


def test_validation_survives_documents_whose_clip_times_are_meaningless(beetle):
    broken = edit(beetle, lambda d: [clip.update(fps=0) for clip in d["animations"]["clips"]])
    report = validate(broken)                                   # must report, not crash
    assert len(report.select("FAIL", "animation", "out_of_range")) == 5
