import pytest

pytest.importorskip("PySide6", reason="Qt is installed by the Windows GUI job")

from PySide6.QtCore import QPointF, QSettings, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialogButtonBox

import godot_ui
from document import MapDocument, read_document
from godot_bridge import BridgeError
from region_design import RegionDesign
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

        window.exit_id.setText("settlement_gate")
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
