"""Exercise offline Region design using the shipped Qt window."""

import hashlib
import sys

from PySide6.QtCore import QPointF, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialogButtonBox

from document import encode
from region_validation import FAIL, NOT_EVALUATED, PASS
from wizard_ui import RegionWizard


def edit_region(window, fixture, require):
    app = QApplication.instance()
    launches = []

    def audit(event, _args):
        if event == "subprocess.Popen":
            launches.append(event)

    sys.addaudithook(audit)
    window._stop_texture_scan()
    window.settings.remove("library/root")
    window.view.textures.root = None

    def fill_wizard():
        dialog = app.activeModalWidget()
        if not isinstance(dialog, RegionWizard):
            app.exit(1)
            return
        dialog.region_id.setText("offline_region")
        dialog.template.setCurrentIndex(1)
        dialog.slots.setValue(3)
        button = dialog.findChild(QDialogButtonBox).button(QDialogButtonBox.StandardButton.Ok)
        QTest.mouseClick(button, Qt.MouseButton.LeftButton)

    require(not window.godot_import_action.isEnabled(), "offline region workflow has no Godot configuration")
    QTimer.singleShot(0, fill_wizard)
    window.wizard_action.trigger()
    require(window.draft.region_id == "offline_region" and len(window.draft.objects) == 1
            and len(window.view.markers) == 5, "native Flat wizard built terrain, markers and slots")
    window.undo.undo()
    require(not window.view.markers and window.draft.design is None, "undo wizard removed the generated layout")
    window.undo.redo()
    for mode, x, y in (("place_entry", 340, 160), ("place_escape", 590, 180), ("place_spawn", 690, 220)):
        window.tool_actions[mode].trigger()
        window.view.fit_map()
        QTest.mouseClick(window.view.viewport(), Qt.MouseButton.LeftButton,
                         pos=window.view.mapFromScene(QPointF(x, y)))
    require(len(window.view.markers) == 8, "Qt viewport placed ENTRY, ESCAPE and the fourth spawn")
    entry = window.draft.design.region_points[0]
    window.exit_id.setText("settlement_gate")
    window.destination.setCurrentText("offline_region")
    window.entry_target.setCurrentText(entry.point_id)
    window._add_connection()
    window.environment_path.setText("res://world/environment/presets/sewer_environment.tres")
    window.environment_color.setText("#113355")
    window._save_environment()
    window.validation_action.trigger()
    require(window._python_state == PASS and window._export_state == window._runtime_state == NOT_EVALUATED,
            "Python validation is separate from Godot export and runtime")
    window._move_marker(entry.id, (-32, 70))
    require(window.validation_list.count() == 0, "map change invalidated stale validation")
    window.validation_action.trigger()
    require(window._python_state == FAIL and window.view.markers[entry.id].issue,
            "out-of-bounds ENTRY is highlighted by offline validation")
    issue = next(window.validation_list.item(i) for i in range(window.validation_list.count())
                 if window.validation_list.item(i).data(Qt.ItemDataRole.UserRole).code == "outside_bounds")
    window.validation_list.scrollToItem(issue)
    QTest.mouseClick(window.validation_list.viewport(), Qt.MouseButton.LeftButton,
                     pos=window.validation_list.visualItemRect(issue).center())
    require(window.view.marker_id == entry.id, "clicked validation row focuses the ENTRY")
    window.undo.undo()
    window.save_document(fixture)
    require(not window.dirty and not launches, "V4 saved without any Bridge subprocess")


def reopen_region(window, path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    window.open_document(path)
    document = window.draft
    assert hashlib.sha256(encode(document)).hexdigest() == digest
    assert document.region_id == "offline_region" and len(window.view.markers) == 8
    assert len(document.design.spawn_points) == 4
    assert document.design.connections[0].entry_id == "offline_region_entry"
    assert document.design.environment.loading_color == "#113355"
    assert not window.dirty and window.close()
    return digest
