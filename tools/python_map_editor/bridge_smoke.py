"""Drive the actual Qt import, edit and publish workflow on a disposable project."""

import json
import sys
import time
import traceback

from PySide6.QtCore import QEventLoop, QPointF, QSettings, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QComboBox, QInputDialog, QMessageBox

from document import read_document
from godot_bridge import file_hash
from godot_ui import GodotSettingsDialog
from strings import tr
from window import MainWindow


def schedule_bridge_smoke(app, report, project, godot):
    if not (project / ".rtc-smoke-fixture").is_file():
        raise ValueError("Godot GUI smoke refuses to publish outside a prepared disposable fixture")
    report.parent.mkdir(parents=True, exist_ok=True)
    window = MainWindow(QSettings(str(report.with_suffix(".ini")), QSettings.Format.IniFormat))
    window.show()
    checks = []
    errors = []
    work = report.parent / "Godot logs"
    scene = project / "world/adventure/sewer_region.tscn"
    region = project / "data/content/regions/sewer_region.tres"
    original_scene = file_hash(scene)
    original_region = file_hash(region)
    evidence = {"passed": False, "frozen": getattr(sys, "frozen", False), "checks": checks,
                "godot": str(godot), "project": str(project), "initial_scene": original_scene,
                "definition_hash": original_region}

    def checkpoint(name):
        with report.with_suffix(".jsonl").open("a", encoding="utf-8") as stream:
            stream.write(json.dumps({"time": time.time(), "step": name}) + "\n")

    def require(condition, name):
        if not condition:
            raise AssertionError(name + (" | dialog: " + errors[-1] if errors else ""))
        checks.append(name)
        checkpoint(name)

    def modal():
        widget = app.activeModalWidget()
        if isinstance(widget, GodotSettingsDialog):
            for key, value in (("project", project), ("godot", godot), ("work", work)):
                widget.fields[key].setText(str(value))
            widget.accept()
        elif isinstance(widget, QInputDialog):
            combo = widget.findChild(QComboBox)
            index = next(index for index in range(combo.count()) if "sewer_region" in combo.itemText(index))
            combo.setCurrentIndex(index)
            widget.accept()
        elif isinstance(widget, QMessageBox):
            if widget.windowTitle() == tr("godot_export"):
                widget.button(QMessageBox.StandardButton.Yes).click()
            else:
                errors.append(widget.text())
                widget.accept()

    modal_timer = QTimer(window)
    modal_timer.timeout.connect(modal)
    modal_timer.start(50)

    def wait_job(timeout=75000):
        loop = QEventLoop()
        watchdog = QTimer()
        watchdog.setSingleShot(True)
        watchdog.timeout.connect(loop.quit)
        poll = QTimer()

        def completed():
            if window._bridge_thread is None and app.activeModalWidget() is None:
                loop.quit()

        poll.timeout.connect(completed)
        poll.start(20)
        watchdog.start(timeout)
        loop.exec()
        poll.stop()
        if not watchdog.isActive():
            raise TimeoutError("Godot Qt worker did not complete")
        watchdog.stop()

    def edit(key, text):
        field = window.object_inspector.fields[key]
        field.setFocus()
        field.selectAll()
        QTest.keyClicks(field, text)
        QTest.keyClick(field, Qt.Key.Key_Return)

    def run():
        try:
            require(not window.godot_import_action.isEnabled() and not window.godot_export_action.isEnabled(),
                    "Godot actions are disabled without configuration")
            window.godot_settings_action.trigger()
            wait_job()
            require(window.godot_import_action.isEnabled() and not errors, "Godot settings validated and saved")
            window.godot_import_action.trigger()
            wait_job()
            require(window.draft.source is not None and len(window.draft.objects) == 5,
                    "ContentRegistry selection imported Sewer")
            require(window.region_id.isReadOnly() and window.display_name.isReadOnly(), "RegionDefinition metadata is read-only")
            window.view.fit_map()
            west = next(item for item in window.draft.objects if item.position == (420, 440))
            point = window.view.mapFromScene(QPointF(*west.position))
            QTest.mouseClick(window.view.viewport(), Qt.MouseButton.LeftButton, pos=point)
            require(window.view.selected_ids() == {west.id}, "imported platform selected in the real viewport")
            edit("x", "452")
            edit("object_width", "256")
            require(window.dirty, "Inspector applied the platform edits")
            path = report.parent / "하수구 편집.rtcmap"
            window.save_document(path)
            saved, _ = read_document(path)
            require(saved.source == window.draft.source and len(saved.objects) == 5, "V3 draft saved")
            checkpoint("stage validation requested")
            window.godot_validate_action.trigger()
            wait_job()
            require(not errors and window.godot_status.text() == tr("godot_pass")
                    and file_hash(scene) == original_scene, "validation reloads and runs the stage without publication")
            checkpoint("publication requested")
            window.godot_export_action.trigger()
            wait_job()
            require(not errors and file_hash(scene) != original_scene and file_hash(region) == original_region,
                    "confirmed publish changed only the Scene")
            checkpoint("updated source fingerprint save requested")
            require(window.dirty and window.save(), "updated source fingerprint can be saved")
            window.open_document(path)
            actual = next(item for item in window.draft.objects if item.id == west.id)
            require(actual.position == (452, 440) and actual.size == (256, 22)
                    and window.draft.source.scene_hash == file_hash(scene), "V3 reload kept edits and new source hash")
            window._start_godot("inspect_project", None, lambda _: errors.append("cancel completed as success"))
            QTest.qWait(150)
            window.godot_cancel.click()
            wait_job()
            require("CANCELLED" in window.godot_status.text() and not errors, "cancel reaped the owned Godot worker")
            require(window.close(), "window closed normally")
            evidence["published_scene"] = file_hash(scene)
            evidence["passed"] = True
        except Exception:
            evidence["error"] = traceback.format_exc()
            evidence["dialogs"] = errors
        finally:
            if window._bridge_thread is not None:
                window._cancel_godot()
                try:
                    wait_job(10000)
                except TimeoutError:
                    evidence["cleanup_timeout"] = True
            modal_timer.stop()
            report.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
            app.exit(0 if evidence["passed"] else 1)

    checkpoint("smoke window started")
    QTimer.singleShot(200, run)
    return app.exec()
