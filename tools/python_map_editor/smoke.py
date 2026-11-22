"""Visible Qt checks shared by source and PyInstaller deployment smoke runs."""

import json
import math
import shutil
from pathlib import Path
import sys
import tempfile
import traceback

from PySide6.QtCore import QPoint, QPointF, QSettings, Qt, QTimer
from PySide6.QtGui import QAction, QWheelEvent
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QFileDialog, QDialogButtonBox, QMessageBox

from editing_smoke import benchmark, edit_map, restart_checks
from document import MapDocument, read_document, write_document
from strings import tr
from window import MainWindow


def schedule_smoke(app, report, reopen=None):
    report.parent.mkdir(parents=True, exist_ok=True)
    app.setAttribute(Qt.ApplicationAttribute.AA_DontUseNativeDialogs)
    with tempfile.TemporaryDirectory(prefix="rtc-map-smoke-") as temporary:
        folder = Path(temporary).resolve()
        settings = QSettings(str(folder / "settings.ini"), QSettings.Format.IniFormat)
        window = MainWindow(settings)
        window.show()

        def check_window():
            result = {
                "passed": False, "frozen": getattr(sys, "frozen", False),
                "platform": app.platformName(), "executable": sys.executable,
                "window_handle": int(window.winId()), "checks": [],
                "device_pixel_ratio": window.devicePixelRatioF(),
            }

            def require(condition, label):
                if not condition:
                    raise RuntimeError(label)
                result["checks"].append(label)

            def answer_message(button, before_click=None):
                def click():
                    dialog = app.activeModalWidget()
                    if not isinstance(dialog, QMessageBox):
                        app.exit(1)
                        return
                    if before_click:
                        before_click()
                    QTest.mouseClick(dialog.button(button), Qt.MouseButton.LeftButton)

                QTimer.singleShot(0, click)

            def choose_save_as(path, answer):
                def choose():
                    dialog = app.activeModalWidget()
                    if not isinstance(dialog, QFileDialog):
                        app.exit(1)
                        return
                    dialog.selectFile(str(path))
                    answer_message(answer)
                    box = dialog.findChild(QDialogButtonBox)
                    QTest.mouseClick(box.button(QDialogButtonBox.StandardButton.Save), Qt.MouseButton.LeftButton)

                QTimer.singleShot(0, choose)
                return window.save_as()

            try:
                if reopen is not None:
                    result["draft_sha256"] = restart_checks(window, reopen)
                    result["checks"].append("fresh process rebuilt the saved V2 scene")
                    result["passed"] = True
                    return
                viewport = window.view.viewport()
                require(window.isVisible() and viewport.isVisible() and window.inspector_dock.isVisible()
                        and window.structure_dock.isVisible(), "native window and editing panels visible")
                point = viewport.rect().center() + QPoint(33, 22)
                view = window.view
                before, zoom = view.mapToScene(point), view.zoom
                wheel = QWheelEvent(QPointF(point), QPointF(viewport.mapToGlobal(point)), QPoint(), QPoint(0, 120),
                                    Qt.MouseButton.NoButton, Qt.KeyboardModifier.NoModifier,
                                    Qt.ScrollPhase.NoScrollPhase, False)
                app.sendEvent(viewport, wheel)
                after = view.mapToScene(point)
                require(view.zoom > zoom and math.dist((before.x(), before.y()), (after.x(), after.y()))
                        <= 2 / view.zoom, "wheel zoom keeps the cursor over the same world point")
                scroll_before = view.horizontalScrollBar().value()
                QTest.mousePress(viewport, Qt.MouseButton.MiddleButton, pos=point)
                QTest.mouseMove(viewport, point + QPoint(65, 30))
                QTest.mouseRelease(viewport, Qt.MouseButton.MiddleButton, pos=point + QPoint(65, 30))
                require(view.horizontalScrollBar().value() < scroll_before, "middle-button pan moves the view")
                window.region_id.selectAll()
                QTest.keyClicks(window.region_id, "fixture01")
                window.width_field.setValue(1800)
                require(window.region_id.text() == "fixture01" and window.dirty
                        and view.map_scene.bounds.width() == 1800, "inspector updates draft and viewport")
                path = folder / "fixture.rtcmap"
                window.save_document(path)
                window.new_document()
                window.open_document(path)
                require(not window.dirty and window.draft.region_id == "fixture01" and window.draft.width == 1800,
                        "draft saved, reopened and clean")
                original_width = window.width()
                target_width = max(window.minimumWidth(), original_width - 48)
                if target_width == original_width:  # Small hosted desktops may start at the minimum.
                    target_width += 48
                window.resize(target_width, window.height())
                app.processEvents()
                require(window.width() == target_width and viewport.isVisible()
                        and math.isfinite(view.zoom), "window resize keeps the viewport available")
                grid_action = next(action for action in window.findChildren(QAction)
                                   if action.text() == tr("grid"))
                grid_before = view.map_scene.show_grid
                window.activateWindow()
                view.setFocus()
                QTest.keyClick(view, Qt.Key.Key_G)
                require(view.map_scene.show_grid is not grid_before and grid_action.isChecked() == view.map_scene.show_grid,
                        "grid shortcut updates the view and action")
                QTest.keyClick(view, Qt.Key.Key_G)

                other = folder / "별도 폴더"
                other.mkdir()
                target = other / "복사본.rtcmap"
                prior = MapDocument("existing")
                prior_hash = write_document(target, prior)
                require(not choose_save_as(target, QMessageBox.StandardButton.No)
                        and window.path == path and read_document(target) == (prior, prior_hash),
                        "Save As decline keeps the target and current path")

                external = MapDocument("external")
                def change_while_confirming():
                    write_document(target, external, prior_hash)
                    answer_message(QMessageBox.StandardButton.Ok)

                answer_message(QMessageBox.StandardButton.Yes, change_while_confirming)
                require(not window._save_as_path(target) and window.path == path
                        and settings.value("file/folder") == str(path.parent)
                        and read_document(target)[0] == external, "Save As rejects a change during confirmation")
                saved_as = choose_save_as(target, QMessageBox.StandardButton.Yes)
                recent = Path(settings.value("file/folder"))
                target_id = read_document(target)[0].region_id
                require(saved_as and window.path.samefile(target) and recent.samefile(other) and target_id == "fixture01",
                        "Save As explicit overwrite updates the path and recent folder "
                        f"(saved={saved_as}, path={window.path}, recent={recent}, target ID={target_id})")

                window.height_field.setValue(940)
                window.activateWindow()
                view.setFocus()
                QTest.keyClick(view, Qt.Key.Key_S, Qt.KeyboardModifier.ControlModifier)
                require(not window.dirty and read_document(target)[0].height == 940,
                        "Save shortcut updates the open revision")
                snapshot = target.read_bytes()
                window.region_id.selectAll()
                QTest.keyClicks(window.region_id, "Invalid ID")
                answer_message(QMessageBox.StandardButton.Ok)
                require(window.dirty and not window.save() and target.read_bytes() == snapshot,
                        "invalid region ID keeps the draft dirty and preserves saved bytes")

                def cancel_dirty_close():
                    dialog = app.activeModalWidget()
                    if not isinstance(dialog, QMessageBox):
                        app.exit(1)
                        return
                    cancel = next(button for button in dialog.buttons()
                                  if dialog.buttonRole(button) == QMessageBox.ButtonRole.RejectRole)
                    QTest.mouseClick(cancel, Qt.MouseButton.LeftButton)

                QTimer.singleShot(0, cancel_dirty_close)
                require(not window.close() and window.isVisible() and window.dirty,
                        "closing a dirty draft can be cancelled")
                window.open_document(target)
                fixture_dir = report.with_name(f"{report.stem}-fixture")
                fixture_dir.mkdir(exist_ok=True)
                fixture = fixture_dir / "재열기.rtcmap"
                fixture.write_bytes(edit_map(window, target, result, require))
                shutil.copyfile(target.parent / "장식.png", fixture_dir / "장식.png")
                result["fixture"] = str(fixture)
                screenshot = report.with_suffix(".png")
                require(window.grab().save(str(screenshot)), "window capture saved")
                result["screenshot"] = str(screenshot)
                view.set_grid_visible(False)
                window.output_dock.hide()
                window.close()
                reopened = MainWindow(settings)
                require(not reopened.view.map_scene.show_grid and reopened.output_dock.isHidden()
                        and settings.contains("window/docks"),
                        "grid and dock settings persisted")
                reopened.show()
                result["benchmark_ms"] = benchmark(reopened, folder)
                require(reopened.close(), "1,000-object selection, zoom, pan, save, reopen and window close")
                result["passed"] = True
            except Exception:
                result["error"] = traceback.format_exc()
            finally:
                report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
                app.exit(0 if result["passed"] else 1)

        QTimer.singleShot(200, check_window)
        return app.exec()
