"""MONSTER-STEP 3 editing logic: images, clips, roles, the bottom-centre preset, shapes and hurtbox overrides.

Everything here is the Qt-free layer. Each helper returns edits; the tests apply them to a document and
read the result back, so a helper that produced a structurally invalid edit fails here.
"""

import pytest

from conftest import PROJECT
from application import animation
from application.session import DocumentSession
from rtcmonster import DocumentError, validate
from rtcmonster.geometry import shape_bounds

BEETLE = "assets/characters/enemies/sewer_beetle"


def applied(document, edits):
    return document.apply(*edits)


def with_clip(rat, clip_id="walk", name="move", columns=6, **options):
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/{name}.png")
    document = applied(rat, edits)
    return applied(document, animation.clip_from_grid(document.data, image_id, clip_id, columns, **options)), image_id


# ---------------------------------------------------------------------------------------------------- images
def test_registering_an_image_records_its_measured_size_and_hash(rat):
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/idle.png")
    row = applied(rat, edits).data["assets"]["images"][0]
    assert image_id == "idle" and row["path"] == f"{BEETLE}/idle.png"
    assert (row["width"], row["height"]) == (256, 48) and len(row["sha256"]) == 64


def test_image_ids_are_unique_and_come_from_the_file_name(rat):
    document = applied(rat, animation.register_image(rat.data, PROJECT, f"{BEETLE}/idle.png")[1])
    with pytest.raises(DocumentError, match="already registered"):
        animation.register_image(document.data, PROJECT, f"{BEETLE}\\idle.png")
    assert animation.unique_id("idle", ["idle", "idle_2"]) == "idle_3"
    assert animation.id_from_path("art/Frog Leap-01.PNG") == "frog_leap_01"
    assert animation.id_from_path("art/01.png") == "image_01" and animation.id_from_path("art/한글.png") == "image"


@pytest.mark.parametrize("relative, error", [
    (f"{BEETLE}/absent.png", FileNotFoundError),
    ("../outside.png", DocumentError),
    ("project.godot", DocumentError),
])
def test_a_file_that_cannot_be_an_image_is_refused_and_adds_nothing(rat, relative, error):
    with pytest.raises(error):
        animation.register_image(rat.data, PROJECT, relative)


def test_refreshing_an_image_only_edits_what_changed(rat):
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/idle.png")
    document = applied(rat, edits)
    assert animation.refresh_image(document.data, PROJECT, image_id) == []
    stale = applied(document, [animation.set_value(("assets", "images", 0, "sha256"), "0" * 64)])
    refreshed = applied(stale, animation.refresh_image(stale.data, PROJECT, image_id))
    assert refreshed.data["assets"]["images"][0]["sha256"] == document.data["assets"]["images"][0]["sha256"]


def test_an_image_in_use_cannot_be_removed(rat):
    document, image_id = with_clip(rat)
    assert animation.image_users(document.data, image_id) == ["walk"]
    with pytest.raises(DocumentError, match="used by clip walk"):
        animation.remove_image(document, image_id)
    emptied = applied(document, animation.remove_clip(document, "walk"))
    assert applied(emptied, animation.remove_image(emptied, image_id)).data["assets"]["images"] == []


# ----------------------------------------------------------------------------------------------------- clips
def test_a_grid_clip_cuts_equal_row_major_frames(rat):
    document, image_id = with_clip(rat, columns=6, fps=12, loop=True)
    clip = document.data["animations"]["clips"][0]
    assert (clip["id"], clip["fps"], clip["loop"], len(clip["frames"])) == ("walk", 12, True, 6)
    assert [list(frame["rect"]) for frame in clip["frames"][:2]] == [[0, 0, 64, 48], [64, 0, 64, 48]]
    assert all(frame["image"] == image_id and frame["duration"] == 1 for frame in clip["frames"])
    assert animation.frame_size(document.data, clip, 3) == (64, 48)
    assert animation.frame_source(document.data, clip, 1) == (f"{BEETLE}/move.png", [64, 0, 64, 48])


def test_a_grid_that_does_not_divide_the_sheet_is_refused(rat):
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/move.png")
    document = applied(rat, edits)
    for columns, rows in ((5, 1), (6, 5), (0, 1)):
        with pytest.raises(DocumentError):
            animation.clip_from_grid(document.data, image_id, "walk", columns, rows)
    with pytest.raises(DocumentError, match="count"):
        animation.clip_from_grid(document.data, image_id, "walk", 6, 1, count=7)
    with pytest.raises(DocumentError, match="no image"):
        animation.clip_from_grid(document.data, "absent", "walk", 6)
    assert len(applied(document, animation.clip_from_grid(document.data, image_id, "walk", 6, count=4))
               .data["animations"]["clips"][0]["frames"]) == 4


def test_a_clip_from_whole_images_keeps_their_order(rat):
    document = rat
    ids = []
    for name in ("idle", "move"):
        image_id, edits = animation.register_image(document.data, PROJECT, f"{BEETLE}/{name}.png")
        document = applied(document, edits)
        ids.append(image_id)
    document = applied(document, animation.clip_from_images(document.data, "poses", list(reversed(ids))))
    clip = document.data["animations"]["clips"][0]
    assert [frame["image"] for frame in clip["frames"]] == ["move", "idle"] and clip["frames"][0]["rect"] is None
    assert animation.frame_size(document.data, clip, 0) == (384, 48)
    with pytest.raises(DocumentError, match="already exists"):
        animation.clip_from_images(document.data, "poses", ids)
    with pytest.raises(DocumentError, match="at least one"):
        animation.clip_from_images(document.data, "empty", [])


def test_removing_a_clip_removes_what_pointed_at_it(rat):
    document, _image = with_clip(rat)
    document = applied(document, animation.bind_role(document.data, "idle", "walk")
                       + animation.bind_role(document.data, "move", "walk"))
    document = applied(document, animation.create_override(document.data, "walk", 2))
    document = applied(document, animation.create_override(document.data, "walk"))
    assert animation.clip_roles(document.data, "walk") == ["idle", "move"]
    removed = applied(document, animation.remove_clip(document, "walk"))
    assert removed.data["animations"]["clips"] == [] and removed.data["collision"]["hurtbox_overrides"] == []
    assert set(removed.data["presentation"]["roles"].values()) == {""}


def test_removing_a_frame_keeps_overrides_on_their_frames(rat):
    document, _image = with_clip(rat)
    for frame in (1, 3, 5, None):
        document = applied(document, animation.create_override(document.data, "walk", frame))
    marked = document
    for index, row in enumerate(document.data["collision"]["hurtbox_overrides"]):
        if row["frame"] is not None:        # tag each override with the source rect of the frame it was made for
            rect = document.data["animations"]["clips"][0]["frames"][row["frame"]]["rect"]
            marked = applied(marked, [animation.set_value(
                ("collision", "hurtbox_overrides", index, "boxes", 0, "shape", "center"), [rect[0], 0])])
    after = applied(marked, animation.remove_frame(marked.data, "walk", 3))
    clip = after.data["animations"]["clips"][0]
    assert len(clip["frames"]) == 5
    frames = sorted((row["frame"] for row in after.data["collision"]["hurtbox_overrides"]), key=lambda value: -1 if value is None else value)
    assert frames == [None, 1, 4]
    for row in after.data["collision"]["hurtbox_overrides"]:
        if row["frame"] is not None:
            assert row["boxes"][0]["shape"]["center"][0] == clip["frames"][row["frame"]]["rect"][0]
    with pytest.raises(DocumentError, match="no frame"):
        animation.remove_frame(after.data, "walk", 9)


# ---------------------------------------------------------------------------------------------- presentation
def test_roles_bind_only_to_existing_clips(rat):
    document, _image = with_clip(rat)
    bound = applied(document, animation.bind_role(document.data, "move", "walk"))
    assert bound.data["presentation"]["roles"]["move"] == "walk"
    assert applied(bound, animation.bind_role(bound.data, "move", "")).data["presentation"]["roles"]["move"] == ""
    with pytest.raises(DocumentError):
        animation.bind_role(document.data, "move", "absent")
    with pytest.raises(DocumentError, match="unknown role"):
        animation.bind_role(document.data, "dance", "walk")


def test_the_bottom_centre_preset_puts_the_feet_on_the_body_bottom(rat):
    document, _image = with_clip(rat)
    document = applied(document, [animation.set_value(("presentation", "visual_scale"), [0.5, 0.5])])
    placed = applied(document, animation.bottom_center_edits(document.data, "walk", foot_margin=4))
    offset = list(placed.data["presentation"]["visual_offset"])
    body_bottom = shape_bounds(placed.data["collision"]["body"]["shape"])[3]
    # Frame bottom minus the empty rows, through the document's own transform, lands on the body's bottom edge.
    from rtcmonster.geometry import sprite_to_actor
    foot = sprite_to_actor([32, 48 - 4], (64, 48), placed.data["presentation"])
    assert offset[0] == 0 and foot[0] == 0 and foot[1] == pytest.approx(body_bottom)
    with pytest.raises(DocumentError):
        animation.bottom_center_edits(document.data, "absent")


# ---------------------------------------------------------------------------------------------------- shapes
def test_dragging_a_rectangle_edge_moves_only_that_edge():
    shape = {"type": "rectangle", "center": [0, 0], "size": [30, 18]}
    wider = animation.resized_shape(shape, "right", (25, 99))
    assert shape_bounds(wider) == (-15, -9, 25, 9)
    taller = animation.resized_shape(shape, "top", (99, -20))
    assert shape_bounds(taller) == (-15, -20, 15, 9)
    collapsed = animation.resized_shape(shape, "left", (400, 0))
    assert shape_bounds(collapsed) == (15 - animation.MINIMUM_EXTENT, -9, 15, 9)
    assert animation.resized_shape(shape, "bottom", (0, -400))["size"][1] == animation.MINIMUM_EXTENT
    with pytest.raises(DocumentError):
        animation.resized_shape(shape, "corner", (0, 0))


def test_a_circle_keeps_its_centre_and_takes_the_drag_distance_as_radius():
    circle = {"type": "circle", "center": [4, -2], "radius": 10}
    assert animation.resized_shape(circle, "right", (24, 50)) == {"type": "circle", "center": [4, -2], "radius": 20}
    assert animation.resized_shape(circle, "top", (99, -8))["radius"] == 6
    assert animation.resized_shape(circle, "left", (4, 0))["radius"] == animation.MINIMUM_EXTENT / 2
    assert animation.handle_points(circle)["left"] == (-6, -2)


def test_moving_converting_and_rounding_shapes():
    shape = {"type": "rectangle", "center": [1, 2], "size": [30, 18]}
    assert animation.moved_shape(shape, (2.5, -1))["center"] == [3.5, 1]
    circle = animation.convert_shape(shape, "circle")
    assert circle == {"type": "circle", "center": [1, 2], "radius": 15}
    assert animation.convert_shape(circle, "rectangle") == {"type": "rectangle", "center": [1, 2], "size": [30, 30]}
    assert animation.convert_shape(shape, "rectangle") == shape
    assert animation.rounded_shape({"type": "circle", "center": [1.004, 2.0], "radius": 3.14159}) == \
        {"type": "circle", "center": [1, 2], "radius": 3.14}
    for kind in animation.SHAPE_KINDS:
        assert animation.default_shape(kind)["type"] == kind
    with pytest.raises(DocumentError):
        animation.default_shape("capsule")


def test_boxes_are_added_edited_and_removed_through_slots(rat):
    existing = len(rat.data["collision"]["hitboxes"])
    box_id, edits = animation.add_box(rat.data, "hitbox", "circle")
    document = applied(rat, edits)
    slots = animation.shape_slots(document.data)
    assert [slot.kind for slot in slots] == ["body", "hurtbox", "hurtbox"] + ["hitbox"] * (existing + 1)
    assert slots[-1].label == box_id and box_id not in [box["id"] for box in rat.data["collision"]["hitboxes"]]
    moved = applied(document, animation.set_shape(slots[-1], animation.moved_shape(animation.shape_at(document.data, slots[-1]), (3.333, 0))))
    assert moved.data["collision"]["hitboxes"][-1]["shape"]["center"][0] == 3.33
    assert len(applied(moved, animation.remove_box(moved, slots[-1])).data["collision"]["hitboxes"]) == existing
    with pytest.raises(DocumentError, match="body"):
        animation.remove_box(moved, slots[0])
    hurt_id, edits = animation.add_box(document.data, "hurtbox")
    added = applied(document, edits).data["collision"]["hurtboxes"][-1]
    assert added["enabled"] is True and added["id"] == hurt_id
    with pytest.raises(DocumentError):
        animation.add_box(document.data, "body")


# ------------------------------------------------------------------------------------------------- overrides
def test_a_frame_override_wins_over_the_clip_override_and_the_default_set(rat):
    document, _image = with_clip(rat)
    default_ids = [box["id"] for box in animation.effective_hurtboxes(document.data, "walk", 0)]
    document = applied(document, animation.create_override(document.data, "walk"))
    document = applied(document, animation.create_override(document.data, "walk", 2))
    clip_slot = animation.shape_slots(document.data, "walk", 0)[1]
    frame_slot = animation.shape_slots(document.data, "walk", 2)[1]
    assert clip_slot.kind == frame_slot.kind == "override" and clip_slot != frame_slot
    document = applied(document, animation.set_shape(frame_slot, animation.default_shape("circle", (9, 9), 5)))
    assert animation.effective_hurtboxes(document.data, "walk", 2)[0]["shape"]["type"] == "circle"
    assert animation.effective_hurtboxes(document.data, "walk", 1)[0]["shape"]["type"] == "rectangle"
    assert [box["id"] for box in animation.effective_hurtboxes(document.data)] == default_ids
    assert document.data["collision"]["hurtboxes"][0]["shape"]["type"] == "rectangle"      # the default set is untouched
    back = applied(document, animation.remove_override(document.data, "walk", 2))
    assert animation.active_override(back.data, "walk", 2) == animation.override_index(back.data, "walk", None)
    with pytest.raises(DocumentError, match="already"):
        animation.create_override(document.data, "walk", 2)
    with pytest.raises(DocumentError, match="no frame"):
        animation.create_override(document.data, "walk", 99)
    with pytest.raises(DocumentError, match="no hurtbox set"):
        animation.remove_override(back.data, "walk", 2)


# -------------------------------------------------------------------------------------------- whole documents
def test_a_draft_built_with_these_helpers_passes_the_animation_rules(rat):
    session = DocumentSession(rat)
    data = lambda: session.document.data
    for name, clip_id, columns, loop in (("idle", "idle", 4, True), ("move", "move", 6, True), ("attack", "attack", 7, False),
                                         ("hurt", "hurt", 3, False), ("death", "death", 5, False)):
        image_id, edits = animation.register_image(data(), PROJECT, f"{BEETLE}/{name}.png", image_id=f"{name}_sheet")
        assert session.apply(*edits, label="image")
        assert session.apply(*animation.clip_from_grid(data(), image_id, clip_id, columns, loop=loop), label="clip")
        assert session.apply(*animation.bind_role(data(), clip_id, clip_id), label="role")
    assert session.apply(*animation.bottom_center_edits(data(), "idle"), label="anchor")
    report = validate(session.document, project=PROJECT)
    animation_codes = {finding.code for finding in report.findings
                       if finding.status == "FAIL" and finding.domain in ("assets", "animation")}
    assert animation_codes == set(), animation_codes
    while session.can_undo:
        session.undo()
    assert session.document.fingerprint == rat.fingerprint


def test_imported_legacy_sections_stay_read_only(beetle):
    session = DocumentSession(beetle)
    assert session.editability("animations") == "read_only" and session.editability("collision") == "read_only"
    with pytest.raises(DocumentError):
        session.apply(*animation.bind_role(beetle.data, "idle", ""))
