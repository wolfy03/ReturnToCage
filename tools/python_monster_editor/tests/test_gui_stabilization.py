"""MONSTER-STEP 3 stabilization on the real window: reference-safe frame and clip editing, drag sessions,
playback and geometry. Tests named ``test_input_...`` send mouse and key events with ``QTest``.
"""

import math

import pytest

pytest.importorskip("PySide6")

from PySide6.QtCore import QPoint, QPointF, Qt  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402

from conftest import PROJECT, load  # noqa: E402
from application import animation as logic  # noqa: E402
from application.session import DocumentSession  # noqa: E402
from application.settings import Settings  # noqa: E402
from gui import dialogs, strings  # noqa: E402
from gui.main_window import MainWindow  # noqa: E402
from gui.preview_canvas import PreviewCanvas, usable_shape  # noqa: E402
from gui.testing import ScriptedPrompts  # noqa: E402
from rtcmonster import FAIL, read_document, set_value, validate, write_document  # noqa: E402
from rtcmonster.geometry import shape_bounds  # noqa: E402

BEETLE = "assets/characters/enemies/sewer_beetle"


@pytest.fixture
def window(app, tmp_path):
    prompts = ScriptedPrompts()
    view = MainWindow(Settings(tmp_path / "settings.json"), prompts)
    view.apply_project_settings({"project_root": str(PROJECT), "godot_path": "", "drafts_folder": str(tmp_path)})
    view.resize(1280, 800)
    view.show()
    QTest.qWaitForWindowExposed(view)
    view.set_session(DocumentSession(load("sewer_rat_prototype")))
    view.workspaces.setCurrentWidget(view.animation)
    app.processEvents()
    yield view
    if view.session is not None and view.session.dirty:
        prompts.expect("unsaved_changes", dialogs.DISCARD)
    view.close()
    view.deleteLater()
    app.processEvents()


def data(window):
    return window.session.document.data


def grid_clip(window, name, clip_id, columns):
    panel = window.animation
    panel.image_path.setText(f"{BEETLE}/{name}.png")
    QTest.mouseClick(panel.register_button, Qt.MouseButton.LeftButton)
    image_id = data(window)["assets"]["images"][-1]["id"]
    for row in range(panel.image_list.count()):
        item = panel.image_list.item(row)
        item.setSelected(item.data(Qt.ItemDataRole.UserRole) == image_id)
    panel.clip_id.setText(clip_id)
    panel.columns.setValue(columns)
    QTest.mouseClick(panel.grid_button, Qt.MouseButton.LeftButton)
    position = logic.clip_index(data(window), clip_id)
    window.apply_edits([set_value(("animations", "clips", position, "frames", index, "duration"), index + 1)
                        for index in range(columns)], "tags")
    return image_id


def tags(window, clip_id):
    clip = data(window)["animations"]["clips"][logic.clip_index(data(window), clip_id)]
    return [frame["duration"] for frame in clip["frames"]]


def override_frames(window, clip_id):
    return sorted(row["frame"] for row in data(window)["collision"]["hurtbox_overrides"]
                  if row["clip"] == clip_id and row["frame"] is not None)


def click(button):
    QTest.mouseClick(button, Qt.MouseButton.LeftButton)


def click_box(box):
    QTest.mouseClick(box, Qt.MouseButton.LeftButton, pos=QPoint(8, box.height() // 2))


# ------------------------------------------------------------------------------------- FIX-01: frame order
def test_input_moving_a_frame_takes_its_hurtbox_set_and_the_hit_frame_along(window, tmp_path):
    panel = window.animation
    grid_clip(window, "attack", "bite", 7)
    combo = panel.roles["attack"]
    combo.setCurrentIndex(combo.findData("bite"))
    combo.activated.emit(combo.currentIndex())
    panel.hit_frame.setValue(1)
    panel.hit_frame.editingFinished.emit()
    assert data(window)["presentation"]["attack_hit_frame"] == 1
    panel.strip.setCurrentRow(1)
    click(panel.override_frame)                                  # a hurtbox set made for frame 1 (tag 2)
    assert override_frames(window, "bite") == [1]
    history = len(window.session.history)

    click(panel.frame_right)
    assert tags(window, "bite") == [1, 3, 2, 4, 5, 6, 7]
    assert override_frames(window, "bite") == [2] and data(window)["presentation"]["attack_hit_frame"] == 2
    assert panel.current_frame() == 2 and panel.strip.currentRow() == 2          # the moved frame stays selected
    assert strings.ANIMATION["override_frame_state"].format(frame=2) == panel.override_label.text()
    assert len(window.session.history) == history + 1                             # one undo step for all of it
    click(panel.frame_right)
    click(panel.frame_right)
    assert tags(window, "bite") == [1, 3, 4, 5, 2, 6, 7] and override_frames(window, "bite") == [4]
    assert data(window)["presentation"]["attack_hit_frame"] == 4 and panel.current_frame() == 4
    assert not validate(window.session.document).select(FAIL, "references")

    path = tmp_path / "moved.rtcmonster"
    write_document(path, window.session.document)
    assert read_document(path)[0] == window.session.document

    for expected_tags, expected_override, expected_hit in (([1, 3, 4, 2, 5, 6, 7], [3], 3), ([1, 3, 2, 4, 5, 6, 7], [2], 2),
                                                           ([1, 2, 3, 4, 5, 6, 7], [1], 1)):
        window.undo()
        assert (tags(window, "bite"), override_frames(window, "bite"), data(window)["presentation"]["attack_hit_frame"]) \
            == (expected_tags, expected_override, expected_hit)
    window.redo()
    assert tags(window, "bite") == [1, 3, 2, 4, 5, 6, 7] and override_frames(window, "bite") == [2]


def test_input_a_move_at_the_edge_is_nothing_and_a_refused_move_keeps_the_selection(window, monkeypatch):
    panel = window.animation
    grid_clip(window, "move", "walk", 6)
    panel.strip.setCurrentRow(0)
    history, fingerprint = len(window.session.history), window.session.document.fingerprint
    click(panel.frame_left)
    assert panel.current_frame() == 0 and len(window.session.history) == history
    panel.strip.setCurrentRow(2)
    monkeypatch.setattr(logic, "move_frame", lambda *args: [set_value(("no", "such", "field"), 1)])
    click(panel.frame_right)                                     # the document refuses the edit
    assert panel.current_frame() == 2 and panel.strip.currentRow() == 2
    assert window.session.document.fingerprint == fingerprint and len(window.session.history) == history
    assert "적용하지 않았습니다" in window._last_message


def test_input_duplicating_a_frame_selects_the_copy(window):
    panel = window.animation
    grid_clip(window, "move", "walk", 6)
    panel.strip.setCurrentRow(2)
    click(panel.override_frame)
    panel.strip.setCurrentRow(1)
    click(panel.duplicate_frame_button)
    assert tags(window, "walk") == [1, 2, 2, 3, 4, 5, 6] and panel.current_frame() == 2
    assert override_frames(window, "walk") == [3]                 # still on the frame tagged 3


# ----------------------------------------------------------------------------------- FIX-02: frame removal
def test_input_removing_a_frame_asks_about_what_goes_with_it(window):
    panel = window.animation
    grid_clip(window, "attack", "bite", 7)
    combo = panel.roles["attack"]
    combo.setCurrentIndex(combo.findData("bite"))
    combo.activated.emit(combo.currentIndex())
    panel.hit_frame.setValue(3)
    panel.hit_frame.editingFinished.emit()
    panel.strip.setCurrentRow(5)
    click(panel.override_frame)

    window.prompts.expect("confirm", False)
    click(panel.remove_frame_button)                             # frame 5 has its own hurtbox set
    assert "전용 Hurtbox" in window.prompts.asked("confirm")[-1][1]
    assert len(tags(window, "bite")) == 7 and override_frames(window, "bite") == [5]
    window.prompts.expect("confirm", True)
    click(panel.remove_frame_button)
    assert tags(window, "bite") == [1, 2, 3, 4, 5, 7] and override_frames(window, "bite") == []

    panel.strip.setCurrentRow(3)                                 # the frame that shows the strike
    window.prompts.expect("choose", None)
    click(panel.remove_frame_button)
    title, text, options = window.prompts.asked("choose")[-1]
    assert "타격 frame" in text and options == ["frame 0", "frame 1", "frame 2", "frame 4", "frame 5"]
    assert len(tags(window, "bite")) == 6 and data(window)["presentation"]["attack_hit_frame"] == 3
    assert "타격 frame" in panel.notice.text()
    window.prompts.expect("choose", "frame 4")
    click(panel.remove_frame_button)
    assert tags(window, "bite") == [1, 2, 3, 5, 7]
    assert data(window)["presentation"]["attack_hit_frame"] == 3 and tags(window, "bite")[3] == 5     # old frame 4
    window.undo()
    assert tags(window, "bite") == [1, 2, 3, 4, 5, 7] and data(window)["presentation"]["attack_hit_frame"] == 3

    panel.strip.setCurrentRow(0)                                 # an ordinary frame: no question at all
    click(panel.remove_frame_button)
    assert tags(window, "bite") == [2, 3, 4, 5, 7] and data(window)["presentation"]["attack_hit_frame"] == 2


def test_input_the_last_frame_is_not_removed(window):
    panel = window.animation
    grid_clip(window, "idle", "idle", 4)
    for _ in range(3):
        panel.strip.setCurrentRow(0)
        click(panel.remove_frame_button)
    assert len(tags(window, "idle")) == 1
    click(panel.remove_frame_button)
    assert len(tags(window, "idle")) == 1 and panel.notice.text() == strings.ANIMATION["last_frame"]


# --------------------------------------------------------------------------------------- FIX-03: clips
def frog_window(window):
    window.prompts.expect("unsaved_changes", dialogs.DISCARD)
    frog = load("frog")
    binding = dict(frog.data["source_binding"])
    binding["editability"] = {key: "editable" for key in binding["editability"]}
    window.set_session(DocumentSession(frog.replace(("source_binding",), None)))      # a free draft with gameplay data
    return window.animation


def test_input_a_clip_an_attack_pattern_uses_needs_a_replacement(window):
    window.session = window.session                                # the rat is clean: no prompt on replace
    panel = window.animation
    frog = load("frog").replace(("source_binding",), None)
    window.set_session(DocumentSession(frog))
    clip_id = next(pattern["clip"] for pattern in frog.data["attack_patterns"] if pattern["clip"])
    pattern = next(index for index, row in enumerate(frog.data["attack_patterns"]) if row["clip"] == clip_id)
    panel.select_clip(clip_id)
    clips = len(data(window)["animations"]["clips"])

    window.prompts.expect("choose", None)
    click(panel.remove_clip_button)
    _title, text, options = window.prompts.asked("choose")[-1]
    assert f"attack_patterns[{pattern}].clip" in text and clip_id not in options and len(options) == clips - 1
    assert len(data(window)["animations"]["clips"]) == clips and "사용 중" in panel.notice.text()

    replacement = options[0]
    window.prompts.expect("choose", replacement).expect("confirm", True)
    click(panel.remove_clip_button)
    assert len(data(window)["animations"]["clips"]) == clips - 1
    assert data(window)["attack_patterns"][pattern]["clip"] == replacement
    assert len(data(window)["attack_patterns"]) == len(frog.data["attack_patterns"])
    assert not validate(window.session.document).select(FAIL, "references")
    window.undo()
    assert window.session.document == frog


def test_input_renaming_a_clip_and_a_hitbox_takes_the_references_along(window):
    panel = window.animation
    frog = load("frog").replace(("source_binding",), None)
    window.set_session(DocumentSession(frog))
    clip_id = next(pattern["clip"] for pattern in frog.data["attack_patterns"] if pattern["clip"])
    panel.select_clip(clip_id)
    window.prompts.expect("text", "Bad Name")
    click(panel.rename_clip_button)
    assert window.session.document == frog and "적용하지 않았습니다" in panel.notice.text()
    window.prompts.expect("text", "great_leap")
    click(panel.rename_clip_button)
    assert "great_leap" in [clip["id"] for clip in data(window)["animations"]["clips"]]
    assert panel.current_clip()["id"] == "great_leap"                 # still the selected clip
    assert not validate(window.session.document).select(FAIL, "references")
    window.undo()
    assert window.session.document == frog

    hitbox = next(slot for slot in panel._slots() if slot.kind == "hitbox")
    users = len(logic.hitbox_usages(window.session.document, hitbox.label))
    assert users
    panel.select_shape(hitbox)
    window.prompts.expect("text", "jaw")
    click(panel.rename_shape)
    assert len(logic.hitbox_usages(window.session.document, "jaw")) == users


def test_input_a_hitbox_an_event_arms_needs_a_replacement(window):
    panel = window.animation
    frog = load("frog").replace(("source_binding",), None)
    window.set_session(DocumentSession(frog))
    hitbox = next(slot for slot in panel._slots() if slot.kind == "hitbox")
    panel.select_shape(hitbox)
    click(panel.remove_shape)                                     # no other hitbox exists: nothing to offer
    assert window.session.document == frog and "적용하지 않았습니다" in panel.notice.text()
    assert panel._slot == hitbox                                  # the selection was not thrown away
    click(panel.add_hitbox)
    spare = data(window)["collision"]["hitboxes"][-1]["id"]
    panel.select_shape(next(slot for slot in panel._slots() if slot.kind == "hitbox" and slot.label == hitbox.label))
    window.prompts.expect("choose", spare)
    click(panel.remove_shape)
    assert [box["id"] for box in data(window)["collision"]["hitboxes"]] == [spare]
    assert logic.hitbox_usages(window.session.document, spare)
    assert not validate(window.session.document).select(FAIL, "references")


def test_input_an_image_in_use_is_never_freed_by_deleting_frames(window):
    panel = window.animation
    image_id = grid_clip(window, "move", "walk", 6)
    before = window.session.document
    for row in range(panel.image_list.count()):
        item = panel.image_list.item(row)
        item.setSelected(item.data(Qt.ItemDataRole.UserRole) == image_id)
    click(panel.remove_image_button)                              # no other image to offer
    assert window.session.document is before and "적용하지 않았습니다" in panel.notice.text()
    assert len(tags(window, "walk")) == 6


# ------------------------------------------------------------------------------- FIX-05: geometry on screen
def test_input_resizing_in_a_flipped_preview_moves_the_authored_edge(window):
    panel, canvas = window.animation, window.animation.canvas
    hurtbox = panel._slots()[1]
    window.apply_edits(logic.set_shape(hurtbox, {"type": "rectangle", "center": [12, 2], "size": [10, 6]}), "shape")
    click_box(panel.flip)
    panel.select_shape(hurtbox)
    assert canvas.facing == -1
    handles = canvas.handle_positions(hurtbox)
    assert handles["right"].x() < handles["left"].x()            # authored right edge is on the screen's left
    start = handles["right"].toPoint()
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=start)
    QTest.mouseMove(canvas, start + QPoint(-8, 0))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=start + QPoint(-16, 0))   # dragged outwards on screen
    shape = logic.shape_at(data(window), hurtbox)
    left, _top, right, _bottom = shape_bounds(shape)
    assert left == 7 and right == 17 + 16 / canvas.zoom           # authored left edge stayed; right edge grew
    start = canvas.handle_positions(hurtbox)["left"].toPoint()
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=start)
    QTest.mouseMove(canvas, start + QPoint(4, 0))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=start + QPoint(8, 0))     # screen right = authored left
    assert shape_bounds(logic.shape_at(data(window), hurtbox))[0] == 7 - 8 / canvas.zoom
    click_box(panel.flip)                                         # facing right again: same stored shape
    assert canvas.facing == 1
    rect = canvas.view_shape_rect(logic.shape_at(data(window), hurtbox))
    assert rect.center().x() > canvas.origin().x()                # authored +x is on the screen's right


def test_zoom_pan_and_visual_scale_never_change_a_collision_shape(window, app):
    panel, canvas = window.animation, window.animation.canvas
    grid_clip(window, "idle", "idle", 4)
    shapes = [logic.shape_at(data(window), slot) for slot in panel._slots()]
    document = window.session.document
    panel.zoom.setValue(9.5)
    QTest.mousePress(canvas, Qt.MouseButton.MiddleButton, pos=QPoint(100, 100))
    QTest.mouseMove(canvas, QPoint(160, 130))
    QTest.mouseRelease(canvas, Qt.MouseButton.MiddleButton, pos=QPoint(160, 130))
    assert (canvas.pan.x(), canvas.pan.y()) == (60, 30) and canvas.zoom == 9.5
    assert window.session.document is document                    # view state only
    frame_before = canvas.frame_rect()
    panel.scale_x.setValue(2)
    panel.scale_y.setValue(2)
    panel.scale_y.editingFinished.emit()
    assert [logic.shape_at(data(window), slot) for slot in panel._slots()] == shapes
    assert math.isclose(canvas.frame_rect().width(), frame_before.width() * 2)        # only the picture grew
    canvas.reset_view()
    assert canvas.origin() == QPointF(canvas.width() / 2, canvas.height() / 2)


def test_art_that_faces_left_is_drawn_turned_and_shapes_are_not(window):
    panel, canvas = window.animation, window.animation.canvas
    grid_clip(window, "idle", "idle", 4)
    assert not canvas.picture_mirrored()
    window.apply_edits([set_value(("presentation", "faces_right_by_default"), False)], "facing")
    assert canvas.picture_mirrored()                              # facing right, art drawn facing left: flipped
    click_box(panel.flip)
    assert not canvas.picture_mirrored() and canvas.facing == -1
    hurtbox = panel._slots()[1]
    shape = logic.shape_at(data(window), hurtbox)
    assert canvas.view_shape_rect(shape).center().x() == pytest.approx(
        canvas.origin().x() - shape["center"][0] * canvas.zoom)


def test_the_bottom_centre_preset_says_when_frames_differ_in_size(window):
    panel = window.animation
    first = grid_clip(window, "idle", "idle", 4)
    panel.image_path.setText(f"{BEETLE}/move.png")
    click(panel.register_button)
    second = data(window)["assets"]["images"][-1]["id"]
    window.apply_edits(logic.clip_from_images(data(window), "mixed", [first, second]), "clip")
    panel.select_clip("mixed")
    assert logic.frame_sizes_differ(data(window), "mixed") and not logic.frame_sizes_differ(data(window), "idle")
    click(panel.anchor_button)
    assert panel.notice.text() == strings.ANIMATION["anchor_mixed"]
    panel.select_clip("idle")
    click(panel.anchor_button)
    assert panel.notice.text() == ""


def test_a_canvas_given_broken_numbers_draws_what_it_can(app):
    canvas = PreviewCanvas()
    canvas.resize(300, 200)
    canvas.show()
    slots = [logic.ShapeSlot("hurtbox", name, ("collision", "hurtboxes", index, "shape"))
             for index, name in enumerate(("nan", "inf", "empty", "negative", "missing", "good"))]
    shapes = [{"type": "rectangle", "center": [float("nan"), 0], "size": [4, 4]},
              {"type": "circle", "center": [0, 0], "radius": float("inf")},
              {"type": "rectangle", "center": [0, 0], "size": [0, 4]},
              {"type": "circle", "center": [0, 0], "radius": -3},
              {"type": "rectangle", "center": [0, 0]},
              {"type": "circle", "center": [5, 5], "radius": 4}]
    assert [usable_shape(shape) for shape in shapes] == [False, False, False, False, False, True]
    bad = {"faces_right_by_default": True, "visual_scale": [0, float("nan")], "visual_offset": [0, 0]}
    canvas.show_frame(None, (64, 48), bad, list(zip(slots, shapes)), True)
    assert canvas.frame_rect() is None
    canvas.select(slots[0])
    canvas.grab()                                                 # paints without raising
    assert canvas.handle_positions(slots[0]) == {}
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=canvas.to_view([5, 5]).toPoint())
    assert canvas.selected == slots[5] and canvas.dragging        # only the usable shape can be picked
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=canvas.to_view([5, 5]).toPoint())
    for zoom in (float("nan"), float("inf"), -1, 0, 1e9, "x"):
        canvas.set_zoom(zoom)
        assert 0.25 <= canvas.zoom <= 32
    far = canvas.to_authored(QPointF(1e12, -1e12))
    assert far == [4096.0, -4096.0]
    canvas.close()


# ------------------------------------------------------------------------------------- FIX-06: drag sessions
def start_drag(window, steps=3):
    panel, canvas = window.animation, window.animation.canvas
    panel.shape_list.setCurrentRow(0)
    body = panel._slots()[0]
    centre = canvas.to_view(logic.shape_at(data(window), body)["center"]).toPoint()
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=centre)
    for step in range(1, steps + 1):
        QTest.mouseMove(canvas, centre + QPoint(step * 8, step * 4))
    assert canvas.dragging and canvas.shape_of(body) != logic.shape_at(data(window), body)
    return body, centre + QPoint(steps * 8, steps * 4)


def assert_cancelled(window, document, history, end):
    canvas = window.animation.canvas
    assert not canvas.dragging
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=end)        # the button comes up later: nothing happens
    assert window.session is None or (window.session.document is document and len(window.session.history) == history)


@pytest.mark.parametrize("cause", ["escape", "frame", "clip", "flip", "play", "undo", "delete", "other_button",
                                   "list_selection", "edit"])
def test_input_a_drag_is_cancelled_when_what_it_started_on_changes(window, cause):
    panel, canvas = window.animation, window.animation.canvas
    grid_clip(window, "idle", "idle", 4)
    grid_clip(window, "move", "walk", 6)
    panel.select_clip("idle")
    if cause == "undo":
        window.apply_edits(logic.set_shape(panel._slots()[0], {"type": "rectangle", "center": [1, 1], "size": [20, 20]}),
                           "shape")
    body, end = start_drag(window)
    document, history = window.session.document, len(window.session.history)
    reasons = []
    canvas.drag_cancelled.connect(reasons.append)
    if cause == "escape":
        QTest.keyClick(canvas, Qt.Key.Key_Escape)
    elif cause == "frame":
        panel.strip.setCurrentRow(2)
    elif cause == "clip":
        panel.clip_list.setCurrentRow(1)
    elif cause == "flip":
        click_box(panel.flip)
    elif cause == "play":
        click(panel.play_button)
    elif cause == "undo":
        window.undo()
        document, history = window.session.document, len(window.session.history)
    elif cause == "delete":
        hurtbox = panel._slots()[1]
        window.apply_edits(logic.remove_box(window.session.document, hurtbox), "remove")
        document, history = window.session.document, len(window.session.history)
    elif cause == "other_button":
        QTest.mousePress(canvas, Qt.MouseButton.RightButton, pos=end)
    elif cause == "list_selection":
        panel.shape_list.setCurrentRow(1)
    elif cause == "edit":
        window.apply_edits([set_value(("presentation", "visual_offset"), [3, 3])], "elsewhere")
        document, history = window.session.document, len(window.session.history)
    if cause in ("delete", "edit"):
        # The dragged body itself is unchanged by these edits; the workspace still drops the drag when it
        # asks for an edit, and an edit from elsewhere leaves the drag alone only if its shape is the same.
        if cause == "edit":
            assert canvas.dragging                                 # unrelated edit: the drag survives
            QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=end)
            assert logic.shape_at(data(window), body) != logic.shape_at(document.data, body)
            return
        assert canvas.dragging or not canvas.dragging
        canvas.cancel_drag("test")
    assert reasons, cause
    assert_cancelled(window, document, history, end)
    assert logic.shape_at(data(window), body) == logic.shape_at(document.data, body)


def test_input_a_drag_does_not_survive_another_document_or_a_closed_one(window):
    canvas = window.animation.canvas
    grid_clip(window, "idle", "idle", 4)
    body, end = start_drag(window)
    first = window.session
    window.prompts.expect("unsaved_changes", dialogs.DISCARD)
    window.set_session(DocumentSession(load("sewer_beetle")))
    assert not canvas.dragging
    other = window.session.document
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=end)
    assert window.session.document is other and len(window.session.history) == 1
    assert len(first.history) == len(first.history)               # the old session got nothing either
    window.set_session(DocumentSession(load("sewer_rat_prototype")))
    body, end = start_drag(window)
    window.set_session(None)
    assert not canvas.dragging
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=end)
    assert window.session is None


def test_input_leaving_the_workspace_or_losing_focus_cancels_a_drag(window, app):
    panel, canvas = window.animation, window.animation.canvas
    _body, end = start_drag(window)
    document, history = window.session.document, len(window.session.history)
    window.workspaces.setCurrentIndex(0)                          # another workspace: the canvas is hidden
    app.processEvents()
    assert_cancelled(window, document, history, end)
    window.workspaces.setCurrentWidget(panel)
    app.processEvents()
    body, end = start_drag(window)
    canvas.clearFocus()
    canvas.focusOutEvent(__import__("PySide6.QtGui", fromlist=["QFocusEvent"]).QFocusEvent(
        __import__("PySide6.QtCore", fromlist=["QEvent"]).QEvent.Type.FocusOut))
    assert_cancelled(window, document, history, end)
    assert panel.notice.text() == strings.ANIMATION["drag_cancelled"]


def test_input_a_drag_that_ends_where_it_started_adds_no_history(window):
    panel, canvas = window.animation, window.animation.canvas
    panel.shape_list.setCurrentRow(0)
    body = panel._slots()[0]
    centre = canvas.to_view(logic.shape_at(data(window), body)["center"]).toPoint()
    history = len(window.session.history)
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=centre)
    QTest.mouseMove(canvas, centre + QPoint(30, 10))
    QTest.mouseMove(canvas, centre)
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=centre)
    assert len(window.session.history) == history


def test_input_a_drag_the_document_refuses_puts_the_shape_back(window, monkeypatch):
    panel, canvas = window.animation, window.animation.canvas
    body, end = start_drag(window)
    document = window.session.document
    monkeypatch.setattr(logic, "set_shape", lambda slot, shape: [set_value(("no", "such", "field"), 1)])
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=end)
    assert window.session.document is document
    assert canvas.shape_of(body) == logic.shape_at(document.data, body) and panel._slot == body


# ----------------------------------------------------------------------------------- FIX-07: playback
def test_input_play_pause_resume_and_stop(window):
    panel = window.animation
    grid_clip(window, "attack", "strike", 7)
    window.apply_edits([set_value(("animations", "clips", 0, "frames", index, "duration"), 1) for index in range(7)],
                       "even")
    assert panel.playback.state == "stopped" and panel.play_button.text() == strings.ANIMATION["play"]
    click(panel.play_button)
    assert panel.playback.playing and panel.play_button.text() == strings.ANIMATION["pause"]
    assert not panel.canvas.editable and strings.ANIMATION["playing_read_only"] == panel.canvas.message
    assert not panel.center_x.isEnabled()                         # shapes cannot be edited while frames change
    panel.advance(0.25)
    assert panel.current_frame() == 2 and panel.strip.currentRow() == 2
    click(panel.play_button)                                      # pause keeps the place
    assert panel.playback.state == "paused" and panel.current_frame() == 2 and panel.canvas.editable
    panel.advance(5)
    assert panel.current_frame() == 2                             # nothing advances while paused
    click(panel.play_button)                                      # resume, not restart
    panel.advance(0.1)
    assert panel.current_frame() == 3 and panel.playback.time == pytest.approx(0.35)
    click(panel.stop_button)
    assert panel.playback.state == "stopped" and panel.current_frame() == 0 and not panel.play_button.isChecked()
    click(panel.play_button)
    panel.advance(0.65)
    panel.advance(0.2)                                            # a one-shot clip ends on its last frame
    assert panel.current_frame() == 6 and panel.playback.finished and not panel.play_button.isChecked()
    assert panel.playback.state == "paused"
    click(panel.play_button)                                      # play after the end starts over
    assert panel.playback.time == 0 and panel.current_frame() == 0
    click(panel.play_button)
    panel.strip.setCurrentRow(4)                                  # pick a frame while paused, then play from it
    click(panel.play_button)
    assert panel.current_frame() == 4 and panel.playback.time == pytest.approx(0.4)
    click(panel.stop_button)


def test_playback_survives_an_edit_of_the_same_clip_and_stops_for_another(window):
    panel = window.animation
    grid_clip(window, "idle", "idle", 4)
    grid_clip(window, "move", "walk", 6)
    panel.select_clip("idle")
    window.apply_edits([set_value(("animations", "clips", 0, "loop"), True)], "loop")
    click(panel.play_button)
    panel.advance(0.05)
    window.apply_edits([set_value(("animations", "clips", 0, "fps"), 20)], "fps")
    assert panel.playback.playing and panel.playback.clip is panel.current_clip()
    assert panel.playback.clip["fps"] == 20
    panel.select_clip("walk")
    assert panel.playback.state == "stopped" and not panel.play_button.isChecked()
    click(panel.play_button)
    window.prompts.expect("unsaved_changes", dialogs.DISCARD)
    window.set_session(DocumentSession(load("sewer_beetle")))
    assert panel.playback.state == "stopped" and not panel._timer.isActive()


# ------------------------------------------------------------------------------------- selection contract
def test_other_views_can_follow_and_drive_the_selection(window):
    panel = window.animation
    seen = []
    panel.selection_changed.connect(lambda clip, frame, slot: seen.append((clip, frame, slot.label if slot else None)))
    grid_clip(window, "attack", "strike", 7)
    window.apply_edits([set_value(("animations", "clips", 0, "frames", index, "duration"), 1) for index in range(7)],
                       "even")
    panel.select_frame(3)
    assert seen[-1] == ("strike", 3, None)
    panel.seek(0.55)                                              # a timeline moves the preview by time
    assert seen[-1] == ("strike", 5, None) and panel.playback.frame_window == pytest.approx((0.5, 0.6))
    click(panel.add_hitbox)
    name = data(window)["collision"]["hitboxes"][-1]["id"]
    slot = panel.highlight_box("hitbox", name)                    # an attack event points at its hitbox
    assert slot is not None and panel.canvas.highlighted == slot and panel._slot != slot
    assert panel.highlight_box("hitbox", "absent") is None and panel.canvas.highlighted is None
    panel.select_shape(slot)
    assert seen[-1] == ("strike", 5, name)
    assert strings.ANIMATION["runtime_note"] == panel.runtime_note.text()
