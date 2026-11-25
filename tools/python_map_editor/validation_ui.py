"""Validity results tied to the current draft and project context."""

from dataclasses import replace

from PySide6.QtCore import QPointF, Qt
from PySide6.QtGui import QColor
from PySide6.QtWidgets import QLabel, QListWidget, QListWidgetItem, QPushButton, QVBoxLayout, QWidget

from objects import DocumentError
from region_validation import EXTERNAL, FAIL, NOT_EVALUATED, PASS, PHYSICS, RUNTIME, STATIC, WARNING, Finding, summarize, validate_region
from strings import tr

_COLORS = {FAIL: "#ff939a", WARNING: "#ffd080", PASS: "#8fdfbd", NOT_EVALUATED: "#b6c0d1"}


class ValidationMixin:
    def _build_validation_dock(self):
        panel = QWidget()
        layout = QVBoxLayout(panel)
        self.validation_status = QLabel()
        self.validation_status.setWordWrap(True)
        layout.addWidget(self.validation_status)
        self.validation_run = QPushButton(tr("validate_python"))
        self.validation_run.clicked.connect(self._validate_python)
        layout.addWidget(self.validation_run)
        self.validation_list = QListWidget()
        self.validation_list.itemClicked.connect(self._focus_finding)
        layout.addWidget(self.validation_list)
        self.validation_dock = self._dock("validation", panel, Qt.DockWidgetArea.BottomDockWidgetArea)
        self.tabifyDockWidget(self.output_dock, self.validation_dock)
        self.output_dock.raise_()
        self._validation_context = None
        self._python_state = self._external_state = self._physics_state = NOT_EVALUATED
        self._export_state = self._runtime_state = NOT_EVALUATED
        self._scene_state = self._publish_state = NOT_EVALUATED
        self._show_validation_status()

    def _validation_key(self):
        return self.draft, self.region_index, self._values(), self.view.textures.root

    def _invalidate_validation(self, *, force=False):
        if self._validation_context is not None and not force:
            draft, index, values, root = self._validation_context
            if draft is self.draft and index is self.region_index and values == self._values() and root == self.view.textures.root:
                return
        self._validation_context = None
        self._python_state = self._external_state = self._physics_state = NOT_EVALUATED
        self._export_state = self._runtime_state = NOT_EVALUATED
        self._scene_state = self._publish_state = NOT_EVALUATED
        self.validation_list.clear()
        self.view.issue_position = None
        for item in self.view.markers.values():
            if item.issue:
                item.issue = False
                item.update()
        for row in range(self.connection_list.count()):
            self.connection_list.item(row).setData(Qt.ItemDataRole.ForegroundRole, None)
        self.view.viewport().update()
        self._show_validation_status()

    def _show_validation_status(self):
        states = ((STATIC, self._python_state), (EXTERNAL, self._external_state),
                  ("godot_scene", self._scene_state), (RUNTIME, self._runtime_state), (PHYSICS, self._physics_state),
                  ("export", self._export_state), ("publish", self._publish_state))
        self._overall_state = summarize(state for _, state in states)
        self.validation_status.setText("  |  ".join(f"{tr(f'{domain}_state')} · {state}"
                                                       for domain, state in (*states, ("overall", self._overall_state))))

    def _validate_python(self):
        self._recheck_region_index()
        self._invalidate_validation()
        self._validation_context = self._validation_key()
        region_id, name, width, height = self._values()
        try:
            document = replace(self.draft, region_id=region_id, display_name=name, width=width, height=height)
            root = self.view.textures.root
            findings = validate_region(document, self.region_index, root.resolve() if root else None,
                                       getattr(self, "_enemy_catalog", ()))
        except (DocumentError, OSError, RuntimeError) as error:
            findings = [Finding(FAIL, "invalid_document", str(error))]
        self._python_state = summarize(item.status for item in findings if item.domain == STATIC)
        self._external_state = summarize(item.status for item in findings if item.domain == EXTERNAL)
        self._show_validation_status()
        self.validation_list.clear()
        self.view.issue_position = None
        for marker in self.view.markers.values():
            marker.issue = False
            marker.update()
        for finding in findings:
            if finding.domain == RUNTIME and finding.status == NOT_EVALUATED and self._runtime_state == PASS:
                continue
            if finding.code == "physics_clearance_check" and self._physics_state != NOT_EVALUATED:
                continue
            text = f"{tr(f'{finding.domain}_state')} · {finding.status} · {tr(finding.code, finding.code)}"
            if finding.detail:
                text += f" · {finding.detail}"
            item = QListWidgetItem(text, self.validation_list)
            item.setForeground(QColor(_COLORS[finding.status]))
            item.setData(Qt.ItemDataRole.UserRole, finding)
            category, _, key = finding.target.partition(":")
            if finding.status in (FAIL, WARNING) and category == "marker" and key in self.view.markers:
                self.view.markers[key].issue = True
                self.view.markers[key].update()
            if finding.connection is not None and finding.status == FAIL:
                self.connection_list.item(finding.connection).setForeground(QColor(_COLORS[FAIL]))
        self.validation_dock.show()
        self.validation_dock.raise_()

    def _focus_finding(self, item):
        finding = item.data(Qt.ItemDataRole.UserRole)
        if not isinstance(finding, Finding):
            return
        category, _, key = finding.target.partition(":")
        self.view.issue_position = None
        if category == "marker" and key in self.view.markers:
            marker = self.view.markers[key]
            self.view.select_marker(key)
            self.view.issue_position = QPointF(marker.pos())
            self.view.centerOn(marker)
            self.region_dock.raise_()
            self.region_tabs.setCurrentIndex(0)
        elif category == "object" and key in self.view.objects:
            obj = self.view.objects[key]
            self.view.select_marker("")
            self.view.map_scene.clearSelection()
            obj.setSelected(True)
            self.view.issue_position = QPointF(obj.pos())
            self.view.centerOn(obj)
            self.inspector_dock.raise_()
        elif finding.connection is not None and 0 <= finding.connection < self.connection_list.count():
            self.connection_list.setCurrentRow(finding.connection)
            self.region_dock.raise_()
            self.region_tabs.setCurrentIndex(1)
        elif finding.target or finding.connection is not None:
            self.statusBar().showMessage(tr("validation_target_missing"), 5000)
        self.view.viewport().update()

    def _record_godot_validation(self, error=None, phase="stage", *, result=None, publishing=False):
        self._invalidate_validation()
        self._validation_context = self._validation_key()
        self._physics_state = self._publish_state = NOT_EVALUATED
        stale = getattr(error, "validation_stale", False)
        verified = result if error is None else getattr(error, "validation", None)
        if stale:
            self._scene_state = self._export_state = self._runtime_state = NOT_EVALUATED
            if publishing and phase == "publishing":
                self._publish_state = FAIL
        elif error is None or verified is not None:
            self._scene_state = self._export_state = self._runtime_state = PASS
            if error is not None and error.code != "CANCELLED" and publishing and phase == "publishing":
                self._publish_state = FAIL
            if error is None and result and result.get("target"):
                self._publish_state = PASS
            if verified and verified["document"].design is not None:
                receipt = verified["result"]
                if receipt.get("unmapped_connections"):
                    self._export_state = NOT_EVALUATED
                runtime_rows = receipt.get("runtime", {}).get("results", ())
                physical = {"ENTRY Physical Anchor", "ENTRY Clearance excluding local actor", "ENTRY Live Physics",
                            "Player Spawn Assignment", "Ground Support", "Terrain Physics", "Player Actor"}
                rows = [row for row in runtime_rows if row.get("stage") in physical
                        or row.get("stage", "").startswith(("Player Spawn Slot ", "Player Body Clearance / slot "))]
                if physical.issubset({row["stage"] for row in rows}):
                    self._physics_state = summarize(WARNING if row["status"] == "WARN" else row["status"].replace("_", " ")
                                                    for row in rows)
        elif error.code == "CANCELLED":
            self._scene_state = self._export_state = self._runtime_state = NOT_EVALUATED
        elif phase in ("runtime_passed", "publishing"):
            self._scene_state = PASS
            self._export_state, self._runtime_state = FAIL, PASS
            if publishing and phase == "publishing":
                self._publish_state = FAIL
        elif phase == "runtime":
            self._scene_state = PASS
            self._export_state, self._runtime_state = NOT_EVALUATED, FAIL
        else:
            self._scene_state = self._export_state = FAIL
            self._runtime_state = NOT_EVALUATED
        if self._runtime_state == PASS:
            for row in reversed(range(self.validation_list.count())):
                finding = self.validation_list.item(row).data(Qt.ItemDataRole.UserRole)
                if (finding.domain == RUNTIME and finding.status == NOT_EVALUATED
                        or finding.code == "physics_clearance_check" and self._physics_state != NOT_EVALUATED):
                    self.validation_list.takeItem(row)
        self._show_validation_status()
