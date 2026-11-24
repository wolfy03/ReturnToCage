"""Exercise offline Region design using the shipped Qt window."""

import hashlib
import sys

from PySide6.QtCore import QPointF, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QApplication, QDialogButtonBox

from document import encode
from region_validation import FAIL, NOT_EVALUATED, PASS
from wizard_ui import RegionWizard
from terrain_atlas import discover_themes


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
    window.view.textures.terrain.slices.clear()
    window.terrain_themes, _ = discover_themes(window.view.textures.terrain_root)
    window.library.set_themes(window.terrain_themes)

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
    window.exit_id.setCurrentText("offline_region_exit")
    window.destination.setCurrentText("offline_region")
    window.entry_target.setCurrentText(entry.point_id)
    window._add_connection()
    window.environment_path.setText("res://world/environment/presets/sewer_environment.tres")
    window.environment_color.setText("#113355")
    window._save_environment()
    window.validation_action.trigger()
    require(window._python_state == window._external_state == PASS
            and window._export_state == window._runtime_state == window._physics_state == window._overall_state == NOT_EVALUATED,
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
    view = window.view
    window.tool_actions["select"].trigger()
    view.fit_map()
    floor = window.draft.objects[0]
    QTest.mouseClick(view.viewport(), Qt.MouseButton.LeftButton, pos=view.mapFromScene(QPointF(*floor.position)))
    theme = window.object_inspector.fields["terrain_theme"]
    QTest.keyClick(theme, Qt.Key.Key_End)
    require(window.draft.objects[0].properties.terrain.theme_id == "sewer_concrete",
            "terrain Inspector applies a registered theme")
    window.undo.undo()
    require(window.draft.objects[0].properties.terrain is None, "terrain theme undo restores the legacy polygon")
    window.undo.redo()
    require(window.draft.objects[0].properties.terrain.theme_id == "sewer_concrete",
            "terrain theme redo restores atlas settings")
    brush = window.library.brush_theme
    QTest.keyClick(brush, Qt.Key.Key_Home)
    # Step by theme id, not by list position: registering a theme must not move the target.
    for _ in range(brush.findData("forest_ground")):
        QTest.keyClick(brush, Qt.Key.Key_Down)
    window.layer_panel.select_layer("terrain")
    window.tool_actions["rectangle"].trigger()
    begin = view.mapFromScene(QPointF(256, 288))
    end = view.mapFromScene(QPointF(352, 320))
    QTest.mousePress(view.viewport(), Qt.MouseButton.LeftButton, pos=begin)
    QTest.mouseMove(view.viewport(), end)
    QTest.mouseRelease(view.viewport(), Qt.MouseButton.LeftButton, pos=end)
    painted = window.draft.objects[-1]
    require(painted.properties.terrain.theme_id == "forest_ground" and painted.size == (96, 32),
            "snapped rectangle brush placed a forest platform")
    window.tool_actions["select"].trigger()
    view.set_zoom(0.75)
    view.centerOn(QPointF(*painted.position))
    item = view.objects[painted.id]
    fixed = item.handle_point((-1, 0))
    start = view.mapFromScene(item.handle_point((1, 0)))
    finish = view.mapFromScene(fixed + QPointF(2, 0))
    QTest.mousePress(view.viewport(), Qt.MouseButton.LeftButton, pos=start)
    QTest.mouseMove(view.viewport(), finish)
    QTest.mouseRelease(view.viewport(), Qt.MouseButton.LeftButton, pos=finish)
    require(window.draft.objects[-1].size[0] == painted.minimum_size[0]
            and item.handle_point((-1, 0)) == fixed, "terrain resize clamps to the border minimum")
    window.undo.undo()
    require(window.draft.objects[-1] == painted, "terrain resize undo restores size and position")
    window.save_document(fixture)
    require(not window.dirty and not launches, "V5 terrain region saved without any Bridge subprocess")


def reopen_region(window, path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    window.open_document(path)
    document = window.draft
    assert hashlib.sha256(encode(document)).hexdigest() == digest
    assert document.region_id == "offline_region" and len(window.view.markers) == 8
    assert len(document.design.spawn_points) == 4
    assert document.design.connections[0].entry_id == "offline_region_entry"
    assert document.design.connections[0].exit_id == "offline_region_exit"
    assert document.design.environment.loading_color == "#113355"
    assert [item.properties.terrain.theme_id for item in document.objects] == ["sewer_concrete", "forest_ground"]
    assert all(window.view.textures.terrain.lookup(window.view.textures.terrain_root, item.properties.terrain)
               for item in document.objects)
    assert not window.dirty and window.close()
    return digest
