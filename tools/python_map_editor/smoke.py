"""Visible Qt checks shared by source and PyInstaller deployment smoke runs."""

import json
import math
import sys
import tempfile
import traceback

from PySide6.QtCore import QPoint, QPointF, QSettings, Qt, QTimer
from PySide6.QtGui import QWheelEvent
from PySide6.QtTest import QTest

from window import MainWindow


def schedule_smoke(app, report):
    report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rtc-map-smoke-") as temporary:
        from pathlib import Path

        folder = Path(temporary)
        settings = QSettings(str(folder / "settings.ini"), QSettings.Format.IniFormat)
        window = MainWindow(settings)
        window.show()

        def check_window():
            result = {
                "passed": False, "frozen": getattr(sys, "frozen", False),
                "platform": app.platformName(), "executable": sys.executable,
                "window_handle": int(window.winId()), "checks": [],
            }

            def require(condition, label):
                if not condition:
                    raise RuntimeError(label)
                result["checks"].append(label)

            try:
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
                screenshot = report.with_suffix(".png")
                require(window.grab().save(str(screenshot)), "window capture saved")
                result["screenshot"] = str(screenshot)
                view.set_grid_visible(False)
                window.close()
                reopened = MainWindow(settings)
                require(not reopened.view.map_scene.show_grid and settings.contains("window/docks"),
                        "grid and dock settings persisted")
                result["passed"] = True
            except Exception:
                result["error"] = traceback.format_exc()
            finally:
                report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
                app.exit(0 if result["passed"] else 1)

        QTimer.singleShot(200, check_window)
        return app.exec()
