"""Time, geometry and documentation contracts."""

import math
from pathlib import Path

import pytest

from conftest import PROJECT, load
from rtcmonster import reference
from rtcmonster.geometry import (actor_to_sprite, bottom_center_offset, mirror_shape, shape_bounds, slice_grid,
                                 sprite_to_actor, to_godot_shape)
from rtcmonster.schema import resolve
from rtcmonster.timing import (clip_seconds, frame_at, frame_start_seconds, quantize, tick_of, timeline,
                               window_ticks)


def clip(document, clip_id):
    return next(row for row in document.data["animations"]["clips"] if row["id"] == clip_id)


# ------------------------------------------------------------------------------------------------------- timing
@pytest.mark.parametrize("seconds, tick", [(0, 0), (-1, 0), (1 / 60, 1), (0.2, 12), (0.25, 15), (0.45, 27),
                                           (0.7, 42), (0.18, 11), (0.0001, 1), (0.1, 6), (0.3, 18)])
def test_seconds_map_to_the_first_tick_that_has_reached_them(seconds, tick):
    assert tick_of(seconds) == tick


def test_tick_mapping_is_not_disturbed_by_float_accumulation():
    # Subtracting 1/60 twelve times from 0.7 does not land exactly on 0.5; integer ticks do not care.
    remaining = 0.7
    for _ in range(12):
        remaining -= 1 / 60
    assert remaining != 0.5 and tick_of(0.7 - 0.5) == 12
    assert all(tick_of(n / 60) == n for n in range(0, 600))
    assert quantize(0.18) == pytest.approx(11 / 60) and quantize(0.2) == pytest.approx(0.2)


def test_windows_are_half_open_in_ticks_and_follow_the_tick_rate():
    assert window_ticks(0.15, 0.25) == 6 and window_ticks(0.2, 0.2) == 0
    assert window_ticks(0.201, 0.209) == 0 and window_ticks(0.201, 0.209, 240) == 2
    assert tick_of(0.2, 30) == 6 and tick_of(0.2, 120) == 24


def test_clip_time_follows_godot_sprite_frames(beetle, frog):
    attack = clip(beetle, "attack")
    assert clip_seconds(attack) == pytest.approx(0.7) and frame_start_seconds(attack, 2) == pytest.approx(0.2)
    assert clip_seconds(clip(beetle, "death")) == pytest.approx(5 / 12)
    assert clip_seconds(clip(frog, "jump_start")) == pytest.approx(2 / 12)
    assert [frame_at(attack, t) for t in (0, 0.09, 0.1, 0.25, 0.69, 5)] == [0, 0, 1, 2, 6, 6]
    idle = clip(beetle, "idle")
    assert [frame_at(idle, t) for t in (0, 0.2, 0.79, 0.8, 1.0)] == [0, 1, 3, 0, 1]  # loops
    weighted = {"fps": 10, "loop": False, "frames": [{"duration": 3}, {"duration": 1}]}
    assert clip_seconds(weighted) == pytest.approx(0.4) and frame_at(weighted, 0.29) == 0


def test_the_timeline_lists_authored_and_effective_times(rat):
    rows = timeline(rat.data["attack_patterns"][1])
    assert [row["what"] for row in rows][:3] == ["windup start", "LockFacing", "windup end"]
    assert all(row["effective_seconds"] == pytest.approx(row["tick"] / 60) for row in rows)
    assert rows[-1] == {"what": "pattern end", "seconds": 0.9, "tick": 54, "effective_seconds": pytest.approx(0.9)}


def test_stat_references_resolve_against_the_document(beetle):
    stats = beetle.data["stats"]
    assert resolve({"stat": "chase_range", "scale": 1.35, "offset": 0}, stats) == pytest.approx(324)
    assert resolve({"stat": "attack_range", "scale": 1, "offset": 12}, stats) == 58 and resolve(40, stats) == 40


# ----------------------------------------------------------------------------------------------------- geometry
def test_shapes_mirror_only_their_centre_x():
    box = {"type": "rectangle", "center": [24, -6], "size": [26, 18]}
    assert mirror_shape(box, 1) == box
    assert mirror_shape(box, -1) == {"type": "rectangle", "center": [-24, -6], "size": [26, 18]}
    assert shape_bounds(box) == (11, -15, 37, 3) and shape_bounds(mirror_shape(box, -1)) == (-37, -15, -11, 3)
    circle = {"type": "circle", "center": [16, -4], "radius": 8}
    assert shape_bounds(mirror_shape(circle, -1)) == (-24, -12, -8, 4)
    assert to_godot_shape(box, -1) == {"shape_class": "RectangleShape2D", "position": [-24, -6], "size": [26, 18]}
    assert to_godot_shape(circle) == {"shape_class": "CircleShape2D", "position": [16, -4], "radius": 8}


def test_sprite_and_actor_space_convert_both_ways(frog):
    presentation = frog.data["presentation"]            # visual_offset [4, -19], 64x64 frames
    size = (64, 64)
    assert sprite_to_actor((32, 32), size, presentation) == [4, -19]
    assert sprite_to_actor((32, 32), size, presentation, facing=-1) == [-4, -19]   # the offset mirrors too
    assert sprite_to_actor((0, 64), size, presentation) == [-28, 13]
    for facing in (1, -1):
        for point in ((0, 0), (10, 50), (64, 64)):
            back = actor_to_sprite(sprite_to_actor(point, size, presentation, facing), size, presentation, facing)
            assert back == pytest.approx(point)
    scaled = {**presentation, "visual_scale": [2, 0.5], "faces_right_by_default": False}
    assert sprite_to_actor((40, 32), size, scaled) == [-24, -9.5]
    assert actor_to_sprite([-24, -9.5], size, scaled) == pytest.approx([40, 32])


def test_visual_scale_never_reaches_collision(beetle):
    body = beetle.data["collision"]["body"]["shape"]
    assert to_godot_shape(body)["size"] == [34, 22]
    assert "visual_scale" not in str(beetle.data["collision"])


def test_bottom_centre_preset_reproduces_the_beetle_offset(beetle, frog):
    body = beetle.data["collision"]["body"]["shape"]
    assert bottom_center_offset((64, 48), (1, 1), body) == beetle.data["presentation"]["visual_offset"]
    # The frog's art leaves two empty rows under the feet and is nudged 4 px by hand.
    assert bottom_center_offset((64, 64), (1, 1), frog.data["collision"]["body"]["shape"], foot_margin=2) == [0, -19]


def test_grid_slicing_is_row_major_and_matches_the_shipped_strips(beetle):
    assert slice_grid("attack_strip", 64, 48, 7) == clip(beetle, "attack")["frames"]
    frames = slice_grid("sheet", 256, 256, 4, 2, count=6, origin=(50, 50), spacing=(10, 20))
    assert [frame["rect"] for frame in frames] == [
        [50, 50, 256, 256], [316, 50, 256, 256], [582, 50, 256, 256], [848, 50, 256, 256],
        [50, 326, 256, 256], [316, 326, 256, 256]]
    for arguments in ((0, 48, 7), (64, 48, 0), (64, 48, 2, 1, 3)):
        with pytest.raises(ValueError):
            slice_grid("sheet", *arguments)


def test_godot_shape_values_are_finite_numbers(rat):
    for row in rat.data["collision"]["hurtboxes"] + rat.data["collision"]["hitboxes"]:
        values = to_godot_shape(row["shape"], -1)
        flat = values["position"] + values.get("size", [values.get("radius", 0)])
        assert all(math.isfinite(value) for value in flat)


# -------------------------------------------------------------------------------------------------- documentation
@pytest.mark.parametrize("name", list(reference.SECTIONS))
def test_the_schema_document_embeds_the_generated_reference(name):
    text = (PROJECT / "docs/monster_editor_schema_v1.md").read_text(encoding="utf-8")
    assert reference.render(name) in text, (
        f"docs/monster_editor_schema_v1.md is out of date for '{name}': paste the output of "
        "`python -m rtcmonster.reference` (run in tools/python_monster_editor)")


def test_the_examples_are_the_ones_the_documents_describe():
    assert sorted(path.name for path in (Path(__file__).parents[1] / "examples").iterdir()) == [
        "frog.rtcmonster", "sewer_beetle.rtcmonster", "sewer_rat_prototype.rtcmonster"]
    assert load("frog").data["source_binding"]["passthrough"] == {"folded_states": ["prepare", "hop"]}
