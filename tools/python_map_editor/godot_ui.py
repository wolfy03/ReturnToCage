"""Qt integration for the headless Godot bridge."""

from dataclasses import replace
from pathlib import Path
import tempfile
import traceback
from threading import Event

from PySide6.QtCore import QThread, QTimer, Qt, Signal, Slot
from PySide6.QtWidgets import (
    QDialog, QDialogButtonBox, QFileDialog, QFormLayout, QHBoxLayout, QInputDialog,
    QLabel, QLineEdit, QMessageBox, QPushButton, QToolBar, QWidget,
)

from godot_bridge import BridgeError, GodotSession, ProjectSettings
from publish_region import publish_copy, publish_scene, recover_project
from strings import tr


def run_operation(settings, cancel, operation, payload, progress):
    if operation in ("export_region", "export_as", "validate_export") and payload[0].design is not None:
        raise BridgeError("UNSUPPORTED_NODE", tr("design_export_unsupported"))
    session = None
    try:
        session = GodotSession(settings, cancel, progress)
        recovered = recover_project(session.settings.project)
        with session:
            if operation == "inspect_project":
                data = session.call(operation)
                return {**data, "version": session.version, "settings": session.settings,
                        "recovered": recovered, "evidence": session.evidence}
            if operation == "import_region":
                document, result = session.import_region(payload)
                return {"document": document, "result": result, "evidence": session.evidence}
            document, destination = payload
            updated, result = session.stage_export(document)
            target = None
            if operation == "export_region":
                progress(tr("godot_publishing"))
                target = publish_scene(session, document.source, result)
            elif operation == "export_as":
                progress(tr("godot_publishing"))
                target = publish_copy(session, destination, document.source, result)
            return {"document": updated, "result": result, "evidence": session.evidence, "target": target}
    except BridgeError as error:
        if session is not None:
            error.evidence = session.evidence
        raise
    except (OSError, ValueError, TypeError, KeyError, RuntimeError) as error:
        if session is not None:
            (session.evidence / "bridge-exception.log").write_text(traceback.format_exc(), encoding="utf-8")
        raise BridgeError("EXPORT_FAILED", str(error), session.evidence if session else None) from error


class BridgeWorker(QThread):
    progress = Signal(str)

    def __init__(self, parent, settings, operation, payload):
        super().__init__(parent)
        self.settings = settings
        self.operation = operation
        self.payload = payload
        self.cancel = Event()
        self.result = None
        self.error = None

    def run(self):
        try:
            self.result = run_operation(self.settings, self.cancel, self.operation, self.payload, self.progress.emit)
        except BridgeError as error:
            self.error = error
        except Exception as error:
            self.error = BridgeError("EXPORT_FAILED", str(error))


class GodotSettingsDialog(QDialog):
    def __init__(self, parent):
        super().__init__(parent)
        self.setWindowTitle(tr("godot_settings"))
        self.resize(640, 220)
        form = QFormLayout(self)
        self.fields = {}
        file_selectors = (
            ("project", "godot_project", QFileDialog.getExistingDirectory),
            ("godot", "godot_exe", QFileDialog.getOpenFileName),
            ("work", "godot_work", QFileDialog.getExistingDirectory),
        )
        for key, label, chooser in file_selectors:
            row = QWidget()
            layout = QHBoxLayout(row)
            layout.setContentsMargins(0, 0, 0, 0)
            default = str(Path(tempfile.gettempdir()) / "rtc-map-bridge") if key == "work" else ""
            field = QLineEdit(parent.settings.value(f"godot/{key}", default, type=str))
            browse = QPushButton(tr("browse"))
            browse.clicked.connect(lambda checked=False, name=label, widget=field, pick=chooser:
                                   self._browse(name, widget, pick))
            layout.addWidget(field, 1)
            layout.addWidget(browse)
            self.fields[key] = field
            form.addRow(tr(label), row)
        form.addRow(tr("godot_version"), QLabel(parent.settings.value("godot/version", tr("not_evaluated"), type=str)))
        history = parent.settings.value("godot/recent", [])
        if isinstance(history, list) and history:
            button = QPushButton(tr("godot_recent"))
            button.clicked.connect(lambda: self._choose_recent(history))
            form.addRow(tr("godot_project"), button)
        actions = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        actions.accepted.connect(self.accept)
        actions.rejected.connect(self.reject)
        form.addRow(actions)

    def _browse(self, label, widget, chooser):
        selection = chooser(self, tr(label), widget.text())
        path = selection[0] if isinstance(selection, tuple) else selection
        if path:
            widget.setText(path)

    def _choose_recent(self, paths):
        value, accepted = QInputDialog.getItem(self, tr("godot_recent"), tr("godot_project"), paths, editable=False)
        if accepted:
            self.fields["project"].setText(value)

    def settings_value(self):
        if any(not field.text().strip() for field in self.fields.values()):
            raise BridgeError("INVALID_PROJECT", tr("godot_required"))
        return ProjectSettings(*(Path(self.fields[key].text().strip()) for key in ("project", "godot", "work")))


class GodotMixin:
    def _build_godot_actions(self, menu):
        self._bridge_thread = None
        self._bridge_completion = None
        self._bridge_close = False
        self._regions = None
        self.godot_import_action = self._action("godot_import", self._choose_region)
        self.godot_export_action = self._action("godot_export", self._export_godot)
        self.godot_export_as_action = self._action("godot_export_as", self._export_godot_as)
        self.godot_validate_action = self._action("godot_validate", self._validate_godot)
        self.godot_settings_action = self._action("godot_settings", self._choose_godot_settings)
        menu.addSeparator()
        for action in (self.godot_import_action, self.godot_export_action, self.godot_export_as_action,
                       self.godot_validate_action, self.godot_settings_action):
            menu.addAction(action)
        self.godot_status = QLabel()
        self.godot_cancel = QPushButton(tr("cancel"))
        self.godot_cancel.clicked.connect(self._cancel_godot)
        self.statusBar().addWidget(self.godot_status, 1)
        self.statusBar().addWidget(self.godot_cancel)
        self.godot_cancel.hide()

    def _godot_settings(self):
        parts = [self.settings.value(f"godot/{key}", "", type=str) for key in ("project", "godot", "work")]
        if not all(parts):
            return None
        return ProjectSettings(*(Path(value) for value in parts))

    def _refresh_godot_actions(self):
        if not hasattr(self, "godot_import_action"):
            return
        settings = self._godot_settings()
        ready = self._bridge_thread is None and settings is not None and settings.godot.is_file()
        self.godot_import_action.setEnabled(ready)
        for action in (self.godot_export_action, self.godot_export_as_action, self.godot_validate_action):
            action.setEnabled(ready and self.draft.source is not None and self.draft.design is None)
            action.setToolTip(tr("design_export_unsupported") if self.draft.design is not None else
                              tr("godot_required") if not ready else action.text())
        self.godot_import_action.setToolTip(self.godot_import_action.text() if ready else tr("godot_required"))
        linked = self.draft.source is not None
        self.region_id.setReadOnly(linked)
        self.display_name.setReadOnly(linked)

    def _choose_godot_settings(self):
        dialog = GodotSettingsDialog(self)
        if dialog.exec() != QDialog.DialogCode.Accepted:
            return
        try:
            settings = dialog.settings_value().checked()
        except BridgeError as error:
            self._report_godot_error(error)
            return
        recent = self.settings.value("godot/recent", [])
        recent = recent if isinstance(recent, list) else []
        path = str(settings.project)
        self.settings.setValue("godot/recent", [path, *[item for item in recent if item != path]][:8])
        for key in ("project", "godot", "work"):
            self.settings.setValue(f"godot/{key}", str(getattr(settings, key)))
        self._regions = None
        self.settings.remove("godot/version")
        self.settings.sync()
        self._set_project_root(settings.project)
        self._invalidate_validation(force=True)
        self._refresh_region_choices()
        self._refresh_godot_actions()

    def _choose_region(self):
        if self._regions is None:
            self._start_godot("inspect_project", None, self._select_import)
        else:
            self._select_import({"regions": self._regions, "recovered": []})

    def _select_import(self, result):
        regions = self._regions = result["regions"]
        if "version" in result:
            self.settings.setValue("godot/version", result["version"])
        self._refresh_region_choices()
        for event in result["recovered"]:
            self.output.appendPlainText(event)
        labels = [f"{item['name']} · {item['id']} · {item['definition']}" for item in regions]
        if not labels:
            self._report_godot_error(BridgeError("RESOURCE_MISSING", tr("godot_no_regions")))
            return
        value, accepted = QInputDialog.getItem(self, tr("godot_import"), tr("godot_region"), labels, editable=False)
        if accepted and self._confirm_changes():
            definition = regions[labels.index(value)]["definition"]
            self._start_godot("import_region", definition, self._install_import)

    def _install_import(self, result):
        self._set_project_root(self._godot_settings().project)
        self._install_draft(result["document"])
        self.output.appendPlainText(tr("godot_imported").format(count=result["result"]["node_count"]))
        self._show_godot_warnings(result)

    def _linked_document(self):
        region_id, name, width, height = self._values()
        return replace(self.draft, region_id=region_id, display_name=name, width=width, height=height)

    def _export_godot(self):
        document = self._linked_document()
        target = self._godot_settings().project / document.source.scene_path
        yes = QMessageBox.StandardButton.Yes
        no = QMessageBox.StandardButton.No
        if QMessageBox.question(self, tr("godot_export"), tr("godot_publish_confirm").format(path=target),
                                yes | no, no) == yes:
            self._start_godot("export_region", (document, None), self._show_export)

    def _export_godot_as(self):
        parent = QFileDialog.getExistingDirectory(self, tr("godot_export_as"), self._last_folder())
        if not parent:
            return
        name, accepted = QInputDialog.getText(self, tr("godot_export_as"), tr("godot_export_folder"))
        name = name.strip()
        if not accepted:
            return
        if not name or name in (".", "..") or any(char in name for char in r'\/:*?"<>|'):
            self._report_godot_error(BridgeError("INVALID_PROJECT", tr("godot_export_folder")))
            return
        self._start_godot("export_as", (self._linked_document(), Path(parent) / name), self._show_export_as)

    def _validate_godot(self):
        self._start_godot("validate_export", (self._linked_document(), None), self._show_export_as)

    def _show_export(self, result):
        self.draft = replace(self.draft, source=result["document"].source)
        self._update_document_status()
        self._show_export_as(result)

    def _show_export_as(self, result):
        self.output.appendPlainText(tr("godot_verified").format(count=result["result"]["node_count"]))
        if result["target"]:
            self.output.appendPlainText(str(result["target"]))
        self._show_godot_warnings(result)

    def _show_godot_warnings(self, result):
        for warning in result["result"].get("warnings", []):
            self.output.appendPlainText(warning)

    def _start_godot(self, operation, payload, completion, settings=None):
        if self._bridge_thread is not None:
            return
        settings = settings or self._godot_settings()
        if settings is None:
            self._choose_godot_settings()
            return
        self.view.cancel_gesture()
        self._bridge_completion = completion
        self._bridge_phase = "stage"
        thread = self._bridge_thread = BridgeWorker(self, settings, operation, payload)
        thread.progress.connect(self._godot_progress, Qt.ConnectionType.QueuedConnection)
        thread.finished.connect(self._godot_thread_finished, Qt.ConnectionType.QueuedConnection)
        self._set_godot_busy(True)
        self._godot_progress(tr("godot_started"))
        thread.start()

    def _set_godot_busy(self, running):
        for widget in (self.centralWidget(), self.menuBar(), self.inspector_dock,
                       self.library_dock, self.layers_dock, self.region_dock, self.validation_dock,
                       *self.findChildren(QToolBar)):
            widget.setEnabled(not running)
        self.godot_cancel.setVisible(running)
        self.godot_cancel.setEnabled(running)
        if not running:
            self._refresh_godot_actions()

    def _cancel_godot(self):
        if self._bridge_thread is not None:
            self._bridge_thread.cancel.set()
            self.godot_cancel.setEnabled(False)
            self._godot_progress(tr("godot_canceling"))

    @Slot(str)
    def _godot_progress(self, message):
        if message == tr("runtime_running"):
            self._bridge_phase = "runtime"
        elif message in (tr("runtime_validated"), tr("godot_publishing")):
            self._bridge_phase = "runtime_passed"
        self.godot_status.setText(message)
        self.output.appendPlainText(message)

    @Slot()
    def _godot_thread_finished(self):
        thread = self._bridge_thread
        # QThread.finished can arrive before thread-local cleanup has completed.
        if not thread.wait(0):
            QTimer.singleShot(10, self, self._godot_thread_finished)
            return
        result, error = thread.result, thread.error
        completion = self._bridge_completion
        validates = thread.operation in ("validate_export", "export_region", "export_as")
        self._bridge_thread = self._bridge_completion = None
        thread.deleteLater()
        self._set_godot_busy(False)
        if self._bridge_close:
            self._bridge_close = False
            QTimer.singleShot(0, self.close)
            return
        if error:
            if validates:
                self._record_godot_validation(error, self._bridge_phase)
            self._report_godot_error(error)
        else:
            self._godot_progress(tr("godot_pass"))
            self.output.appendPlainText(tr("godot_evidence").format(path=result["evidence"]))
            completion(result)
            if validates:
                self._record_godot_validation()

    def _report_godot_error(self, error):
        text = str(error)
        if error.evidence:
            text += "\n" + tr("godot_evidence").format(path=error.evidence)
        self._godot_progress(text)
        if error.code != "CANCELLED":
            QMessageBox.warning(self, tr("invalid"), text)
