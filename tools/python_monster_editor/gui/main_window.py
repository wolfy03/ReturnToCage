"""The editor window: menus, docks and the wiring between panels and the application layer.

The window owns no document logic. A document changes only through ``DocumentSession.apply``; files are
read and written only by the session; Godot runs only through ``bridge.client`` on a worker thread. Panels
are told what to show and report what the user asked for.

Workspaces live in ``self.workspaces`` (a tab widget). STEP 2 has one, the overview. A later editor is
added with ``add_workspace`` and uses the same ``session``, ``apply_edits`` and signals.
"""

import base64
from datetime import datetime
from pathlib import Path

from PySide6.QtCore import QByteArray, Qt, QThread, QTimer, Signal
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import QDockWidget, QLabel, QMainWindow, QTabWidget

from application.project import ProjectError, ProjectSession, delete_draft
from application.session import DocumentSession
from application.settings import Settings
from application.work import JobBoard, ValidationController
from bridge import client, staging
from rtcmonster import SUFFIX, DocumentConflict, DocumentError, document_revision, parse_path, set_value
from rtcmonster.catalog import CONFLICT

from . import strings
from .animation import AnimationWorkspace
from .dialogs import DISCARD, OVERWRITE, RELOAD, SAVE, SAVE_AS, Prompts
from .inspector import InspectorPanel
from .lists import CatalogPanel, ValidationPanel
from .panels import LootEditor, OverviewPanel, SummaryPanel

VALIDATION_DELAY_MS = 300


class BridgeJob(QThread):
    """Runs one bridge call off the GUI thread. The result is delivered as a signal on the GUI thread."""
    done = Signal(object, object, object)       # ticket, value, error

    def __init__(self, ticket, function):
        super().__init__()
        self.ticket, self._function = ticket, function

    def run(self):
        try:
            self.done.emit(self.ticket, self._function(self.ticket.cancel), None)
        except Exception as error:  # noqa: BLE001 - reported to the user, never swallowed
            self.done.emit(self.ticket, None, error)


class MainWindow(QMainWindow):
    document_changed = Signal(object)        # the DocumentSession, or None
    project_changed = Signal()
    validation_changed = Signal(object)      # the Report, or None
    selection_changed = Signal(tuple)        # field path last navigated to

    def __init__(self, settings=None, prompts=None):
        super().__init__()
        self.settings = settings or Settings()
        self.prompts = prompts or Prompts(self)
        self.project = ProjectSession()
        self.session = None
        self.validation = ValidationController()
        self.jobs = JobBoard()
        self._threads = []
        self._import_support = {}
        self._engine_version = ""
        self._last_message = ""
        self.last_stage = None
        self.setObjectName("MonsterEditorMainWindow")
        self.resize(1360, 860)

        self.workspaces = QTabWidget()
        self.overview = OverviewPanel()
        self.workspaces.addTab(self.overview, "Monster Overview")
        self.animation = AnimationWorkspace()
        self.animation.prompts = self.prompts
        self.workspaces.addTab(self.animation, strings.ANIMATION["title"])
        self.setCentralWidget(self.workspaces)
        self.catalog_panel, self.inspector = CatalogPanel(), InspectorPanel()
        self.validation_panel, self.loot_editor, self.summary = ValidationPanel(), LootEditor(), SummaryPanel()
        self.docks = {}
        for key, title, widget, area in (
                ("catalog", "Monster Catalog", self.catalog_panel, Qt.DockWidgetArea.LeftDockWidgetArea),
                ("inspector", "Inspector", self.inspector, Qt.DockWidgetArea.RightDockWidgetArea),
                ("validation", "Validation", self.validation_panel, Qt.DockWidgetArea.BottomDockWidgetArea)):
            dock = QDockWidget(title, self)
            dock.setObjectName(f"dock_{key}")
            dock.setWidget(widget)
            self.addDockWidget(area, dock)
            self.docks[key] = dock
        self.resizeDocks([self.docks["catalog"], self.docks["inspector"]], [300, 420], Qt.Orientation.Horizontal)
        self.resizeDocks([self.docks["validation"]], [220], Qt.Orientation.Vertical)

        self._project_label, self._job_label = QLabel(), QLabel()
        self.statusBar().addPermanentWidget(self._job_label)
        self.statusBar().addPermanentWidget(self._project_label)
        self._validation_timer = QTimer(self)
        self._validation_timer.setSingleShot(True)
        self._validation_timer.setInterval(VALIDATION_DELAY_MS)
        self._validation_timer.timeout.connect(self.validate_now)

        self._build_actions()
        self.inspector.edit_requested.connect(self._on_field_edit)
        self.loot_editor.edits_requested.connect(self.apply_edits)
        self.animation.edits_requested.connect(self.apply_edits)
        self.animation.browse_requested.connect(self._browse_image)
        self.catalog_panel.entry_activated.connect(self.activate_entry)
        self.catalog_panel.selection_changed.connect(lambda _entry: self._update_actions())
        self.validation_panel.finding_activated.connect(self.navigate_to)
        self._default_state = self.saveState()
        self._restore_settings()
        self._show_session()

    # ------------------------------------------------------------------------------------------ actions
    def _action(self, text, slot, shortcut=None, shortcuts=None):
        action = QAction(text, self)
        action.triggered.connect(lambda _checked=False: slot())
        if shortcut:
            action.setShortcut(QKeySequence(shortcut))
        if shortcuts:
            action.setShortcuts([QKeySequence(item) for item in shortcuts])
        action.setShortcutContext(Qt.ShortcutContext.WindowShortcut)
        return action

    def _build_actions(self):
        a = self.actions_by_name = {
            "new": self._action("새 몬스터…", self.new_monster, "Ctrl+N"),
            "open": self._action("열기…", self.open_document, "Ctrl+O"),
            "save": self._action("저장", self.save, "Ctrl+S"),
            "save_as": self._action("다른 이름으로 저장…", self.save_as, "Ctrl+Shift+S"),
            "close": self._action("문서 닫기", self.close_document, "Ctrl+W"),
            "settings": self._action("프로젝트 설정…", self.edit_project_settings),
            "quit": self._action("종료", self.close, "Ctrl+Q"),
            "undo": self._action("실행 취소", self.undo, "Ctrl+Z"),
            "redo": self._action("다시 실행", self.redo, shortcuts=["Ctrl+Y", "Ctrl+Shift+Z"]),
            "clone": self._action("몬스터 복제…", self.clone_monster),
            "delete": self._action("초안 삭제…", self.delete_selected_draft),
            "validate": self._action("현재 문서 검증", self.validate_now, "F6"),
            "refresh": self._action("프로젝트 카탈로그 새로고침", self.refresh_catalog, "F5"),
            "registry": self._action("Godot Registry 검증 (게임 몬스터 목록 가져오기)", self.verify_registry),
            "import": self._action("선택 몬스터 가져오기", self.import_selected),
            "stage": self._action("표현 리소스 Staging 검증 (프로젝트 사본)", self.stage_presentation),
            "godot_check": self._action("Godot 연결 및 버전 검사", self.check_godot),
            "cancel_job": self._action("진행 중인 Godot 작업 취소", self.cancel_jobs),
            "reset_layout": self._action("기본 레이아웃 복원", self.reset_layout),
        }
        bar = self.menuBar()
        menu = bar.addMenu("파일(&F)")
        menu.addActions([a["new"], a["open"]])
        self.recent_menu = menu.addMenu("최근 문서")
        menu.addSeparator()
        menu.addActions([a["save"], a["save_as"], a["close"]])
        menu.addSeparator()
        menu.addAction(a["settings"])
        menu.addSeparator()
        menu.addAction(a["quit"])
        menu = bar.addMenu("편집(&E)")
        menu.addActions([a["undo"], a["redo"]])
        menu.addSeparator()
        menu.addActions([a["clone"], a["delete"]])
        menu = bar.addMenu("보기(&V)")
        for dock in self.docks.values():
            menu.addAction(dock.toggleViewAction())
        menu.addSeparator()
        menu.addAction(a["reset_layout"])
        menu = bar.addMenu("검증(&A)")
        menu.addActions([a["validate"], a["refresh"], a["registry"]])
        menu = bar.addMenu("Godot(&G)")
        menu.addActions([a["registry"], a["import"], a["stage"], a["godot_check"]])
        menu.addSeparator()
        menu.addAction(a["cancel_job"])
        later = menu.addAction("게임에 게시 (후속 단계에서 지원)")
        later.setEnabled(False)
        toolbar = self.addToolBar("기본")
        toolbar.setObjectName("main_toolbar")
        toolbar.addActions([a["new"], a["open"], a["save"], a["undo"], a["redo"], a["validate"], a["refresh"],
                            a["import"]])
        self._rebuild_recent()

    def _rebuild_recent(self):
        self.recent_menu.clear()
        for path in self.settings.get("recent_documents"):
            self.recent_menu.addAction(self._action(path, lambda path=path: self.open_document(Path(path))))
        self.recent_menu.setEnabled(bool(self.settings.get("recent_documents")))

    def _update_actions(self):
        a, session = self.actions_by_name, self.session
        entry = self.catalog_panel.selected_entry()
        a["save"].setEnabled(session is not None and session.dirty)
        for name in ("save_as", "close", "validate", "clone"):
            a[name].setEnabled(session is not None)
        a["undo"].setEnabled(session is not None and session.can_undo)
        a["redo"].setEnabled(session is not None and session.can_redo)
        a["undo"].setText("실행 취소" + (f": {session.history.undo_label}" if session and session.history.undo_label else ""))
        a["redo"].setText("다시 실행" + (f": {session.history.redo_label}" if session and session.history.redo_label else ""))
        a["delete"].setEnabled(entry is not None and entry.source == "draft")
        godot_ready = self.project.connected and self.project.godot is not None and not self.jobs.active
        a["registry"].setEnabled(godot_ready)
        a["godot_check"].setEnabled(godot_ready)
        a["import"].setEnabled(godot_ready and entry is not None and entry.source == "game")
        a["stage"].setEnabled(godot_ready and session is not None and bool(session.document.data["animations"]["clips"]))
        a["cancel_job"].setEnabled(bool(self.jobs.active))
        a["refresh"].setEnabled(True)

    def status(self, text, timeout=8000):
        self._last_message = text
        self.statusBar().showMessage(text, timeout)

    # ----------------------------------------------------------------------------------------- settings
    def _restore_settings(self):
        if self.settings.recovered:
            self.status("설정 파일이 손상되어 기본값으로 복구했습니다.")
        for key, restore in (("window_geometry", self.restoreGeometry), ("window_state", self.restoreState)):
            value = self.settings.get(key)
            if value:
                try:
                    restore(QByteArray(base64.b64decode(value)))
                except (ValueError, TypeError):
                    pass
        self.catalog_panel.search.setText(self.settings.get("catalog_search"))
        index = self.catalog_panel.filter.findData(self.settings.get("catalog_filter"))
        self.catalog_panel.filter.setCurrentIndex(max(0, index))
        try:
            self.project.configure(self.settings.get("project_root"), self.settings.get("godot_path"),
                                   self.settings.get("drafts_folder"))
        except ProjectError as error:
            # A remembered path that no longer works must not stop the editor from starting.
            self.status(f"저장된 프로젝트 설정을 사용할 수 없습니다: {error}")
        self._project_updated()

    def _store_settings(self):
        self.settings.set("window_geometry", base64.b64encode(bytes(self.saveGeometry())).decode("ascii"))
        self.settings.set("window_state", base64.b64encode(bytes(self.saveState())).decode("ascii"))
        self.settings.set("catalog_search", self.catalog_panel.search.text())
        self.settings.set("catalog_filter", self.catalog_panel.filter.currentData())
        try:
            self.settings.save()
        except OSError as error:
            self.status(f"설정을 저장하지 못했습니다: {error}")

    def reset_layout(self):
        self.restoreState(self._default_state)
        for dock in self.docks.values():
            dock.show()

    def edit_project_settings(self):
        values = self.prompts.project_settings({key: self.settings.get(key) for key in (
            "project_root", "godot_path", "drafts_folder", "logs_folder")})
        if values is not None:
            return self.apply_project_settings(values)
        return False

    def apply_project_settings(self, values):
        """Switch project. Refused (and nothing changes) when a path is unusable or the user cancels."""
        changing_project = (values.get("project_root") or "") != (self.settings.get("project_root") or "")
        if changing_project and self.session is not None and not self._maybe_save():
            return False
        try:
            self.project.configure(values.get("project_root"), values.get("godot_path"), values.get("drafts_folder"))
        except ProjectError as error:
            self.prompts.error("프로젝트 설정", f"{error}\n({error.code})")
            return False
        for key in ("project_root", "godot_path", "drafts_folder", "logs_folder"):
            self.settings.set(key, values.get(key) or "")
        if values.get("project_root"):
            self.settings.remember("recent_projects", values["project_root"])
        self._store_settings()
        self._project_updated()
        return True

    def _project_updated(self):
        """Everything that was known about the previous project is dropped."""
        self.jobs.cancel_all()
        self._import_support = {}
        self._engine_version = ""
        self.loot_editor.set_items(self.project.content_ids("items"))
        self.animation.set_project_root(self.project.root)
        self.refresh_catalog()
        if self.session is not None:
            self._schedule_validation()
        self._show_session()
        self.project_changed.emit()

    # ------------------------------------------------------------------------------------------ catalog
    def refresh_catalog(self):
        catalog = self.project.catalog()
        self.catalog_panel.set_catalog(catalog, self._import_support, self.project.connected)
        registry = self.project.registry()
        text = "프로젝트: " + (str(self.project.root) if self.project.connected else "미연결")
        if self.project.connected:
            text += "  ·  Registry: " + (f"확인됨 (Godot {registry.engine_version})" if registry else "미확인")
        self._project_label.setText(text)
        self._update_actions()
        return catalog

    def id_check(self, monster_id, for_new_document=True):
        """ID status for a new or cloned monster, aware of the document being edited."""
        return self.project.id_status(
            monster_id, None,
            self.session.document if (for_new_document and self.session is not None) else None,
            self.session.path if self.session is not None else None)

    def activate_entry(self, entry):
        if entry.source == "draft":
            self.open_document(Path(entry.path))
        elif self.project.godot is None:
            self.prompts.info("가져오기", "게임 몬스터를 가져오려면 프로젝트 설정에서 Godot 실행 파일을 지정하세요.")
        else:
            self.import_monster(entry.monster_id)

    # ----------------------------------------------------------------------------------------- document
    def add_workspace(self, widget, title):
        """Extension point for later steps: another editor of the same document session."""
        return self.workspaces.addTab(widget, title)

    def set_session(self, session):
        """Make ``session`` the open document (or close with None). History starts with the session."""
        self._validation_timer.stop()
        self.session = session
        self.validation.clear()
        if session is not None:
            session.subscribe(self._on_session_changed)
        self.inspector.build(session, self.loot_editor, self.summary)
        self.loot_editor.set_session(session)
        self.summary.set_session(session)
        self.animation.set_session(session, self.project.root)
        self.document_changed.emit(session)
        if session is not None:
            self.validate_now()
        else:
            self.validation_panel.show_report(None, "none")
            self.validation_changed.emit(None)
        self._show_session()

    def _on_session_changed(self, session, _reason):
        if session is not self.session:
            return
        self.inspector.refresh()
        self.loot_editor.refresh()
        self.summary.refresh()
        self.animation.refresh()
        self._show_validation()
        self._schedule_validation()
        self._show_session()
        self.document_changed.emit(session)

    def _binding_state(self):
        session, report = self.session, self.validation.report
        if session is None or session.binding is None:
            return "none"
        if report is None or not self.project.connected:
            return "unknown"
        codes = {finding.code for finding in report.findings}
        return "missing" if "source_missing" in codes else "modified" if "source_changed" in codes else \
            "unknown" if "source_files_unchecked" in codes else "unchanged"

    def _show_session(self):
        session = self.session
        if session is None:
            self.setWindowTitle(strings.APP_NAME)
        else:
            data = session.document.data
            self.setWindowTitle(f"{'*' if session.dirty else ''}{data['metadata']['display_name']} "
                                f"[{data['monster_id']}] — {strings.APP_NAME}")
        report, state = self.validation.report, self._validation_state()
        if report is None:
            text = "검증 전"
        else:
            text = f"정적 검증: {strings.STATUS[report.static_status]}" + (" (오래됨)" if state == "stale" else "") \
                + f" · 전체: {strings.STATUS[report.overall]}"
        self.overview.show_session(session, self.project.root, self._binding_state(), text)
        self._update_actions()

    def _on_field_edit(self, path, value):
        self.apply_edits([set_value(path, value)], strings.field_label(".".join(str(key) for key in path)) + " 변경")

    def apply_edits(self, edits, label=""):
        """The one way a panel changes the document. A rejected edit changes nothing and is reported."""
        if self.session is None:
            return False
        try:
            changed = self.session.apply(*edits, label=label)
        except DocumentError as error:
            self.status(f"입력을 적용하지 않았습니다: {error}")
            self.inspector.refresh()         # put the field back; every other field keeps its value
            self.loot_editor.refresh(force=True)
            self.animation.refresh()
            return False
        return changed

    def _browse_image(self):
        """Pick a PNG inside the project for the animation workspace; a file elsewhere is refused there."""
        root = self.project.root
        if root is None:
            self.status("프로젝트를 먼저 연결하세요.")
            return
        chosen = self.prompts.image_path(root)
        if chosen is None:
            return
        try:
            relative = Path(chosen).resolve().relative_to(Path(root).resolve()).as_posix()
        except ValueError:
            self.status("프로젝트 폴더 안의 PNG만 등록할 수 있습니다.")
            return
        self.animation.set_image_path(relative)

    def undo(self):
        if self.session is not None and self.session.undo():
            self.status("실행 취소")

    def redo(self):
        if self.session is not None and self.session.redo():
            self.status("다시 실행")

    def _maybe_save(self):
        """Ask about unsaved changes. True = go on, False = the user cancelled or saving failed."""
        if self.session is None or not self.session.dirty:
            return True
        answer = self.prompts.unsaved_changes(self.session.document.data["metadata"]["display_name"])
        if answer == SAVE:
            return self.save()
        return answer == DISCARD

    def new_monster(self):
        if not self._maybe_save():
            return False
        values = self.prompts.new_monster(lambda monster_id: self.id_check(monster_id, False),
                                          self.project.drafts_folder)
        if values is None:
            return False
        if self.id_check(values["monster_id"], False).status == CONFLICT:
            self.prompts.error("새 몬스터", "이 Monster ID는 이미 사용 중입니다.")
            return False
        fields = {"metadata.rank": values["rank"]}
        if values["category"]:
            fields["metadata.category"] = values["category"]
        if values["description"]:
            fields["metadata.description"] = values["description"]
        try:
            session = DocumentSession.create(values["monster_id"], values["display_name"], **fields)
        except DocumentError as error:
            self.prompts.error("새 몬스터", str(error))
            return False
        self.set_session(session)
        if values["folder"]:
            self._save_to(Path(values["folder"]) / f"{values['monster_id']}{SUFFIX}")
        if values["id_state"] == "unknown":
            self.status("프로젝트가 연결되지 않아 Monster ID 중복을 확인하지 못했습니다.")
        return True

    def open_document(self, path=None):
        if not self._maybe_save():
            return False
        if path is None:
            path = self.prompts.open_path(self.project.drafts_folder
                                          or (self.session.path.parent if self.session and self.session.path else ""))
            if path is None:
                return False
        try:
            session = DocumentSession.open(path)
        except (OSError, DocumentError) as error:
            # The document that was open stays open, with its history.
            self.prompts.error("문서 열기", f"{path}\n\n{error}")
            self.settings.forget("recent_documents", path)
            self._rebuild_recent()
            return False
        self.set_session(session)
        self._remember(path)
        self.status(f"열었습니다: {path}")
        return True

    def _remember(self, path):
        self.settings.remember("recent_documents", Path(path))
        self._store_settings()
        self._rebuild_recent()

    def save(self):
        if self.session is None:
            return False
        if self.session.path is None:
            return self.save_as()
        try:
            self.session.save()
        except DocumentConflict:
            return self._resolve_conflict()
        except (OSError, DocumentError) as error:
            self.prompts.error("저장", f"저장하지 못했습니다. 파일은 그대로입니다.\n\n{error}")
            return False
        self._saved()
        return True

    def save_as(self):
        if self.session is None:
            return False
        folder = self.session.path.parent if self.session.path else (self.project.drafts_folder or Path.home())
        target = self.prompts.save_path(Path(folder) / f"{self.session.document.monster_id}{SUFFIX}")
        return target is not None and self._save_to(target)

    def _save_to(self, target):
        """Save under another name. An existing file is replaced only after an explicit confirmation of the
        revision that is there now; if it changes before the write, nothing is written."""
        try:
            approved = document_revision(target)
        except (OSError, DocumentError) as error:
            self.prompts.error("저장", str(error))
            return False
        if approved is not None and not self.prompts.confirm(
                "덮어쓰기", f"{target}\n\n이미 있는 파일입니다. 이 파일을 현재 문서로 바꿀까요?"):
            return False
        try:
            self.session.save_as(target, approved)
        except DocumentConflict as error:
            self.prompts.error("저장", f"대상 파일이 확인한 뒤에 바뀌어 저장하지 않았습니다.\n\n{error}")
            return False
        except (OSError, DocumentError) as error:
            self.prompts.error("저장", f"저장하지 못했습니다.\n\n{error}")
            return False
        self._saved()
        return True

    def _saved(self):
        self._remember(self.session.path)
        self.refresh_catalog()
        self.status(f"저장했습니다: {self.session.path}")

    def _resolve_conflict(self):
        answer = self.prompts.conflict(self.session.path)
        if answer == RELOAD:
            try:
                self.session.reload()
            except (OSError, DocumentError) as error:
                self.prompts.error("다시 열기", str(error))
                return False
            self.inspector.build(self.session, self.loot_editor, self.summary)
            self.status("디스크의 문서를 다시 열었습니다.")
            return False
        if answer == SAVE_AS:
            return self.save_as()
        if answer == OVERWRITE:
            # Still not an unconditional write: the revision on disk right now is the one being replaced.
            return self._save_to(self.session.path)
        return False

    def close_document(self):
        if self.session is not None and self._maybe_save():
            self.set_session(None)
            return True
        return False

    def clone_monster(self):
        if self.session is None:
            return False
        source = self.session.document
        values = self.prompts.clone(source, self.id_check)
        if values is None:
            return False
        if self.id_check(values["monster_id"]).status == CONFLICT:
            self.prompts.error("몬스터 복제", "이 Monster ID는 이미 사용 중입니다.")
            return False
        if not self._maybe_save():
            return False
        loot_id = None
        if source.data["loot"]["entries"] is not None:
            # The copy owns its rows, so it needs a loot table ID nobody else uses.
            taken = set(self.project.content_ids("loot") or ())
            taken |= {entry.monster_id + "_loot" for entry in self.project.catalog().entries}
            loot_id, index = f"{values['monster_id']}_loot"[:64], 2
            while loot_id in taken:
                loot_id, index = f"{values['monster_id'][:56]}_loot_{index}", index + 1
        try:
            session = DocumentSession.clone_of(source, values["monster_id"], values["display_name"] or None, loot_id)
        except DocumentError as error:
            self.prompts.error("몬스터 복제", str(error))
            return False
        self.set_session(session)
        self.status("복제본을 만들었습니다. 아직 저장되지 않았습니다.")
        return True

    def delete_selected_draft(self):
        entry = self.catalog_panel.selected_entry()
        if entry is None or entry.source != "draft":
            return False
        if not self.prompts.confirm("초안 삭제", f"이 초안 파일을 삭제합니다. 되돌릴 수 없습니다.\n\n"
                                               f"파일: {entry.path}\nMonster ID: {entry.monster_id}\n\n"
                                               "게임 콘텐츠는 삭제되지 않습니다."):
            return False
        try:
            delete_draft(entry.path, entry.sha256)
        except (OSError, DocumentError) as error:
            self.prompts.error("초안 삭제", str(error))
            return False
        if self.session is not None and self.session.path is not None and Path(entry.path) == self.session.path:
            self.set_session(None)
        self.settings.forget("recent_documents", entry.path)
        self._rebuild_recent()
        self.refresh_catalog()
        self.status(f"초안을 삭제했습니다: {entry.path}")
        return True

    # --------------------------------------------------------------------------------------- validation
    def _validation_state(self):
        return self.validation.state(self.session, self.project.root)

    def _schedule_validation(self):
        """Edits are validated after a short pause; several edits in a row cost one run."""
        self._validation_timer.start()

    def _show_validation(self):
        self.validation_panel.show_report(self.validation.report, self._validation_state())

    def validate_now(self):
        self._validation_timer.stop()
        if self.session is None:
            return None
        report = self.validation.run(self.session, self.project.root)
        self._show_validation()
        self._show_session()
        self.validation_changed.emit(report)
        return report

    def navigate_to(self, finding):
        """Show the field a finding is about. An unknown or unsupported path is reported, never fatal."""
        if finding is None or not finding.path or self.session is None:
            self.status("이 항목은 특정 필드를 가리키지 않습니다.")
            return False
        try:
            path = parse_path(finding.path)
            self.session.document.schema.field(self.session.document.data, path)
        except (DocumentError, ValueError, KeyError, IndexError):
            path = parse_path(finding.path.split("[")[0]) if finding.path else ()
        self.docks["inspector"].show()
        self.docks["inspector"].raise_()
        shown = self.inspector.focus_path(path)
        self.selection_changed.emit(tuple(path))
        self.status(f"{finding.code}: {finding.path}" if shown else f"이 위치의 편집기는 아직 없습니다: {finding.path}")
        return shown

    # -------------------------------------------------------------------------------------------- Godot
    def _start_job(self, kind, function, on_result, same_document=False, label=""):
        if self.project.root is None or self.project.godot is None:
            self.prompts.info("Godot", "프로젝트 설정에서 프로젝트 폴더와 Godot 실행 파일을 지정하세요.")
            return None
        ticket = self.jobs.issue(kind, self.project.generation, self.session)
        job = BridgeJob(ticket, function)
        job.done.connect(lambda ticket, value, error: self._job_done(job, ticket, value, error, on_result,
                                                                   same_document))
        self._threads.append(job)
        self._job_label.setText(f"Godot 작업 중: {label or kind}")
        job.start()
        self._update_actions()
        return ticket

    def _job_done(self, job, ticket, value, error, on_result, same_document):
        job.wait()
        if job in self._threads:
            self._threads.remove(job)
        valid = self.jobs.finish(ticket, self.project.generation, self.session, same_document)
        self._job_label.setText("" if not self.jobs.active else self._job_label.text())
        self._update_actions()
        if isinstance(error, client.BridgeError) and error.code == client.CANCELLED:
            self.status("Godot 작업을 취소했습니다.")
        elif not valid:
            # The project or the document moved on while Godot was running.
            self.status(f"늦게 도착한 결과를 버렸습니다 ({ticket.kind}): 요청 이후 프로젝트나 문서가 바뀌었습니다.")
        elif error is not None:
            code = getattr(error, "code", type(error).__name__)
            kept = self._keep_engine_log(ticket.kind, code, getattr(error, "log", ""))
            self.prompts.error("Godot", f"{error}\n({code})" + (f"\n엔진 로그: {kept}" if kept else ""))
        else:
            on_result(value)

    def _keep_engine_log(self, kind, code, log):
        """Write a failed call's engine output to the logs folder, if one is configured. Returns the path."""
        folder = self.settings.get("logs_folder")
        if not folder or not log:
            return None
        try:
            folder = Path(folder)
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / f"godot-{datetime.now():%Y%m%d-%H%M%S-%f}-{kind}-{code}.log"
            path.write_text(log, encoding="utf-8", errors="replace")
            return path
        except OSError:
            return None        # a log that cannot be kept must not hide the error it belongs to

    def cancel_jobs(self):
        self.jobs.cancel_all()

    def check_godot(self):
        godot, root = self.project.godot, self.project.root

        def done(version):
            self._engine_version = version
            self.prompts.info("Godot", f"Godot {version}\n프로젝트가 요구하는 버전과 일치합니다.")
        return self._start_job("check_godot", lambda cancel: client.check_version(godot, root, cancel), done,
                               label="버전 검사")

    def verify_registry(self):
        godot, root, generation = self.project.godot, self.project.root, self.project.generation

        def work(cancel):
            client.check_version(godot, root, cancel)
            return client.inspect_monsters(godot, root, cancel)

        def done(response):
            rows = response.data["monsters"]
            if self.project.accept_registry([row["monster_id"] for row in rows], generation,
                                            response.environment["godot_version"]):
                self._import_support = {row["monster_id"]: row["import_support"] for row in rows}
                self.refresh_catalog()
                self.status(f"Godot Registry에서 몬스터 {len(rows)}개를 확인했습니다.")
        return self._start_job("inspect_monsters", work, done, label="Registry 검증")

    def import_selected(self):
        entry = self.catalog_panel.selected_entry()
        if entry is not None and entry.source == "game":
            return self.import_monster(entry.monster_id)
        return None

    def import_monster(self, monster_id):
        """Read a game monster into a new, unsaved draft. The game's files are only read."""
        if not self._maybe_save():
            return None
        godot, root = self.project.godot, self.project.root

        def work(cancel):
            client.check_version(godot, root, cancel)
            return client.import_monster(godot, root, monster_id, cancel)

        def done(value):
            result, _response = value
            self.set_session(DocumentSession(result.document))
            text = f"{monster_id}: {strings.IMPORT_STATUS[result.status]}"
            if result.notes:
                text += f" · 표현하지 못한 항목 {len(result.notes)}건 (요약 탭의 Source Binding 참조)"
            self.status(text + " · 초안은 아직 저장되지 않았습니다.", 15000)
        return self._start_job("import_monster", work, done, same_document=True, label=f"{monster_id} 가져오기")

    def stage_presentation(self, carrier=""):
        """Build the open document's SpriteFrames and animation profile in a copy of the project and compare
        what Godot built with the document. The project itself is not written; the copy is removed afterwards."""
        if self.session is None:
            return None
        godot, root, document = self.project.godot, self.project.root, self.session.document

        def work(cancel):
            result = staging.stage_presentation(godot, root, document, carrier=carrier, cancel=cancel)
            staging.remove_staging_copy(result.staging_root)
            return result

        def done(result):
            self.last_stage = result
            if result.passed:
                self.status(strings.STAGE["passed"].format(clips=len(result.profile.get("animations", {})),
                                                           carrier=result.attach.get("carrier", "–")), 15000)
            else:
                shown = list(result.differences[:12])
                if len(result.differences) > 12:
                    shown.append(f"… 외 {len(result.differences) - 12}건")
                self.prompts.error("Staging", strings.STAGE["differs"] + "\n\n" + "\n".join(shown))
        return self._start_job("stage_monster", work, done, same_document=True, label="표현 리소스 Staging")

    def wait_for_jobs(self, timeout_ms=200000):
        """Block until background jobs have delivered their results. For tests and for closing."""
        from PySide6.QtCore import QCoreApplication, QElapsedTimer
        timer = QElapsedTimer()
        timer.start()
        while (self._threads or self.jobs.active) and timer.elapsed() < timeout_ms:
            QCoreApplication.processEvents()
            QThread.msleep(10)
        return not self._threads

    # -------------------------------------------------------------------------------------------- close
    def closeEvent(self, event):
        if not self._maybe_save():
            event.ignore()
            return
        self.jobs.cancel_all()          # only processes this editor started are ever stopped
        self.wait_for_jobs(20000)
        self._store_settings()
        event.accept()
