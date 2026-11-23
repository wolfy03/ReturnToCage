import pytest
from dataclasses import replace
from threading import Event
from types import SimpleNamespace

pytest.importorskip("PySide6", reason="Qt is installed by the Windows GUI job")

from PySide6.QtCore import QPointF, QSettings, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialogButtonBox, QFileDialog, QInputDialog, QListWidgetItem

import godot_ui
from document import MapDocument, read_document, write_document
from godot_bridge import BridgeError
from objects import MapObject
from region_design import RegionDesign, RegionEnvironment
from region_validation import FAIL, NOT_EVALUATED, PASS, Finding
from region_wizard import create_region
from strings import tr
from window import MainWindow
from wizard_ui import RegionWizard


def test_offline_region_workflow_with_qt_events(monkeypatch, tmp_path):
    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    launches = []
    monkeypatch.setattr(window, "_start_godot", lambda *args, **kwargs: launches.append(args))
    window.show()
    app.processEvents()

    def finish_wizard():
        dialog = app.activeModalWidget()
        assert isinstance(dialog, RegionWizard)
        dialog.region_id.setText("offline_region")
        dialog.slots.setValue(1)
        dialog.findChild(QDialogButtonBox).button(QDialogButtonBox.StandardButton.Ok).click()

    try:
        QTimer.singleShot(0, finish_wizard)
        window.wizard_action.trigger()
        assert window.draft.region_id == "offline_region" and window.dirty
        window.undo.undo()
        assert window.draft.design is None
        window.undo.redo()
        window.view.fit_map()
        screen = window.view.viewport()
        for tool, x, y in (("place_entry", 350, 210), ("place_escape", 500, 250), ("place_spawn", 600, 200)):
            window.tool_actions[tool].trigger()
            spot = window.view.mapFromScene(QPointF(x, y))
            QTest.mouseClick(screen, Qt.MouseButton.LeftButton, pos=spot)
        assert len(window.draft.design.region_points) == 4
        assert len(window.draft.design.spawn_points) == 2
        marker = window.draft.design.region_points[-1]
        window.tool_actions["select"].trigger()
        hit = window.view.mapFromScene(QPointF(*marker.position))
        hit.setY(hit.y() - 10)
        end = hit + type(hit)(38, 7)
        QTest.mousePress(screen, Qt.MouseButton.LeftButton, pos=hit)
        QTest.mouseMove(screen, end)
        QTest.mouseRelease(screen, Qt.MouseButton.LeftButton, pos=end)
        assert window.draft.design.region_points[-1].position != marker.position
        window.undo.undo()
        assert window.draft.design.region_points[-1] == marker
        window.undo.redo()
        window._delete_marker()
        assert len(window.draft.design.region_points) == 3
        window.undo.undo()

        assert window.exit_id.findText("offline_region_entry") == -1
        window.exit_id.setCurrentText("offline_region_exit")
        window.destination.setCurrentText("offline_region")
        window.entry_target.setCurrentText("offline_region_entry")
        window._add_connection()
        window.environment_path.setText("res://world/environment/presets/sewer_environment.tres")
        window.environment_color.setText("#112233")
        window._save_environment()
        path = tmp_path / "오프라인 지역.rtcmap"
        window.save_document(path)
        assert not window.dirty
        before = window.draft
        window.open_document(path)
        assert read_document(path)[0] == window.draft == before
        assert not window.godot_export_action.isEnabled() and not launches
    finally:
        window.undo.setClean()
        window.close()


@pytest.mark.parametrize("operation", ["export_as", "export_region", "validate_export"])
def test_unsupported_region_design_never_starts_a_godot_session(monkeypatch, operation):
    monkeypatch.setattr(godot_ui, "GodotSession", lambda *args: pytest.fail("unsupported export started Godot"))
    with pytest.raises(BridgeError, match="UNSUPPORTED_NODE"):
        godot_ui.run_operation(None, None, operation, (MapDocument(design=RegionDesign()), None), None)


def test_v4_publish_requires_explicit_approval_after_runtime(monkeypatch, tmp_path):
    calls = []
    draft = MapDocument(design=RegionDesign())
    receipt = {"scene_path": "world/adventure/new_region.tscn", "runtime": {"overall": "PASS"}}

    class Session:
        evidence = tmp_path
        settings = SimpleNamespace(project=tmp_path)

        def __init__(self, *_):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def stage_design(self, document):
            calls.append("runtime-confirmed")
            return document, receipt

    def review(observed):
        assert observed is receipt and calls == ["runtime-confirmed"]
        calls.append("declined")
        return False

    monkeypatch.setattr(godot_ui, "GodotSession", Session)
    monkeypatch.setattr(godot_ui, "recover_project", lambda _: [])
    monkeypatch.setattr(godot_ui, "publish_pair", lambda *_: pytest.fail("declined pair was published"))
    with pytest.raises(BridgeError, match="CANCELLED"):
        godot_ui.run_operation(None, Event(), "publish_design", (draft, None), lambda _: None, approval=review)
    assert calls == ["runtime-confirmed", "declined"]


def test_source_conflict_after_runtime_evidence_keeps_the_runtime_result(tmp_path):
    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    try:
        window._godot_progress(tr("runtime_running"))
        window._godot_progress(tr("runtime_validated"))
        error = BridgeError("SOURCE_MODIFIED", "fixture changed")
        window._record_godot_validation(error, window._bridge_phase)
        assert window._export_state == FAIL and window._runtime_state == PASS
        window.region_id.setText("changed")
        assert window._export_state == window._runtime_state == NOT_EVALUATED
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()


def test_erase_continuous_segment_hits_small_objects_between_mouse_samples():
    from viewport import MapView

    app = QApplication.instance() or QApplication([])
    view = MapView()
    try:
        things = tuple(MapObject(f"tiny_{i}", "platform", "terrain", (x, 20), (4, 4))
                       for i, x in enumerate((14, 45, 82)))
        view.sync_document(MapDocument(objects=things), ())
        view.set_zoom(0.15)
        removed = set()
        view._erase_segment(QPointF(0, 20), QPointF(100, 20), None, removed)
        assert removed == {item.id for item in things}
    finally:
        view.close()
        app.processEvents()


def test_index_status_and_validation_focus_follow_external_file_revision(tmp_path, monkeypatch):
    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    try:
        draft = create_region("draft", "Draft", 1200, 600, "flat", 4, RegionEnvironment())
        external = create_region("other", "이웃", 1200, 600, "flat", 4, RegionEnvironment())
        path = tmp_path / "외부 지역.rtcmap"
        digest = write_document(path, external)
        window._install_draft(draft)
        monkeypatch.setattr(QFileDialog, "getOpenFileNames", lambda *_: ([str(path)], ""))
        window._index_region_files()
        assert window.draft == draft
        window.destination.setCurrentText("other")
        assert window.destination_status.text() == "Indexed"
        assert window.entry_target.currentText() == "other_entry"
        window._add_connection()
        window._validate_python()
        assert window._python_state == window._external_state == PASS
        assert window._runtime_state == window._physics_state == window._overall_state == NOT_EVALUATED
        saved = tmp_path / "연결 있음.rtcmap"
        window.save_document(saved)
        window._install_draft(MapDocument())
        window.open_document(saved)
        window.destination.setCurrentText("other")
        assert window.connection_list.count() == 1

        renamed_points = (replace(external.design.region_points[0], point_id="changed_entry"), external.design.region_points[1])
        changed = replace(external, design=replace(external.design, region_points=renamed_points))
        write_document(path, changed, digest)
        window._validate_python()
        assert window.destination_status.text().startswith("Modified")
        assert window.entry_target.findText("other_entry") == -1 and window._external_state == NOT_EVALUATED
        assert "Modified" in window.connection_list.item(0).text()
        target = next(window.validation_list.item(i) for i in range(window.validation_list.count())
                      if window.validation_list.item(i).data(Qt.ItemDataRole.UserRole).code == "destination_modified")
        window._focus_finding(target)
        assert window.region_tabs.currentIndex() == 1 and window.connection_list.currentRow() == 0

        window._index_region_files()
        assert window.validation_list.count() == 0 and window.entry_target.currentText() == "changed_entry"
        window._validate_python()
        assert window._external_state == FAIL and window._overall_state == FAIL
        window._remove_connection()
        assert window.validation_list.count() == 0
        window.undo.undo()
        assert len(window.draft.design.connections) == 1
        window.undo.redo()
        assert not window.draft.design.connections
        stale = QListWidgetItem()
        stale.setData(Qt.ItemDataRole.UserRole, Finding(FAIL, "outside_bounds", target="marker:removed"))
        window._focus_finding(stale)
        assert window.statusBar().currentMessage() == tr("validation_target_missing")
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()


def test_design_edits_and_preset_invalidate_validation_on_undo_and_redo(tmp_path, monkeypatch):
    app = QApplication.instance() or QApplication([])
    window = MainWindow(QSettings(str(tmp_path / "qt.ini"), QSettings.Format.IniFormat))
    try:
        window._install_draft(create_region("draft", "Draft", 1200, 600, "flat", 3, RegionEnvironment()))

        def check_edit(action):
            before = window.draft
            window._validate_python()
            action()
            after = window.draft
            assert before != after and window.validation_list.count() == 0
            window._validate_python()
            window.undo.undo()
            assert window.draft == before and window.validation_list.count() == 0
            window._validate_python()
            window.undo.redo()
            assert window.draft == after and window.validation_list.count() == 0

        for mode in ("place_entry", "place_escape", "place_spawn"):
            check_edit(lambda: window._add_marker(mode, (200, 200)))
            key = window.view.marker_id
            check_edit(lambda: window._move_marker(key, (250, 250)))
            check_edit(window._delete_marker)

        window.environment_color.setText("#122436")
        check_edit(window._save_environment)
        window.view.objects["flat_ground"].setSelected(True)
        monkeypatch.setattr(QInputDialog, "getText", lambda *_: ("Platform preset", True))
        monkeypatch.setattr(QInputDialog, "getItem", lambda *args, **_: (args[3][0], True))
        window._capture_placement()
        check_edit(window._apply_placement)
    finally:
        window.undo.setClean()
        window.close()
        app.processEvents()
