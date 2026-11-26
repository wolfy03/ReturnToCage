"""ReturnToCage Monster Editor.

    python tools/python_monster_editor/main.py [document.rtcmonster]

    python tools/python_monster_editor/main.py --smoke-report <report.json> --smoke-shots <folder>
                                               [--project <ReturnToCage> --godot <Godot 4.7.2>]

The smoke run drives the real window through the STEP 2 workflow with real key and mouse input, saves a
screenshot of each stage and a JSON report with timings. It uses its own temporary settings and drafts
folder, so it never touches the user's settings or documents. With ``--project`` and ``--godot`` it also
imports the game's monsters through the real Godot bridge.
"""

import argparse
import json
from pathlib import Path
import sys
import tempfile
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))


def configure_appearance(app):
    from PySide6.QtGui import QColor, QPalette

    app.setStyle("Fusion")
    palette = QPalette()
    roles = QPalette.ColorRole
    for role, value in (
            (roles.Window, "#252c38"), (roles.Base, "#1b202a"), (roles.AlternateBase, "#292f3b"),
            (roles.WindowText, "#e7edf5"), (roles.Text, "#e7edf5"), (roles.Button, "#303a49"),
            (roles.ButtonText, "#e7edf5"), (roles.Highlight, "#457969"), (roles.HighlightedText, "#ffffff"),
            (roles.PlaceholderText, "#9aa7ba"), (roles.ToolTipBase, "#303a49"), (roles.ToolTipText, "#e7edf5")):
        palette.setColor(role, QColor(value))
    disabled = QPalette.ColorGroup.Disabled
    for role in (roles.Text, roles.WindowText, roles.ButtonText):
        palette.setColor(disabled, role, QColor("#7b8597"))
    app.setPalette(palette)


def run_smoke(app, args):
    from PySide6.QtCore import Qt
    from PySide6.QtGui import QKeySequence
    from PySide6.QtTest import QTest

    from application.settings import Settings
    from gui.dialogs import SAVE, NewMonsterDialog
    from gui.main_window import MainWindow
    from gui.testing import ScriptedPrompts
    from rtcmonster import FAIL, read_document, set_value

    shots = args.smoke_shots
    shots.mkdir(parents=True, exist_ok=True)
    checks, timings = [], {}

    def check(name, condition, detail=""):
        checks.append({"name": name, "passed": bool(condition), "detail": "" if condition else str(detail)})
        print(("PASS " if condition else "FAIL ") + name + (f" :: {detail}" if detail and not condition else ""),
              flush=True)

    def timed(name, function):
        start = time.perf_counter()
        result = function()
        timings[name] = round((time.perf_counter() - start) * 1000, 2)
        return result

    def shot(widget, name):
        app.processEvents()
        QTest.qWait(120)
        path = shots / f"{name}.png"
        check(f"screenshot {name}", widget.grab().save(str(path)) and path.stat().st_size > 2000)

    with tempfile.TemporaryDirectory(prefix="rtc-monster-smoke-") as temporary:
        work = Path(temporary)
        drafts = work / "한글 초안 폴더"          # a non-ASCII path on purpose
        drafts.mkdir()
        prompts = ScriptedPrompts()
        start = time.perf_counter()
        window = MainWindow(Settings(work / "settings.json"), prompts)
        window.show()
        QTest.qWaitForWindowExposed(window)
        timings["launch"] = round((time.perf_counter() - start) * 1000, 2)
        check("window starts without a project", not window.project.connected and window.session is None)

        if args.project:
            ok = timed("project_switch", lambda: window.apply_project_settings({
                "project_root": str(args.project), "godot_path": str(args.godot or ""),
                "drafts_folder": str(drafts), "logs_folder": ""}))
            check("project settings are accepted", ok and window.project.connected, prompts.last_error())
        else:
            window.apply_project_settings({"project_root": "", "godot_path": "", "drafts_folder": str(drafts)})
        timed("catalog_refresh", window.refresh_catalog)

        # ---- new monster: the real dialog, real typing
        dialog = NewMonsterDialog(window, lambda monster_id: window.id_check(monster_id, False), drafts)
        dialog.show()
        QTest.qWaitForWindowExposed(dialog)
        QTest.keyClicks(dialog.monster_id.edit, "cave_spider")
        QTest.keyClicks(dialog.display_name, "Cave Spider")
        dialog.description.setPlainText("스모크 테스트용 초안")
        check("the new-monster dialog accepts a free ID",
              dialog.monster_id.acceptable and dialog.buttons.button(dialog.buttons.StandardButton.Ok).isEnabled(),
              dialog.monster_id.status.text())
        shot(dialog, "01_new_monster_dialog")
        values = dialog.values()
        dialog.close()
        prompts.expect("new_monster", values)
        timed("new_document", window.new_monster)
        check("a new monster is created and saved as a draft",
              window.session is not None and window.session.path == drafts / "cave_spider.rtcmonster"
              and window.session.path.is_file() and not window.session.dirty, prompts.last_error())
        shot(window, "02_new_monster_in_catalog")

        # ---- stats: type into the inspector, commit with Enter, undo and redo with the keyboard
        window.inspector.focus_path(("stats", "max_health"))
        editor = window.inspector.editor(("stats", "max_health"))
        QTest.keyClick(editor.spin, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
        QTest.keyClicks(editor.spin, "45")
        start = time.perf_counter()
        QTest.keyClick(editor.spin, Qt.Key.Key_Return)
        timings["single_field_edit"] = round((time.perf_counter() - start) * 1000, 2)
        check("typing a stat and pressing Enter edits the document",
              window.session.document.data["stats"]["max_health"] == 45 and window.session.dirty)
        window.inspector.focus_path(("stats", "move_speed"))
        speed = window.inspector.editor(("stats", "move_speed"))
        QTest.keyClick(speed.spin, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
        QTest.keyClicks(speed.spin, "80")
        QTest.keyClick(speed.spin, Qt.Key.Key_Tab)
        shot(window, "05_stats_edit")
        start = time.perf_counter()
        QTest.keySequence(window, QKeySequence("Ctrl+Z"))
        timings["undo"] = round((time.perf_counter() - start) * 1000, 2)
        QTest.keySequence(window, QKeySequence("Ctrl+Z"))
        check("Ctrl+Z twice restores the saved state",
              window.session.document.data["stats"]["max_health"] == 20 and not window.session.dirty)
        start = time.perf_counter()
        QTest.keySequence(window, QKeySequence("Ctrl+Y"))
        timings["redo"] = round((time.perf_counter() - start) * 1000, 2)
        QTest.keySequence(window, QKeySequence("Ctrl+Shift+Z"))
        check("Ctrl+Y and Ctrl+Shift+Z redo both edits",
              window.session.document.data["stats"]["max_health"] == 45
              and window.session.document.data["stats"]["move_speed"] == 80)

        # ---- loot
        window.inspector.focus_path(("loot",))
        QTest.mouseClick(window.loot_editor.managed, Qt.MouseButton.LeftButton)
        QTest.mouseClick(window.loot_editor.add_button, Qt.MouseButton.LeftButton)
        QTest.mouseClick(window.loot_editor.add_button, Qt.MouseButton.LeftButton)
        entries = window.session.document.data["loot"]["entries"]
        check("loot rows are added through the buttons", entries is not None and len(entries) == 2)
        timed("multi_field_edit", lambda: window.apply_edits(
            [set_value(("loot", "entries", 1, "weight"), 3),
             set_value(("loot", "entries", 1, "max_amount"), 2),
             set_value(("loot", "loot_table_id"), "cave_spider_loot")], "전리품 일괄 수정"))
        shot(window, "06_loot_edit")

        # ---- validation: make an error, see it, jump to its field
        window.apply_edits([set_value(("stats", "attack_range"), -5)], "공격 거리 변경")
        report = timed("validation", window.validate_now)
        failures = [finding for finding in window.validation_panel.findings_shown() if finding.status == FAIL]
        check("the validation panel lists the failure", any(item.code == "out_of_range" for item in failures))
        check("eleven domains are shown and unverified ones are not shown as passed",
              len(window.validation_panel.chips) == 11
              and window.validation_panel.chips["runtime"].property("status") == "NOT_EVALUATED"
              and report.status("runtime") == "NOT_EVALUATED")
        target = next(item for item in failures if item.code == "out_of_range")
        window.navigate_to(target)
        check("activating a finding focuses its field",
              window.inspector.editor(("stats", "attack_range")).spin.hasFocus() or args.offscreen)
        shot(window, "07_validation_error")
        QTest.keySequence(window, QKeySequence("Ctrl+Z"))

        # ---- save with the keyboard, then reopen in a second window
        start = time.perf_counter()
        QTest.keySequence(window, QKeySequence("Ctrl+S"))
        timings["save"] = round((time.perf_counter() - start) * 1000, 2)
        saved_path, saved_fingerprint = window.session.path, window.session.document.fingerprint
        check("Ctrl+S saves the draft", not window.session.dirty
              and read_document(saved_path)[0].fingerprint == saved_fingerprint, prompts.last_error())

        # ---- clone
        prompts.expect("clone", {"monster_id": "cave_spider_elder", "display_name": "Cave Spider Elder"})
        window.clone_monster()
        check("a clone is a new unsaved draft with its own ID and loot table",
              window.session.document.monster_id == "cave_spider_elder" and window.session.path is None
              and window.session.document.data["loot"]["loot_table_id"] == "cave_spider_elder_loot"
              and window.session.binding is None)
        prompts.expect("save_path", drafts / "cave_spider_elder.rtcmonster")
        window.save()
        check("the clone is saved next to the original and the original is unchanged",
              (drafts / "cave_spider_elder.rtcmonster").is_file()
              and read_document(saved_path)[0].fingerprint == saved_fingerprint)

        # ---- Godot: registry and imports through the real bridge
        imported = {}
        if args.project and args.godot:
            start = time.perf_counter()
            window.verify_registry()
            window.wait_for_jobs()
            timings["registry_check"] = round((time.perf_counter() - start) * 1000, 2)
            registry = window.project.registry()
            check("Godot Registry verification marks game monsters as verified",
                  registry is not None and window.catalog_panel.entries_shown()
                  and all(entry.registration == "registry_verified"
                          for entry in window.catalog_panel.entries_shown() if entry.source == "game"),
                  prompts.last_error())
            shot(window, "03_catalog_registry_verified")
            for index, (monster_id, name) in enumerate((("sewer_beetle", "04_import_sewer_beetle"),
                                                        ("frog", "04_import_frog"))):
                window.catalog_panel.select("game", monster_id)
                start = time.perf_counter()
                window.import_selected()
                window.wait_for_jobs()
                timings[f"import_{monster_id}"] = round((time.perf_counter() - start) * 1000, 2)
                ok = window.session is not None and window.session.document.monster_id == monster_id \
                    and window.session.binding is not None and window.session.path is None
                check(f"{monster_id} is imported as an unsaved draft bound to the game resources", ok,
                      prompts.last_error())
                if ok:
                    imported[monster_id] = window.session.document
                    window.inspector.focus_path(("stats", "max_health"))
                    shot(window, name)
                    check(f"{monster_id}: behaviour is read-only, stats are editable",
                          not window.session.is_editable(("behavior",)) and window.session.is_editable(("stats",)))
                    prompts.expect("save_path", drafts / f"{monster_id}_import.rtcmonster")
                    window.save()
                    check(f"{monster_id}: the imported draft saves and reopens identically",
                          read_document(drafts / f"{monster_id}_import.rtcmonster")[0] == window.session.document,
                          prompts.last_error())
        else:
            checks.append({"name": "Godot import", "passed": None, "detail": "NOT_EVALUATED: no --project/--godot"})
            print("NOT_EVALUATED Godot import (no --project/--godot)")

        # ---- unsaved changes are protected on close; then reopen in a fresh window
        window.apply_edits([set_value(("metadata", "tags"), ["cave"])], "태그 변경")
        prompts.expect("unsaved_changes", "cancel")
        check("closing with unsaved changes can be cancelled", not window.close() and window.isVisible())
        prompts.expect("unsaved_changes", SAVE)
        check("closing after choosing Save closes the window", window.close(), prompts.last_error())

        second = MainWindow(Settings(work / "settings.json"), ScriptedPrompts())
        second.show()
        QTest.qWaitForWindowExposed(second)
        check("settings are restored in a new window",
              (second.project.connected == bool(args.project)) and second.project.drafts_folder == drafts
              and str(saved_path) in second.settings.get("recent_documents"))
        start = time.perf_counter()
        opened = second.open_document(saved_path)
        timings["open_document"] = round((time.perf_counter() - start) * 1000, 2)
        check("the saved draft reopens with the same content and is clean",
              opened and second.session.document.fingerprint == saved_fingerprint and not second.session.dirty)
        start = time.perf_counter()
        second.inspector.build(second.session, second.loot_editor, second.summary)
        timings["inspector_build"] = round((time.perf_counter() - start) * 1000, 2)
        shot(second, "08_saved_and_reopened")
        drafts_listed = {entry.monster_id for entry in second.catalog_panel.entries_shown() if entry.source == "draft"}
        check("the catalog lists the saved drafts", {"cave_spider", "cave_spider_elder"} <= drafts_listed,
              drafts_listed)

        # ---- animation and collision workspace, with the project's own art when a project is connected
        if args.project:
            from PySide6.QtCore import QPoint
            from application import animation as logic
            panel, canvas = second.animation, second.animation.canvas
            timings["workspace"] = {}

            def clocked(name, action):
                start = time.perf_counter()
                value = action()
                app.processEvents()
                timings["workspace"][name] = round((time.perf_counter() - start) * 1000, 2)
                return value
            clocked("switch_to_workspace", lambda: second.workspaces.setCurrentWidget(panel))
            art = "assets/characters/enemies/sewer_beetle"
            for name, clip_id, columns in (("idle", "idle", 4), ("attack", "bite", 7)):
                panel.image_path.setText(f"{art}/{name}.png")
                QTest.mouseClick(panel.register_button, Qt.MouseButton.LeftButton)
                image_id = second.session.document.data["assets"]["images"][-1]["id"]
                for row in range(panel.image_list.count()):
                    item = panel.image_list.item(row)
                    item.setSelected(item.data(Qt.ItemDataRole.UserRole) == image_id)
                panel.clip_id.setText(clip_id)
                panel.columns.setValue(columns)
                QTest.mouseClick(panel.grid_button, Qt.MouseButton.LeftButton)
            data = lambda: second.session.document.data          # noqa: E731
            check("two clips were cut from the project's sheets with the buttons",
                  [clip["id"] for clip in data()["animations"]["clips"]] == ["idle", "bite"], panel.notice.text())
            combo = panel.roles["attack"]
            combo.setCurrentIndex(combo.findData("bite"))
            combo.activated.emit(combo.currentIndex())
            panel.hit_frame.setValue(2)
            panel.hit_frame.editingFinished.emit()
            clocked("select_frame", lambda: panel.strip.setCurrentRow(2))
            QTest.mouseClick(panel.override_frame, Qt.MouseButton.LeftButton)
            rect = list(panel.current_clip()["frames"][2]["rect"])
            history = len(second.session.history)
            clocked("move_frame", lambda: QTest.mouseClick(panel.frame_right, Qt.MouseButton.LeftButton))
            clip = panel.current_clip()
            overrides = [row["frame"] for row in data()["collision"]["hurtbox_overrides"] if row["clip"] == "bite"]
            check("moving a frame took its hurtbox set and the attack hit frame along, in one undo step",
                  list(clip["frames"][3]["rect"]) == rect and overrides == [3]
                  and data()["presentation"]["attack_hit_frame"] == 3 and panel.current_frame() == 3
                  and len(second.session.history) == history + 1, (overrides, data()["presentation"]["attack_hit_frame"]))
            clocked("undo_move_frame", second.undo)
            check("undoing the move restores the frame, the hurtbox set and the hit frame together",
                  [row["frame"] for row in data()["collision"]["hurtbox_overrides"]] == [2]
                  and data()["presentation"]["attack_hit_frame"] == 2
                  and list(panel.current_clip()["frames"][2]["rect"]) == rect)
            shot(second, "09_animation_workspace")
            panel.side.setCurrentIndex(2)
            body = panel._slots()[0]
            panel.select_shape(body)
            before = logic.shape_at(data(), body)
            centre = canvas.to_view(before["center"]).toPoint()
            fingerprint = second.session.document.fingerprint
            QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=centre)
            start = time.perf_counter()
            for step in range(1, 21):
                QTest.mouseMove(canvas, centre + QPoint(step * 2, step))
            app.processEvents()
            timings["workspace"]["drag_20_moves"] = round((time.perf_counter() - start) * 1000, 2)
            check("nothing is written to the document while a shape is dragged",
                  second.session.document.fingerprint == fingerprint and canvas.dragging)
            clocked("drag_commit", lambda: QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=centre + QPoint(40, 20)))
            moved = logic.shape_at(data(), body)
            check("releasing the mouse commits the drag as one edit",
                  moved["center"] == [before["center"][0] + 40 / canvas.zoom, before["center"][1] + 20 / canvas.zoom])
            QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=canvas.to_view(moved["center"]).toPoint())
            QTest.mouseMove(canvas, canvas.to_view(moved["center"]).toPoint() + QPoint(30, 30))
            QTest.keyClick(canvas, Qt.Key.Key_Escape)
            QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=canvas.to_view(moved["center"]).toPoint() + QPoint(30, 30))
            check("Esc cancels a drag and the document keeps its shape", logic.shape_at(data(), body) == moved
                  and not canvas.dragging)
            shot(second, "10_collision_workspace")
            QTest.mouseClick(panel.play_button, Qt.MouseButton.LeftButton)
            start = time.perf_counter()
            frames_seen = set()
            while time.perf_counter() - start < 0.5:
                app.processEvents()
                frames_seen.add(panel.current_frame())
            check("playback advances frames and the canvas is read-only meanwhile",
                  len(frames_seen) > 1 and not canvas.editable, frames_seen)
            QTest.mouseClick(panel.play_button, Qt.MouseButton.LeftButton)
            paused = panel.current_frame()
            QTest.qWait(120)
            check("pause keeps the frame and makes the canvas editable again",
                  panel.current_frame() == paused and panel.playback.state == "paused" and canvas.editable)
            QTest.mouseClick(panel.stop_button, Qt.MouseButton.LeftButton)
            from gui import frame_cache
            timings["workspace"]["frame_cache"] = frame_cache.FRAMES.stats()
            check("the frame cache is inside its byte budget",
                  frame_cache.FRAMES.bytes <= frame_cache.FRAMES.max_bytes and len(frame_cache.FRAMES) > 0)
            second.workspaces.setCurrentIndex(0)
        else:
            checks.append({"name": "animation workspace", "passed": None, "detail": "NOT_EVALUATED: no --project"})
            print("NOT_EVALUATED animation workspace (no --project)")

        # ---- responsiveness with larger documents (sizes shared with benchmark.py)
        import benchmark
        from application.session import DocumentSession
        from rtcmonster import MonsterDocument
        for size, shape in benchmark.SIZES.items():
            session = DocumentSession(MonsterDocument(benchmark.build(*shape)))
            row = {}
            start = time.perf_counter()
            second.set_session(session)
            app.processEvents()
            row["show_document"] = round((time.perf_counter() - start) * 1000, 2)
            start = time.perf_counter()
            second.apply_edits([set_value(("stats", "max_health"), 77)], "edit")
            app.processEvents()
            row["single_edit"] = round((time.perf_counter() - start) * 1000, 2)
            start = time.perf_counter()
            second.undo()
            app.processEvents()
            row["undo"] = round((time.perf_counter() - start) * 1000, 2)
            start = time.perf_counter()
            report = second.validate_now()
            app.processEvents()
            row["validate_and_list"] = round((time.perf_counter() - start) * 1000, 2)
            row["findings"] = len(report.findings)
            timings[f"document_{size}"] = row
            check(f"{size} document stays responsive (edit and undo under 250 ms)",
                  row["single_edit"] < 250 and row["undo"] < 250, row)
        second.set_session(None)
        second.close()

    passed = [row for row in checks if row["passed"]]
    failed = [row for row in checks if row["passed"] is False]
    from PySide6 import __version__ as pyside_version
    report = {"platform": app.platformName(), "device_pixel_ratio": app.devicePixelRatio(),
              "pyside6": pyside_version, "python": sys.version.split()[0],
              "project": str(args.project or ""), "godot": str(args.godot or ""),
              "counts": {"pass": len(passed), "fail": len(failed), "not_evaluated": len(checks) - len(passed) - len(failed)},
              "timings_ms": timings, "checks": checks}
    args.smoke_report.parent.mkdir(parents=True, exist_ok=True)
    args.smoke_report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"MONSTER EDITOR SMOKE {'FAIL' if failed else 'PASS'} ({len(passed)} passed, {len(failed)} failed)")
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description="ReturnToCage Monster Editor")
    parser.add_argument("document", nargs="?", type=Path)
    parser.add_argument("--smoke-report", type=Path, help="run the scripted GUI workflow and write a JSON report")
    parser.add_argument("--smoke-shots", type=Path, help="folder for the smoke run's screenshots")
    parser.add_argument("--project", type=Path, help="ReturnToCage project for the smoke run")
    parser.add_argument("--godot", type=Path, help="Godot executable for the smoke run")
    args = parser.parse_args()
    if args.smoke_report and not args.smoke_shots:
        parser.error("--smoke-report needs --smoke-shots")

    from PySide6.QtWidgets import QApplication

    app = QApplication([sys.argv[0]])
    app.setOrganizationName("ReturnToCage")
    app.setApplicationName("MonsterEditor")
    configure_appearance(app)
    args.offscreen = app.platformName() == "offscreen"
    if args.smoke_report:
        return run_smoke(app, args)

    from gui.main_window import MainWindow

    window = MainWindow()
    window.show()
    if args.document:
        window.open_document(args.document)
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
