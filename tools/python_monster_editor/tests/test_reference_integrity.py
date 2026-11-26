"""Reference integrity of animation and collision edits (MONSTER-STEP 3 stabilization, FIX-01..04). No Qt.

A frame is followed by *identity*, never by its picture: every test frame gets a distinct ``duration`` as
a tag, because the same image and source rect may legitimately appear in several frames.
"""

import random

import pytest

from conftest import PROJECT
from application import animation, references
from application.references import ReferenceBlocked
from application.session import DocumentSession
from rtcmonster import DocumentError, FAIL, encode, move_item, read_document, set_value, validate, write_document

BEETLE = "assets/characters/enemies/sewer_beetle"
OVERRIDES = ("collision", "hurtbox_overrides")


def applied(document, edits):
    return document.apply(*edits)


def tagged_clip(rat, clip_id="walk", name="move", columns=6):
    """A grid clip whose frame ``i`` has duration ``i + 1`` (its tag)."""
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/{name}.png")
    document = applied(rat, edits)
    document = applied(document, animation.clip_from_grid(document.data, image_id, clip_id, columns))
    position = animation.clip_index(document.data, clip_id)
    return applied(document, [set_value(("animations", "clips", position, "frames", index, "duration"), index + 1)
                              for index in range(columns)])


def with_overrides(document, clip_id, frames):
    """Give frames their own hurtbox set, each marked with the tag of the frame it was made for."""
    for frame in frames:
        document = applied(document, animation.create_override(document.data, clip_id, frame))
        index = animation.override_index(document.data, clip_id, frame)
        mark = -1 if frame is None else tags(document, clip_id)[frame]
        document = applied(document, [set_value(OVERRIDES + (index, "boxes", 0, "shape", "center"), [mark, 0]),
                                      set_value(OVERRIDES + (index, "boxes", 0, "enabled"), frame != 2)])
    return document


def tags(document, clip_id):
    clip = document.data["animations"]["clips"][animation.clip_index(document.data, clip_id)]
    return [frame["duration"] for frame in clip["frames"]]


def override_marks(document, clip_id):
    """``{frame tag the override now sits on: the tag it was made for}`` - equal pairs mean nothing drifted."""
    order = tags(document, clip_id)
    return {(None if row["frame"] is None else order[row["frame"]]): row["boxes"][0]["shape"]["center"][0]
            for row in document.data["collision"]["hurtbox_overrides"] if row["clip"] == clip_id}


def consistent(document, clip_id):
    marks = override_marks(document, clip_id)
    return all(mark == (-1 if tag is None else tag) for tag, mark in marks.items())


# ------------------------------------------------------------------------------------------ the old defect
def test_reordering_only_the_frame_array_is_the_defect(rat):
    """What the workspace did before the fix: the override made for frame B ends up on frame C."""
    document = with_overrides(tagged_clip(rat), "walk", [1])
    position = animation.clip_index(document.data, "walk")
    broken = applied(document, [move_item(("animations", "clips", position, "frames", 1), 3)])
    assert tags(broken, "walk") == [1, 3, 4, 2, 5, 6]
    assert not consistent(broken, "walk")                        # override still says "frame 1", now another frame
    fixed = applied(document, animation.move_frame(document.data, "walk", 1, 3))
    assert tags(fixed, "walk") == [1, 3, 4, 2, 5, 6] and consistent(fixed, "walk")
    assert [row["frame"] for row in fixed.data["collision"]["hurtbox_overrides"]] == [3]


# ---------------------------------------------------------------------------------------------- move_frame
def test_the_mapping_of_the_specification_example():
    assert references.move_mapping(4, 1, 3) == {0: 0, 1: 3, 2: 1, 3: 2}
    assert references.move_mapping(4, 3, 0) == {0: 1, 1: 2, 2: 3, 3: 0}
    assert references.move_mapping(4, 2, 2) == {0: 0, 1: 1, 2: 2, 3: 3}
    assert references.remove_mapping(4, 1) == {0: 0, 1: None, 2: 1, 3: 2}
    assert references.insert_mapping(3, 1) == {0: 0, 1: 2, 2: 3}


@pytest.mark.parametrize("source, target", [(2, 1), (2, 3), (0, 5), (5, 0), (1, 4), (4, 1), (0, 1), (5, 4)])
def test_every_override_follows_its_frame(rat, source, target):
    document = with_overrides(tagged_clip(rat), "walk", [0, 1, 2, 4, 5, None])
    before = document.data["collision"]["hurtbox_overrides"]
    moved = applied(document, animation.move_frame(document.data, "walk", source, target))
    order = list(range(1, 7))
    order.insert(target, order.pop(source))
    assert tags(moved, "walk") == order and consistent(moved, "walk")
    after = moved.data["collision"]["hurtbox_overrides"]
    assert len(after) == len(before) and len({row["frame"] for row in after}) == len(after)   # none lost or doubled
    assert [row["boxes"] for row in after] == [row["boxes"] for row in before]      # shapes and enabled untouched
    assert [row["frame"] for row in after if row["frame"] is None] == [None]        # the whole-clip set stays
    assert not validate(moved).select(FAIL, "references")


def test_other_clips_and_time_based_attack_events_are_left_alone(frog):
    """The frog has attack patterns with events in seconds, and several clips."""
    clips = [clip["id"] for clip in frog.data["animations"]["clips"] if len(clip["frames"]) >= 3]
    first, second = clips[0], clips[1]
    document = frog
    for clip_id in (first, second):
        document = applied(document, animation.create_override(document.data, clip_id, 1))
    moved = applied(document, animation.move_frame(document.data, first, 1, 2))
    rows = {row["clip"]: row["frame"] for row in moved.data["collision"]["hurtbox_overrides"]}
    assert rows == {first: 2, second: 1}
    assert moved.data["attack_patterns"] == document.data["attack_patterns"]
    assert moved.data["behavior"] == document.data["behavior"]


def test_the_attack_hit_frame_follows_only_the_attack_clip(rat):
    document = tagged_clip(tagged_clip(rat, "bite", "attack", 7), "walk", "move", 6)
    document = applied(document, animation.bind_role(document.data, "attack", "bite")
                       + [set_value(("presentation", "attack_hit_frame"), 2)])
    assert [usage.what for usage in references.frame_usages(document.data, "bite")] == ["attack_hit_frame"]
    assert references.frame_usages(document.data, "walk") == []
    for source, target, expected in ((2, 4, 4), (0, 4, 1), (4, 0, 3), (3, 4, 2), (1, 2, 1)):
        moved = applied(document, animation.move_frame(document.data, "bite", source, target))
        assert moved.data["presentation"]["attack_hit_frame"] == expected, (source, target)
        assert tags(moved, "bite")[expected] == 3                      # still the frame that showed the strike
    other = applied(document, animation.move_frame(document.data, "walk", 2, 0))
    assert other.data["presentation"]["attack_hit_frame"] == 2
    # A hit frame beyond the clip is stale data, not a reference: it is not "followed" anywhere.
    stale = applied(document, [set_value(("presentation", "attack_hit_frame"), 40)])
    assert applied(stale, animation.move_frame(stale.data, "bite", 0, 4)).data["presentation"]["attack_hit_frame"] == 40


def test_frames_that_look_the_same_are_still_different_frames(rat):
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/idle.png")
    document = applied(rat, edits)
    document = applied(document, animation.clip_from_images(document.data, "hold", [image_id] * 4))
    assert len({(frame["image"], frame["rect"]) for frame in document.data["animations"]["clips"][0]["frames"]}) == 1
    document = applied(document, [set_value(("animations", "clips", 0, "frames", index, "duration"), index + 1)
                                  for index in range(4)])
    document = with_overrides(document, "hold", [1, 2])
    moved = applied(document, animation.move_frame(document.data, "hold", 1, 3))
    assert tags(moved, "hold") == [1, 3, 4, 2] and consistent(moved, "hold")


def test_bad_indexes_are_refused_and_a_move_to_the_same_place_is_no_edit(rat):
    document = with_overrides(tagged_clip(rat), "walk", [1])
    assert animation.move_frame(document.data, "walk", 3, 3) == []
    for source, target in ((-1, 2), (6, 0), (0, 6), (0, -1), (99, 99)):
        with pytest.raises(DocumentError):
            animation.move_frame(document.data, "walk", source, target)
    with pytest.raises(DocumentError):
        animation.move_frame(document.data, "absent", 0, 1)


def test_a_move_is_one_undo_step_and_survives_a_save(rat, tmp_path):
    session = DocumentSession(with_overrides(tagged_clip(rat), "walk", [1, 4]))
    start = session.document
    assert session.apply(*animation.move_frame(session.document.data, "walk", 1, 5), label="move")
    assert len(session.history) == 2 and consistent(session.document, "walk")
    moved = session.document
    session.undo()
    assert session.document == start and session.document.fingerprint == start.fingerprint
    session.redo()
    assert session.document == moved
    assert not session.apply(*animation.move_frame(session.document.data, "walk", 2, 2), label="nothing")
    assert len(session.history) == 2
    path = tmp_path / "moved.rtcmonster"
    write_document(path, moved)
    reopened = read_document(path)[0]
    assert reopened == moved and consistent(reopened, "walk") and encode(reopened) == path.read_bytes()


def test_a_failed_move_changes_nothing(rat):
    session = DocumentSession(with_overrides(tagged_clip(rat), "walk", [1]))
    before, history = session.document, len(session.history)
    edits = animation.move_frame(session.document.data, "walk", 1, 3) + [set_value(("no", "such", "field"), 1)]
    with pytest.raises(DocumentError):
        session.apply(*edits, label="broken")
    assert session.document is before and len(session.history) == history


def test_random_sequences_keep_every_reference_and_undo_restores_the_original(rat):
    generator = random.Random(20261127)
    for _round in range(25):
        session = DocumentSession(with_overrides(tagged_clip(rat), "walk", generator.sample(range(6), 3) + [None]))
        session.apply(*animation.bind_role(session.document.data, "attack", "walk"),
                      set_value(("presentation", "attack_hit_frame"), generator.randrange(6)), label="bind")
        original = session.document
        hit_tag = tags(original, "walk")[original.data["presentation"]["attack_hit_frame"]]
        steps = 0
        for _step in range(12):
            count = len(tags(session.document, "walk"))
            choice = generator.random()
            data = session.document.data
            if choice < 0.6:
                edits = animation.move_frame(data, "walk", generator.randrange(count), generator.randrange(count))
            elif choice < 0.8:
                edits = animation.duplicate_frame(data, "walk", generator.randrange(count))
            else:
                frame = generator.randrange(count)
                impact = animation.frame_removal_impact(data, "walk", frame)
                if impact["last"] or impact["hit_frame"]:
                    continue
                edits = animation.remove_frame(data, "walk", frame)
            if edits and session.apply(*edits, label="step"):
                steps += 1
            document = session.document
            assert consistent(document, "walk")
            assert tags(document, "walk")[document.data["presentation"]["attack_hit_frame"]] == hit_tag
            assert not validate(document).select(FAIL, "references")
        for _undo in range(steps):
            session.undo()
        assert session.document == original


# ------------------------------------------------------------------------------- remove / insert / duplicate
def test_removing_a_frame_reports_what_goes_with_it(rat):
    document = with_overrides(tagged_clip(rat), "walk", [1, 3, 5, None])
    assert animation.frame_removal_impact(document.data, "walk", 3) == {"override": True, "hit_frame": False, "last": False}
    assert animation.frame_removal_impact(document.data, "walk", 2) == {"override": False, "hit_frame": False, "last": False}
    after = applied(document, animation.remove_frame(document.data, "walk", 3))
    assert tags(after, "walk") == [1, 2, 3, 5, 6] and consistent(after, "walk")
    assert sorted(override_marks(after, "walk"), key=lambda tag: -1 if tag is None else tag) == [None, 2, 6]


def test_the_frame_that_shows_the_strike_is_not_reassigned_silently(rat):
    document = tagged_clip(rat, "bite", "attack", 7)
    document = applied(document, animation.bind_role(document.data, "attack", "bite")
                       + [set_value(("presentation", "attack_hit_frame"), 2)])
    assert animation.frame_removal_impact(document.data, "bite", 2)["hit_frame"]
    with pytest.raises(ReferenceBlocked) as blocked:
        animation.remove_frame(document.data, "bite", 2)
    assert [usage.where for usage in blocked.value.usages] == ["presentation.attack_hit_frame"]
    with pytest.raises(DocumentError, match="no frame 6"):
        animation.remove_frame(document.data, "bite", 2, hit_frame=6)
    chosen = applied(document, animation.remove_frame(document.data, "bite", 2, hit_frame=3))
    assert chosen.data["presentation"]["attack_hit_frame"] == 3 and tags(chosen, "bite") == [1, 2, 4, 5, 6, 7]
    # Removing an earlier or later frame is arithmetic, not a decision: the hit frame follows.
    assert applied(document, animation.remove_frame(document.data, "bite", 0)).data["presentation"]["attack_hit_frame"] == 1
    assert applied(document, animation.remove_frame(document.data, "bite", 4)).data["presentation"]["attack_hit_frame"] == 2


def test_the_last_frame_is_not_removed(rat):
    image_id, edits = animation.register_image(rat.data, PROJECT, f"{BEETLE}/idle.png")
    document = applied(rat, edits)
    document = applied(document, animation.clip_from_images(document.data, "still", [image_id]))
    assert animation.frame_removal_impact(document.data, "still", 0)["last"]
    with pytest.raises(DocumentError, match="remove the clip instead"):
        animation.remove_frame(document.data, "still", 0)


def test_inserting_and_duplicating_shift_later_indexes(rat):
    document = with_overrides(tagged_clip(rat), "walk", [0, 2, 5])
    document = applied(document, animation.bind_role(document.data, "attack", "walk")
                       + [set_value(("presentation", "attack_hit_frame"), 3)])
    copied = applied(document, animation.duplicate_frame(document.data, "walk", 2))
    assert tags(copied, "walk") == [1, 2, 3, 3, 4, 5, 6]
    assert sorted(row["frame"] for row in copied.data["collision"]["hurtbox_overrides"]) == [0, 2, 6]
    assert copied.data["presentation"]["attack_hit_frame"] == 4
    assert animation.override_index(copied.data, "walk", 3) is None           # the copy has no set of its own
    row = {"image": document.data["assets"]["images"][0]["id"], "rect": [0, 0, 64, 48], "duration": 9, "offset": [0, 0]}
    front = applied(document, animation.insert_frame(document.data, "walk", 0, row))
    assert tags(front, "walk")[0] == 9 and consistent(front, "walk")
    assert front.data["presentation"]["attack_hit_frame"] == 4
    end = applied(document, animation.insert_frame(document.data, "walk", 6, row))
    assert end.data["collision"]["hurtbox_overrides"] == document.data["collision"]["hurtbox_overrides"]
    with pytest.raises(DocumentError):
        animation.insert_frame(document.data, "walk", 8, row)
    with pytest.raises(DocumentError, match="no image"):
        animation.insert_frame(document.data, "walk", 0, {**row, "image": "absent"})


# ---------------------------------------------------------------------------------------------------- clips
def test_incoming_references_come_from_the_schema(frog, beetle):
    for document in (frog, beetle):
        for clip in document.data["animations"]["clips"]:
            usages = references.incoming(document, "animation", clip["id"])
            for usage in usages:
                value = document.data
                for key in usage.path:
                    value = value[key]
                assert value == clip["id"]
        for box in document.data["collision"]["hitboxes"]:
            assert all(usage.section == "attack_patterns" for usage in references.incoming(document, "hitbox", box["id"]))
    attack = frog.data["presentation"]["roles"]["attack"]
    sections = {usage.section for usage in references.incoming(frog, "animation", attack)}
    assert "presentation" in sections
    with pytest.raises(DocumentError, match="unknown reference kind"):
        references.incoming(frog, "sound", "x")


def gameplay_clip(document):
    """A clip named by an attack pattern, with the pattern's index."""
    for index, pattern in enumerate(document.data["attack_patterns"]):
        if pattern["clip"]:
            return pattern["clip"], index
    raise AssertionError("the example has no pattern with a clip")


def test_a_clip_without_gameplay_references_is_removed_with_its_presentation(rat):
    document = with_overrides(tagged_clip(rat), "walk", [2, None])
    document = applied(document, animation.bind_role(document.data, "idle", "walk")
                       + animation.bind_role(document.data, "move", "walk"))
    usages = animation.clip_usages(document, "walk")
    assert {usage.section for usage in usages} == {"presentation", "collision"} and all(usage.soft for usage in usages)
    assert len(usages) == 4
    removed = applied(document, animation.remove_clip(document, "walk"))
    assert removed.data["animations"]["clips"] == [] and removed.data["collision"]["hurtbox_overrides"] == []
    assert set(removed.data["presentation"]["roles"].values()) == {""}


def test_a_clip_used_by_an_attack_pattern_is_not_removed_behind_its_back(frog):
    clip_id, index = gameplay_clip(frog)
    with pytest.raises(ReferenceBlocked) as blocked:
        animation.remove_clip(frog, clip_id)
    assert f"attack_patterns[{index}].clip" in [usage.where for usage in blocked.value.usages]
    assert all(not usage.soft for usage in blocked.value.usages)
    other = next(clip["id"] for clip in frog.data["animations"]["clips"] if clip["id"] != clip_id)
    replaced = applied(frog, animation.remove_clip(frog, clip_id, replace_with=other))
    assert replaced.data["attack_patterns"][index]["clip"] == other
    assert len(replaced.data["attack_patterns"]) == len(frog.data["attack_patterns"])        # no pattern deleted
    assert replaced.data["behavior"] == frog.data["behavior"]
    assert clip_id not in [clip["id"] for clip in replaced.data["animations"]["clips"]]
    assert not validate(replaced).select(FAIL, "references")
    for wrong in ("absent", clip_id):
        with pytest.raises(DocumentError):
            animation.remove_clip(frog, clip_id, replace_with=wrong)


def test_a_clip_named_by_a_behaviour_state_or_an_event_is_protected_too(rat):
    document = tagged_clip(rat)
    state = next(index for index, row in enumerate(document.data["behavior"]["states"]))
    document = applied(document, [set_value(("behavior", "states", state, "animation", "clip"), "walk")])
    with pytest.raises(ReferenceBlocked) as blocked:
        animation.remove_clip(document, "walk")
    assert [usage.where for usage in blocked.value.usages] == [f"behavior.states[{state}].animation.clip"]


def test_renaming_a_clip_takes_every_reference_along(frog):
    clip_id, index = gameplay_clip(frog)
    document = applied(frog, animation.create_override(frog.data, clip_id, 0))
    before = len(animation.clip_usages(document, clip_id))
    renamed = applied(document, animation.rename_clip(document, clip_id, "renamed_clip"))
    assert renamed.data["attack_patterns"][index]["clip"] == "renamed_clip"
    assert len(animation.clip_usages(renamed, "renamed_clip")) == before
    assert not validate(renamed).select(FAIL, "references")
    assert animation.rename_clip(document, clip_id, clip_id) == []
    taken = next(clip["id"] for clip in frog.data["animations"]["clips"] if clip["id"] != clip_id)
    for new, message in ((taken, "already exists"), ("Not Valid", "not a valid identifier")):
        with pytest.raises(DocumentError, match=message):
            applied(document, animation.rename_clip(document, clip_id, new))
    with pytest.raises(DocumentError, match="does not exist"):
        animation.rename_clip(document, "absent", "other")
    with pytest.raises(DocumentError, match="animations is read_only"):       # an imported monster's clips are the game's
        DocumentSession(document).apply(*animation.rename_clip(document, clip_id, "renamed_clip"), label="rename")
    free = document.replace(("source_binding",), None)
    session = DocumentSession(free)
    assert session.apply(*animation.rename_clip(free, clip_id, "renamed_clip"), label="rename")
    session.undo()
    assert session.document == free


def test_a_session_lets_reference_fields_follow_but_nothing_else_in_sections_without_an_editor(frog):
    free = frog.replace(("source_binding",), None)
    clip_id, index = gameplay_clip(free)
    other = next(clip["id"] for clip in free.data["animations"]["clips"] if clip["id"] != clip_id)
    session = DocumentSession(free)
    assert session.apply(*animation.remove_clip(free, clip_id, replace_with=other), label="replace")
    assert session.document.data["attack_patterns"][index]["clip"] == other
    for edit in (set_value(("attack_patterns", index, "duration"), 9),               # not a reference
                 set_value(("behavior", "initial_state"), "attack"),                  # a reference to a state
                 set_value(("attack_patterns", index, "id"), "other")):
        with pytest.raises(DocumentError, match="read_only"):
            session.apply(edit, label="no")
    bound = DocumentSession(frog)                                                    # the imported original
    with pytest.raises(DocumentError, match="read_only"):
        bound.apply(set_value(("attack_patterns", index, "clip"), other), label="no")


# --------------------------------------------------------------------------------------------------- images
def test_an_image_in_use_is_protected_and_can_be_replaced_by_one_that_fits(rat, tmp_path):
    document = tagged_clip(rat)
    image_id = document.data["assets"]["images"][0]["id"]
    with pytest.raises(ReferenceBlocked, match="used by clip walk") as blocked:
        animation.remove_image(document, image_id)
    assert len(blocked.value.usages) == 6
    same, edits = animation.register_image(document.data, PROJECT, f"{BEETLE}/attack.png")
    document = applied(document, edits)
    replacement = document.data["assets"]["images"][animation.image_index(document.data, same)]
    original = document.data["assets"]["images"][animation.image_index(document.data, image_id)]
    if (replacement["width"], replacement["height"]) >= (original["width"], original["height"]):
        swapped = applied(document, animation.remove_image(document, image_id, replace_with=same))
        clip = swapped.data["animations"]["clips"][0]
        assert len(clip["frames"]) == 6 and {frame["image"] for frame in clip["frames"]} == {same}
        assert tags(swapped, "walk") == [1, 2, 3, 4, 5, 6]                       # no frame was dropped
    else:
        with pytest.raises(DocumentError, match="too small"):
            animation.remove_image(document, image_id, replace_with=same)
    small, edits = animation.register_image(document.data, PROJECT, f"{BEETLE}/idle.png")
    document = applied(document, edits)
    idle = document.data["assets"]["images"][animation.image_index(document.data, small)]
    if idle["width"] < original["width"]:
        with pytest.raises(DocumentError, match="too small"):
            animation.remove_image(document, image_id, replace_with=small)
    with pytest.raises(DocumentError):
        animation.remove_image(document, image_id, replace_with="absent")


def test_refreshing_an_image_that_shrank_refuses_instead_of_inventing_rects(rat, tmp_path):
    import shutil
    project = tmp_path / "project"
    (project / "art").mkdir(parents=True)
    shutil.copy(PROJECT / BEETLE / "move.png", project / "art/sheet.png")
    image_id, edits = animation.register_image(rat.data, project, "art/sheet.png")
    document = applied(rat, edits)
    document = applied(document, animation.clip_from_grid(document.data, image_id, "walk", 6))
    whole = applied(document, animation.clip_from_images(document.data, "poster", [image_id]))
    assert animation.refresh_image(whole.data, project, image_id) == []
    shutil.copy(PROJECT / BEETLE / "idle.png", project / "art/sheet.png")           # a smaller picture, same path
    width = animation.inspect_image(project, "art/sheet.png")[0]
    assert width < document.data["assets"]["images"][0]["width"]
    with pytest.raises(DocumentError, match="no longer fit") as refused:
        animation.refresh_image(whole.data, project, image_id)
    assert "walk[" in str(refused.value)
    assert whole.data["animations"]["clips"][0]["frames"][5]["rect"] == [320, 0, 64, 48]     # nothing was shrunk


# -------------------------------------------------------------------------------------------------- hitboxes
def armed_hitbox(document):
    for box in document.data["collision"]["hitboxes"]:
        usages = animation.hitbox_usages(document, box["id"])
        if usages:
            return box["id"], usages
    raise AssertionError("the example arms no hitbox")


def hitbox_slot(document, name):
    return next(slot for slot in animation.shape_slots(document.data) if slot.kind == "hitbox" and slot.label == name)


def test_a_hitbox_an_event_arms_is_not_removed_behind_its_back(frog):
    name, usages = armed_hitbox(frog)
    slot = hitbox_slot(frog, name)
    with pytest.raises(ReferenceBlocked) as blocked:
        animation.remove_box(frog, slot)
    assert len(blocked.value.usages) == len(usages) and all(".events[" in usage.where for usage in usages)
    spare, edits = animation.add_box(frog.data, "hitbox")
    document = applied(frog, edits)
    replaced = applied(document, animation.remove_box(document, hitbox_slot(document, name), replace_with=spare))
    assert [box["id"] for box in replaced.data["collision"]["hitboxes"]] == [spare]
    assert animation.hitbox_usages(replaced, spare) and not validate(replaced).select(FAIL, "references")
    assert len(replaced.data["attack_patterns"]) == len(frog.data["attack_patterns"])
    unused = applied(document, animation.remove_box(document, hitbox_slot(document, spare)))
    assert [box["id"] for box in unused.data["collision"]["hitboxes"]] == [name]
    with pytest.raises(DocumentError):
        animation.remove_box(document, hitbox_slot(document, name), replace_with="absent")


def test_renaming_boxes(frog):
    name, usages = armed_hitbox(frog)
    renamed = applied(frog, animation.rename_box(frog, hitbox_slot(frog, name), "jaw"))
    assert len(animation.hitbox_usages(renamed, "jaw")) == len(usages) and not validate(renamed).select(FAIL, "references")
    document = applied(frog, animation.create_override(frog.data, frog.data["animations"]["clips"][0]["id"], 0))
    default = next(slot for slot in animation.shape_slots(document.data) if slot.kind == "hurtbox")
    other = applied(document, animation.rename_box(document, default, "torso"))
    assert other.data["collision"]["hurtboxes"][0]["id"] == "torso"
    # An override is its own complete set, not a view of the default one: its copy keeps its name.
    assert other.data["collision"]["hurtbox_overrides"] == document.data["collision"]["hurtbox_overrides"]
    second, edits = animation.add_box(document.data, "hurtbox")
    two = applied(document, edits)
    with pytest.raises(DocumentError, match="already exists"):
        animation.rename_box(two, next(slot for slot in animation.shape_slots(two.data) if slot.kind == "hurtbox"), second)
    with pytest.raises(DocumentError, match="no ID"):
        animation.rename_box(frog, animation.shape_slots(frog.data)[0], "x")


def test_removing_a_default_hurtbox_leaves_overrides_alone(rat):
    document = with_overrides(tagged_clip(rat), "walk", [1])
    slot = next(slot for slot in animation.shape_slots(document.data) if slot.kind == "hurtbox")
    removed = applied(document, animation.remove_box(document, slot))
    assert len(removed.data["collision"]["hurtboxes"]) == len(document.data["collision"]["hurtboxes"]) - 1
    assert removed.data["collision"]["hurtbox_overrides"] == document.data["collision"]["hurtbox_overrides"]
    with pytest.raises(DocumentError, match="cannot be removed"):
        animation.remove_box(document, animation.shape_slots(document.data)[0])
