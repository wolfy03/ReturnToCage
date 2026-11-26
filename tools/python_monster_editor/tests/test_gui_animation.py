"""The Animation / Collision workspace on the real window.

``test_input_...`` tests click and drag real widgets through ``QTest``. The others call the workspace's
public methods. Images come from the repository's own beetle sheets, read through the project root.
"""

import pytest

pytest.importorskip("PySide6")

from PySide6.QtCore import QPoint, Qt  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402

from conftest import PROJECT, load  # noqa: E402
from application import animation as logic  # noqa: E402
from application.session import DocumentSession  # noqa: E402
from application.settings import Settings  # noqa: E402
from gui import dialogs, strings  # noqa: E402
from gui.animation import load_frame  # noqa: E402
from gui.main_window import MainWindow  # noqa: E402
from gui.testing import ScriptedPrompts  # noqa: E402
from rtcmonster.geometry import shape_bounds  # noqa: E402
from test_gui import app  # noqa: E402,F401  (session fixture)
from conftest import fake  # noqa: E402,F401

BEETLE = "assets/characters/enemies/sewer_beetle"


@pytest.fixture
def window(app, tmp_path):  # noqa: F811
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


def register(window, name):
    panel = window.animation
    panel.image_path.setText(f"{BEETLE}/{name}.png")
    QTest.mouseClick(panel.register_button, Qt.MouseButton.LeftButton)
    return data(window)["assets"]["images"][-1]["id"]


def select_image(panel, image_id):
    for row in range(panel.image_list.count()):
        item = panel.image_list.item(row)
        item.setSelected(item.data(Qt.ItemDataRole.UserRole) == image_id)


def grid_clip(window, name, clip_id, columns):
    panel = window.animation
    image_id = register(window, name)
    select_image(panel, image_id)
    panel.clip_id.setText(clip_id)
    panel.columns.setValue(columns)
    QTest.mouseClick(panel.grid_button, Qt.MouseButton.LeftButton)
    return image_id


# ------------------------------------------------------------------------------------------ images and clips
def test_input_registering_an_image_and_cutting_a_grid_clip(window):
    panel = window.animation
    assert window.workspaces.tabText(window.workspaces.indexOf(panel)) == strings.ANIMATION["title"]
    image_id = grid_clip(window, "move", "walk", 6)
    clip = data(window)["animations"]["clips"][0]
    assert image_id == "move" and clip["id"] == "walk" and len(clip["frames"]) == 6
    assert panel.image_list.count() == 1 and panel.clip_list.count() == 1 and panel.strip.count() == 6
    assert panel.current_clip()["id"] == "walk" and panel.image_path.text() == "" and panel.clip_id.text() == ""
    assert panel.canvas.pixmap is not None and panel.canvas.frame_size == (64, 48)
    assert not panel.strip.item(0).icon().isNull()
    window.undo()
    assert data(window)["animations"]["clips"] == [] and panel.strip.count() == 0
    window.undo()
    assert data(window)["assets"]["images"] == [] and panel.image_list.count() == 0
    assert not window.session.can_undo


def test_input_a_refused_action_changes_nothing_and_says_why(window):
    panel = window.animation
    before = window.session.document.fingerprint
    panel.image_path.setText(f"{BEETLE}/absent.png")
    QTest.mouseClick(panel.register_button, Qt.MouseButton.LeftButton)
    assert "absent.png" in panel.notice.text() or panel.notice.text()
    image_id = register(window, "move")
    select_image(panel, image_id)
    panel.columns.setValue(5)                     # 384 px does not divide into 5 equal frames
    middle = window.session.document.fingerprint
    QTest.mouseClick(panel.grid_button, Qt.MouseButton.LeftButton)
    assert window.session.document.fingerprint == middle != before
    assert "5x1" in panel.notice.text() and panel.clip_list.count() == 0
    select_image(panel, "")
    QTest.mouseClick(panel.grid_button, Qt.MouseButton.LeftButton)
    assert panel.notice.text() == strings.ANIMATION["select_one_image"]


def test_input_frame_duration_order_and_removal_are_single_undo_steps(window):
    panel = window.animation
    grid_clip(window, "move", "walk", 6)
    steps = len(window.session.history.snapshots) if hasattr(window.session.history, "snapshots") else None
    first = list(data(window)["animations"]["clips"][0]["frames"][0]["rect"])
    panel.strip.setCurrentRow(0)
    panel.duration.setValue(2.5)
    panel.duration.editingFinished.emit()
    assert data(window)["animations"]["clips"][0]["frames"][0]["duration"] == 2.5
    QTest.mouseClick(panel.frame_right, Qt.MouseButton.LeftButton)
    frames = data(window)["animations"]["clips"][0]["frames"]
    assert list(frames[1]["rect"]) == first and frames[1]["duration"] == 2.5 and panel.current_frame() == 1
    QTest.mouseClick(panel.remove_frame_button, Qt.MouseButton.LeftButton)
    assert len(data(window)["animations"]["clips"][0]["frames"]) == 5 and panel.strip.count() == 5
    for _ in range(3):
        window.undo()
    restored = data(window)["animations"]["clips"][0]["frames"]
    assert len(restored) == 6 and list(restored[0]["rect"]) == first and restored[0]["duration"] == 1
    assert steps is None or len(window.session.history.snapshots) >= steps
    panel.fps.setValue(15)
    panel.fps.editingFinished.emit()
    QTest.mouseClick(panel.loop, Qt.MouseButton.LeftButton, pos=QPoint(8, panel.loop.height() // 2))
    clip = data(window)["animations"]["clips"][0]
    assert clip["fps"] == 15 and clip["loop"] is True


def test_input_roles_and_the_bottom_centre_preset(window):
    panel = window.animation
    grid_clip(window, "idle", "idle", 4)
    combo = panel.roles["idle"]
    combo.setCurrentIndex(combo.findData("idle"))
    combo.activated.emit(combo.currentIndex())
    assert data(window)["presentation"]["roles"]["idle"] == "idle"
    assert "idle" in panel.clip_list.item(0).text() and "[idle]" in panel.clip_list.item(0).text()
    QTest.mouseClick(panel.anchor_button, Qt.MouseButton.LeftButton)
    offset = list(data(window)["presentation"]["visual_offset"])
    body_bottom = shape_bounds(data(window)["collision"]["body"]["shape"])[3]
    assert offset == [0, body_bottom - 24] and panel.offset_y.value() == offset[1]
    panel.scale_x.setValue(0.5)
    panel.scale_y.setValue(0.5)
    panel.scale_y.editingFinished.emit()
    assert list(data(window)["presentation"]["visual_scale"]) == [0.5, 0.5]
    QTest.mouseClick(panel.remove_clip_button, Qt.MouseButton.LeftButton)
    assert data(window)["presentation"]["roles"]["idle"] == "" and data(window)["animations"]["clips"] == []


# -------------------------------------------------------------------------------------------------- playback
def test_playback_follows_the_documents_timing_rule(window):
    panel = window.animation
    grid_clip(window, "attack", "strike", 7)
    clip = panel.current_clip()
    assert clip["fps"] == 10 and not clip["loop"]
    panel.show_time(0.25)
    assert panel.current_frame() == 2 and panel.strip.currentRow() == 2
    panel.play_button.setChecked(True)
    panel.show_time(99)                           # a one-shot clip holds its last frame and stops
    assert panel.current_frame() == 6 and not panel.play_button.isChecked()
    window.apply_edits([logic.set_value(logic.CLIPS + (0, "loop"), True)], "loop")
    panel.show_time(0.75)                         # 0.7 s long: wraps to 0.05 s
    assert panel.current_frame() == 0


# ---------------------------------------------------------------------------------------------------- shapes
def test_input_dragging_a_shape_on_the_canvas_is_one_edit_on_release(window, app):  # noqa: F811
    panel, canvas = window.animation, window.animation.canvas
    grid_clip(window, "idle", "idle", 4)
    body = panel._slots()[0]
    before = logic.shape_at(data(window), body)
    centre = canvas.to_view(before["center"]).toPoint()
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=centre)
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=centre)
    assert canvas.selected == panel._slots()[panel.shape_list.currentRow()] != body    # the top shape is picked
    panel.shape_list.setCurrentRow(0)             # a shape chosen in the list is draggable under the others
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=centre)
    assert panel.shape_list.currentRow() == 0 and canvas.selected == body
    fingerprint = window.session.document.fingerprint
    for step in range(1, 6):
        QTest.mouseMove(canvas, centre + QPoint(step * 8, step * 4))
    assert window.session.document.fingerprint == fingerprint          # nothing is written during the drag
    assert canvas.shape_of(body)["center"] != before["center"]          # but the preview follows the mouse
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=centre + QPoint(40, 20))
    moved = logic.shape_at(data(window), body)
    assert moved["center"] == [before["center"][0] + 40 / canvas.zoom, before["center"][1] + 20 / canvas.zoom]
    assert moved["size"] == before["size"] and panel.center_x.value() == moved["center"][0]
    handle = canvas.handle_positions(body)["right"].toPoint()
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=handle)
    QTest.mouseMove(canvas, handle + QPoint(12, 0))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=handle + QPoint(24, 0))
    resized = logic.shape_at(data(window), body)
    assert shape_bounds(resized)[0] == shape_bounds(moved)[0]            # the opposite edge stayed
    assert shape_bounds(resized)[2] == shape_bounds(moved)[2] + 24 / canvas.zoom
    window.undo()
    assert logic.shape_at(data(window), body) == moved
    window.undo()
    assert logic.shape_at(data(window), body) == before


def test_input_a_flipped_preview_edits_the_authored_shape(window):
    panel, canvas = window.animation, window.animation.canvas
    hurtbox = panel._slots()[1]
    window.apply_edits(logic.set_shape(hurtbox, {"type": "rectangle", "center": [10, 0], "size": [8, 8]}), "shape")
    QTest.mouseClick(panel.flip, Qt.MouseButton.LeftButton, pos=QPoint(8, panel.flip.height() // 2))
    assert canvas.facing == -1
    shown = canvas.to_view([-10, 0]).toPoint()                           # mirrored on screen
    panel.shape_list.setCurrentRow(1)
    QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=shown)
    assert canvas.selected == hurtbox
    QTest.mouseMove(canvas, shown + QPoint(-8, 0))
    QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=shown + QPoint(-16, 0))
    # Dragged further left on a left-facing preview: further along +x in the authored, right-facing space.
    assert logic.shape_at(data(window), hurtbox)["center"] == [10 + 16 / canvas.zoom, 0]


def test_input_shape_fields_type_and_enabled(window):
    panel = window.animation
    panel.shape_list.setCurrentRow(1)
    slot = panel._slots()[1]
    panel.center_x.setValue(7)
    panel.center_x.editingFinished.emit()
    panel.extent_a.setValue(20)
    panel.extent_a.editingFinished.emit()
    shape = logic.shape_at(data(window), slot)
    assert shape["center"][0] == 7 and shape["size"][0] == 20
    panel.shape_type.setCurrentIndex(panel.shape_type.findData("circle"))
    panel.shape_type.activated.emit(panel.shape_type.currentIndex())
    assert logic.shape_at(data(window), slot)["type"] == "circle" and not panel.extent_b.isVisible()
    QTest.mouseClick(panel.enabled, Qt.MouseButton.LeftButton, pos=QPoint(8, panel.enabled.height() // 2))
    assert data(window)["collision"]["hurtboxes"][0]["enabled"] is False
    count = len(data(window)["collision"]["hitboxes"])
    QTest.mouseClick(panel.add_hitbox, Qt.MouseButton.LeftButton)
    assert len(data(window)["collision"]["hitboxes"]) == count + 1
    panel.shape_list.setCurrentRow(panel.shape_list.count() - 1)
    QTest.mouseClick(panel.remove_shape, Qt.MouseButton.LeftButton)
    assert len(data(window)["collision"]["hitboxes"]) == count
    panel.shape_list.setCurrentRow(0)
    assert not panel.remove_shape.isEnabled()                            # the body cannot be removed


def test_input_frame_overrides_show_and_edit_their_own_set(window):
    panel = window.animation
    grid_clip(window, "attack", "strike", 7)
    panel.strip.setCurrentRow(3)
    QTest.mouseClick(panel.override_frame, Qt.MouseButton.LeftButton)
    overrides = data(window)["collision"]["hurtbox_overrides"]
    assert len(overrides) == 1 and overrides[0]["clip"] == "strike" and overrides[0]["frame"] == 3
    assert "3" in panel.override_label.text() and panel._slots()[1].kind == "override"
    panel.shape_list.setCurrentRow(1)
    panel.center_y.setValue(-9)
    panel.center_y.editingFinished.emit()
    assert data(window)["collision"]["hurtbox_overrides"][0]["boxes"][0]["shape"]["center"][1] == -9
    assert data(window)["collision"]["hurtboxes"][0]["shape"]["center"][1] != -9      # the default set is untouched
    panel.strip.setCurrentRow(2)
    assert panel._slots()[1].kind == "hurtbox" and panel.override_label.text() == strings.ANIMATION["override_none"]
    panel.strip.setCurrentRow(3)
    QTest.mouseClick(panel.override_clear, Qt.MouseButton.LeftButton)
    assert data(window)["collision"]["hurtbox_overrides"] == []


# ------------------------------------------------------------------------------------------------- read-only
def test_an_imported_legacy_monster_previews_but_cannot_be_edited(window):
    window.set_session(DocumentSession(load("sewer_beetle")))
    panel = window.animation
    assert panel.clip_list.count() == 5 and panel.canvas.pixmap is not None
    assert panel.notice.text() == strings.ANIMATION["read_only"]
    for widget in (panel.register_button, panel.grid_button, panel.remove_clip_button, panel.fps, panel.anchor_button,
                   panel.add_hurtbox, panel.override_frame, panel.roles["idle"], panel.center_x):
        assert not widget.isEnabled()
    assert panel.play_button.isEnabled() and not panel.canvas.editable
    before = window.session.document.fingerprint
    body = panel._slots()[0]
    centre = panel.canvas.to_view(logic.shape_at(data(window), body)["center"]).toPoint()
    QTest.mousePress(panel.canvas, Qt.MouseButton.LeftButton, pos=centre)
    QTest.mouseMove(panel.canvas, centre + QPoint(30, 0))
    QTest.mouseRelease(panel.canvas, Qt.MouseButton.LeftButton, pos=centre + QPoint(30, 0))
    assert window.session.document.fingerprint == before
    from rtcmonster.timing import frame_start_seconds
    panel.show_time(frame_start_seconds(panel.current_clip(), 2) + 0.001)
    assert panel.current_frame() == 2 and panel.strip.currentRow() == 2


def test_frames_are_decoded_once_per_file_content(window):
    first, state = load_frame(PROJECT, f"{BEETLE}/idle.png", [0, 0, 64, 48])
    again, _state = load_frame(PROJECT, f"{BEETLE}/idle.png", [0, 0, 64, 48])
    assert state == "ok" and first is again and (first.width(), first.height()) == (64, 48)
    assert load_frame(PROJECT, f"{BEETLE}/absent.png")[1] == "missing"
    assert load_frame(None, f"{BEETLE}/idle.png")[1] == "unchecked" and load_frame(PROJECT, "")[1] == "none"


def test_closing_the_document_empties_the_workspace(window):
    grid_clip(window, "idle", "idle", 4)
    window.prompts.expect("unsaved_changes", dialogs.DISCARD)
    window.close_document()
    panel = window.animation
    assert panel.image_list.count() == panel.clip_list.count() == panel.strip.count() == 0
    assert panel.canvas.message == strings.ANIMATION["no_document"] and not panel.register_button.isEnabled()


# -------------------------------------------------------------------------------------------------- staging
def test_the_stage_action_reports_what_godot_built(app, tmp_path, fake):  # noqa: F811
    import json
    from test_staging import OUTPUTS, stage_data
    godot, project, set_mode = fake
    for name in ("autoload/content_registry.gd", "data/definitions/enemy_definition.gd"):
        (project / name).parent.mkdir(parents=True, exist_ok=True)
        (project / name).write_text("", encoding="utf-8")
    prompts = ScriptedPrompts()
    view = MainWindow(Settings(tmp_path / "settings.json"), prompts)
    view.apply_project_settings({"project_root": str(project), "godot_path": str(godot), "drafts_folder": str(tmp_path)})
    view.show()
    QTest.qWaitForWindowExposed(view)
    try:
        assert not view.actions_by_name["stage"].isEnabled()                  # nothing open
        beetle = load("sewer_beetle")
        view.set_session(DocumentSession(beetle))
        assert view.actions_by_name["stage"].isEnabled()
        set_mode("ok", data=json.dumps(stage_data(beetle)), touch=OUTPUTS)
        assert view.stage_presentation(carrier="ant") is not None
        view.wait_for_jobs()
        assert view.last_stage is not None and view.last_stage.passed and not view.last_stage.staging_root.exists()
        assert prompts.last_error() is None and not (project / "monster_stage").exists()
        data = stage_data(beetle)
        data["profile"]["roles"]["move"] = "idle"
        set_mode("ok", data=json.dumps(data), touch=OUTPUTS)
        view.stage_presentation()
        view.wait_for_jobs()
        assert not view.last_stage.passed and "role move" in prompts.last_error()[1]
        view.set_session(DocumentSession(load("sewer_rat_prototype")))      # no clips: nothing to stage
        assert not view.actions_by_name["stage"].isEnabled()
    finally:
        view.session = None
        view.close()
        view.deleteLater()
        app.processEvents()
