"""Drive the actual Qt import, edit and publish workflow on a disposable project."""

import json
import sys
import time
import traceback

from PySide6.QtCore import QEventLoop, QPointF, QSettings, Qt, QTimer
from PySide6.QtTest import QTest
from PySide6.QtWidgets import QComboBox, QInputDialog, QMessageBox

from document import encode, read_document
from godot_bridge import file_hash
from godot_ui import GodotSettingsDialog
from region_design import RegionEnvironment
from region_wizard import create_region
from strings import tr
from window import MainWindow


def read_document_version(document):
    return json.loads(encode(document))["schema_version"]


def schedule_bridge_smoke(app, report, project, godot, include_design=False):
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
    new_scene = project / "world/adventure/v4_packaged.tscn"
    new_region = project / "data/content/regions/v4_packaged.tres"
    # Publication reviews, in order: the V6 Sewer enemy edit, then the declined and the confirmed new pair.
    review_answers = [QMessageBox.StandardButton.Yes, QMessageBox.StandardButton.No, QMessageBox.StandardButton.Yes]
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
            if widget.windowTitle() == tr("godot_publish_design"):
                if new_scene.exists() or new_region.exists():
                    errors.append("new destination written before approval")
                widget.button(review_answers.pop(0)).click()
            elif widget.windowTitle() == tr("godot_export"):
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

    def verify_design():
        from region_validation import NOT_EVALUATED, PASS, WARNING

        checkpoint("packaged V4 import requested")
        window.godot_import_design_action.trigger()
        wait_job()
        require(not errors and len(window.draft.design.region_points) == 3 and len(window.draft.design.spawn_points) == 4,
                "frozen V4 import restored Sewer markers and slots")
        entry = window.draft.design.region_points[0]
        window._move_marker(entry.id, (152, 520))
        window.environment_color.setText("#203456")
        window._save_environment()
        original = file_hash(scene), file_hash(region)
        checkpoint("packaged V4 revalidation requested")
        window.godot_validate_action.trigger()
        wait_job()
        require(not errors and window._scene_state == window._runtime_state == PASS
                and window._physics_state in (PASS, WARNING) and window._publish_state == NOT_EVALUATED
                and (file_hash(scene), file_hash(region)) == original,
                "V4 validation measured spawn physics without publishing")

        # Schema V6: place an enemy with the real tool and real input, publish it, read it back.
        checkpoint("packaged V6 enemy placement requested")
        authored = window.draft.design.enemy_spawns
        offered = {window.enemy_palette.itemText(index) for index in range(window.enemy_palette.count())}
        require(authored and {row.enemy_id for row in authored} == {"sewer_beetle"} and {"frog", "sewer_beetle"} <= offered
                and read_document_version(window.draft) == 6,
                "frozen V6 import read the Sewer enemy spawns and the registry's enemy list")
        window.tool_actions["place_enemy"].trigger()
        require(window.region_dock.isVisible() and window.enemy_palette.isVisibleTo(window) and window.enemy_palette.isEnabled(),
                "enemy placement tool shows its kind selector")
        kind = window.enemy_palette.lineEdit()
        QTest.mouseClick(kind, Qt.MouseButton.LeftButton)
        QTest.keyClick(kind, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
        QTest.keyClicks(kind, "frog")
        QTest.keyClick(kind, Qt.Key.Key_Return)
        window.view.fit_map()
        anchor = authored[0].position
        spot = window.view.mapFromScene(QPointF(anchor[0] - 96, anchor[1]))
        QTest.mouseClick(window.view.viewport(), Qt.MouseButton.LeftButton, pos=spot)
        window.tool_actions["select"].trigger()
        placed = window.draft.design.enemy_spawns[-1]
        require(len(window.draft.design.enemy_spawns) == len(authored) + 1 and placed.enemy_id == "frog"
                and placed.spawn_id == "frog_spawn_1" and placed.enabled, "real mouse and keyboard input placed a frog spawn")
        checkpoint("packaged V6 enemy publication requested")
        window.godot_export_action.trigger()
        wait_job()
        require(not errors and window._publish_state == PASS and (file_hash(scene), file_hash(region)) != original
                and file_hash(scene) == window.draft.source.scene_hash
                and file_hash(region) == window.draft.source.region_hash,
                "V6 enemy placement published to the Sewer Scene and RegionDefinition")
        enemy_path = report.parent / "하수구 Enemy 배치.rtcmap"
        window.save_document(enemy_path)
        published = window.draft
        require(read_document_version(published) == 6 and not window.dirty, "V6 enemy draft saved")
        checkpoint("packaged V6 enemy reload requested")
        window.godot_import_design_action.trigger()
        wait_job()
        reloaded = {row.spawn_id: row for row in window.draft.design.enemy_spawns}
        require(not errors and len(reloaded) == len(authored) + 1 and reloaded.get("frog_spawn_1") is not None
                and (reloaded["frog_spawn_1"].enemy_id, reloaded["frog_spawn_1"].position) == ("frog", placed.position)
                and all(reloaded[row.spawn_id].enemy_id == row.enemy_id and reloaded[row.spawn_id].position == row.position
                        for row in authored),
                "published frog and the authored beetles reloaded from Godot")
        window.open_document(enemy_path)
        require(window.draft.design.enemy_spawns == published.design.enemy_spawns and window.draft.source == published.source,
                "V6 enemy draft reopened unchanged")
        draft = create_region("v4_packaged", "Packaged fixture", 1200, 600, "flat", 4, RegionEnvironment())
        from dataclasses import replace
        from terrain_atlas import read_theme

        floor = draft.objects[0]
        atlas = read_theme(project, "forest_ground")
        draft = replace(draft, objects=(replace(floor, properties=replace(floor.properties, terrain=atlas)),))
        window._install_draft(draft)
        window.godot_export_action.trigger()
        wait_job()
        require(not errors and not (new_scene.exists() or new_region.exists()) and window._runtime_state == PASS
                and window._physics_state in (PASS, WARNING) and window._publish_state == NOT_EVALUATED,
                "declined V4 publication kept runtime and physics without writing the pair")
        checkpoint("packaged V4 pair publication requested")
        window.godot_export_action.trigger()
        wait_job()
        require(not errors and window._publish_state == PASS and window.draft.source is not None
                and file_hash(new_scene) == window.draft.source.scene_hash
                and file_hash(new_region) == window.draft.source.region_hash,
                "confirmed V4 publication produced both verified files")
        path = report.parent / "새 지역 게시.rtcmap"
        window.save_document(path)
        window.open_document(path)
        require(window.draft.source.scene_uid and window.draft.source.region_uid
                and window.draft.design == draft.design and window.draft.objects == draft.objects,
                "published V5 terrain draft reopened with both resource UIDs and atlas settings")

    def run():
        try:
            require(not window.godot_import_action.isEnabled() and not window.godot_export_action.isEnabled(),
                    "Godot actions are disabled without configuration")
            window.godot_settings_action.trigger()
            wait_job()
            require(window.godot_import_action.isEnabled() and not errors and work.is_dir() and not any(work.iterdir()),
                    "Godot settings saved without a Bridge child")
            window.godot_import_action.trigger()
            wait_job()
            require(window.draft.source is not None and len(window.draft.objects) == 5,
                    "ContentRegistry selection imported Sewer")
            if include_design:
                require((project / ".rtc-map-publish/pair-smoke/rolled-back.json").is_file()
                        and not (project / "world/adventure/rtc_recovery_smoke.tscn").exists(),
                        "frozen editor recovered an interrupted pair before import")
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
                    and window._export_state == window._runtime_state == "PASS"
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
            if include_design:
                verify_design()
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
