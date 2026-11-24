"""Region design tools that operate entirely on the current Python document."""

from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import Qt
from PySide6.QtGui import QUndoCommand
from PySide6.QtWidgets import (
    QCheckBox, QComboBox, QDoubleSpinBox, QFileDialog, QFormLayout, QInputDialog, QLabel, QLineEdit,
    QListWidget, QPushButton, QSpinBox, QTabWidget, QVBoxLayout, QWidget,
)

from objects import MAX_GEOMETRY, DocumentError
from placement_presets import capture_preset, load_preset
from region_design import SPAWN_SLOTS, Connection, RegionDesign, RegionEnvironment, RegionPoint, SpawnPoint
from region_index import INDEXED, NOT_INDEXED, IndexedRegion
from strings import tr


class DesignEdit(QUndoCommand):
    def __init__(self, window, after, selection, label):
        super().__init__(tr(label))
        self.window = window
        self.before = window.draft.design, window.view.marker_id
        self.after = after, selection

    def redo(self):
        self.window._apply_design(*self.after)

    def undo(self):
        self.window._apply_design(*self.before)


def _button(label, callback):
    button = QPushButton(tr(label))
    button.clicked.connect(callback)
    return button


class RegionMixin:
    def _build_region_dock(self):
        self.region_index = {}
        tabs = self.region_tabs = QTabWidget()
        panel = QWidget()
        marker_layout = QVBoxLayout(panel)
        self.marker_list = QListWidget()
        self.marker_list.currentRowChanged.connect(self._marker_clicked)
        marker_layout.addWidget(self.marker_list)
        self.marker_form = QWidget()
        form = QFormLayout(self.marker_form)
        self.point_name = QLineEdit()
        self.point_name.setMaxLength(64)
        self.marker_x, self.marker_y = QDoubleSpinBox(), QDoubleSpinBox()
        for field in (self.marker_x, self.marker_y):
            field.setRange(-MAX_GEOMETRY, MAX_GEOMETRY)
            field.setDecimals(6)
        self.landing = QCheckBox()
        self.slot = QSpinBox()
        self.slot.setRange(1, SPAWN_SLOTS)
        for key, field in (("point_id", self.point_name), ("x", self.marker_x), ("y", self.marker_y),
                           ("requires_landing", self.landing), ("spawn_slot", self.slot)):
            form.addRow(tr(key), field)
        form.addRow(_button("apply_region", self._save_marker), _button("delete", self._delete_marker))
        marker_layout.addWidget(self.marker_form)
        tabs.addTab(panel, tr("region_markers"))

        panel = QWidget()
        form = QFormLayout(panel)
        self.connection_list = QListWidget()
        self.exit_id = QComboBox()
        self.destination = QComboBox()
        self.destination.setEditable(True)
        self.entry_target = QComboBox()
        self.entry_target.setEditable(True)
        self.destination_status = QLabel()
        self.destination.currentTextChanged.connect(self._connection_destination_changed)
        form.addRow(self.connection_list)
        form.addRow(tr("exit_id"), self.exit_id)
        form.addRow(tr("destination_region"), self.destination)
        form.addRow(tr("destination_entry"), self.entry_target)
        form.addRow(tr("external_state"), self.destination_status)
        form.addRow(_button("add_connection", self._add_connection), _button("delete", self._remove_connection))
        form.addRow(_button("index_regions", self._index_region_files))
        tabs.addTab(panel, tr("connections"))

        panel = QWidget()
        form = QFormLayout(panel)
        self.environment_path, self.environment_uid, self.environment_color = QLineEdit(), QLineEdit(), QLineEdit()
        for key, field in (("environment_path", self.environment_path), ("environment_uid", self.environment_uid),
                           ("environment_color", self.environment_color)):
            form.addRow(tr(key), field)
        form.addRow(_button("apply_region", self._save_environment))
        self.design_notice = QLabel()
        self.design_notice.setWordWrap(True)
        tabs.addTab(panel, tr("environment"))
        container = QWidget()
        layout = QVBoxLayout(container)
        layout.addWidget(self.design_notice)
        layout.addWidget(tabs)
        self.region_dock = self._dock("region_design", container, Qt.DockWidgetArea.RightDockWidgetArea)
        self.region_tabs.currentChanged.connect(self._connection_tab_changed)
        self.tabifyDockWidget(self.inspector_dock, self.region_dock)
        self.inspector_dock.raise_()
        self.view.marker_selected.connect(self._show_marker)
        self.view.marker_placed.connect(self._place_marker)
        self.view.marker_moved.connect(self._move_marker)

    def _region_actions(self):
        menu = self.menuBar().addMenu(tr("region"))
        menu.addAction(self.wizard_action)
        for key in ("place_entry", "place_escape", "place_spawn"):
            action = self._action(key, lambda enabled, key=key: self._set_tool(key) if enabled else None,
                                  checked=False)
            self.tool_group.addAction(action)
            self.tool_actions[key] = action
            menu.addAction(action)
        presets = menu.addMenu(tr("placement_presets"))
        presets.addAction(self._action("capture_preset", self._capture_placement))
        presets.addAction(self._action("apply_preset", self._apply_placement))
        return menu

    def _capture_placement(self):
        models = sorted(self._selected_models(), key=lambda item: item.id)
        if not models:
            self._edit_error(tr("preset_selection_required"))
            return
        name, ok = QInputDialog.getText(self, tr("capture_preset"), tr("preset_name"))
        if ok:
            try:
                payload = capture_preset(name.strip(), models)
                self.settings.setValue(f"placement/{self._new_id('preset')}", payload)
            except DocumentError as error:
                self._edit_error(error)

    def _apply_placement(self):
        self.settings.beginGroup("placement")
        try:
            presets = [load_preset(self.settings.value(key, type=str)) for key in self.settings.childKeys()]
        except DocumentError as error:
            self._edit_error(error)
            return
        finally:
            self.settings.endGroup()
        if not presets:
            self._edit_error(tr("no_placement_presets"))
            return
        labels = [f"{index + 1} · {name}" for index, (name, _) in enumerate(presets)]
        label, ok = QInputDialog.getItem(self, tr("apply_preset"), tr("preset_name"), labels, editable=False)
        if not ok:
            return
        models = presets[labels.index(label)][1]
        anchor = self.view.snapped(self.view.mapToScene(self.view.viewport().rect().center()))
        allowed = self._editable_layers()
        try:
            if any(model.layer_id not in allowed for model in models):
                raise DocumentError(tr("locked_layer"))
            items = tuple(replace(model, id=self._new_id(model.type),
                                  position=(anchor.x() + model.position[0], anchor.y() + model.position[1]))
                          for model in models)
            self._commit("apply_preset", (*self.draft.objects, *items), selection=[item.id for item in items])
        except DocumentError as error:
            self._edit_error(error)

    def _design(self):
        return self.draft.design or RegionDesign()

    def _change_design(self, design, selection="", label="region_design"):
        if design != self._design():
            self.undo.push(DesignEdit(self, design, selection, label))

    def _apply_design(self, design, selection):
        self.draft = replace(self.draft, design=design)
        self._sync_region_design(selection)
        self._refresh_godot_actions()

    def _sync_region_design(self, selection=""):
        design = self._design()
        self.marker_rows = (*design.region_points, *design.spawn_points)
        self.marker_list.blockSignals(True)
        self.marker_list.clear()
        for row in self.marker_rows:
            text = f"{row.kind} · {row.point_id}" if isinstance(row, RegionPoint) else f"{tr('spawn_slot')} {row.spawn_index + 1}"
            self.marker_list.addItem(text)
        self.marker_list.blockSignals(False)
        self._populate_connections()
        previous_exit = self.exit_id.currentText()
        self.exit_id.clear()
        self.exit_id.addItems(sorted({row.point_id for row in design.region_points if row.kind == "ESCAPE"}))
        if previous_exit:
            self.exit_id.setCurrentText(previous_exit)
        for field, value in ((self.environment_path, design.environment.path), (self.environment_uid, design.environment.uid),
                             (self.environment_color, design.environment.loading_color)):
            field.setText(value)
        self.design_notice.setText(tr("design_connections_unsupported" if design.connections else "design_export_ready")
                                   if self.draft.design is not None else tr("design_import_preserved") if self.draft.source else "")
        self.design_notice.setVisible(bool(self.design_notice.text()))
        self._refresh_region_choices()
        self.view.sync_markers(self.draft.design, selection)

    def _marker_clicked(self, index):
        if index >= 0:
            row = self.marker_rows[index]
            self.view.select_marker(row.id)
            self.view.centerOn(*row.position)

    def _show_marker(self, key):
        index = next((i for i, row in enumerate(self.marker_rows) if row.id == key), -1)
        self.marker_list.blockSignals(True)
        self.marker_list.setCurrentRow(index)
        self.marker_list.blockSignals(False)
        self.marker_form.setEnabled(index >= 0)
        if index < 0:
            return
        row = self.marker_rows[index]
        point = isinstance(row, RegionPoint)
        self.marker_form.layout().setRowVisible(self.point_name, point)
        self.marker_form.layout().setRowVisible(self.landing, point)
        self.marker_form.layout().setRowVisible(self.slot, not point)
        self.point_name.setText(row.point_id if point else "")
        self.landing.setChecked(point and row.requires_landing)
        self.slot.setValue(1 if point else row.spawn_index + 1)
        self.marker_x.setValue(row.position[0])
        self.marker_y.setValue(row.position[1])

    def _place_marker(self, mode, position):
        try:
            self._add_marker(mode, position)
        except DocumentError as error:
            self._edit_error(error)
            return
        self.region_dock.show()
        self.region_dock.raise_()
        self.region_tabs.setCurrentIndex(0)

    def _add_marker(self, mode, position):
        design = self._design()
        if mode == "place_spawn":
            slot = next((i for i in range(SPAWN_SLOTS) if all(row.spawn_index != i for row in design.spawn_points)), None)
            if slot is None:
                raise DocumentError(tr("no_spawn_slot"))
            row = SpawnPoint(self._new_id("spawn"), slot, position)
            design = replace(design, spawn_points=(*design.spawn_points, row))
        else:
            kind = "ENTRY" if mode == "place_entry" else "ESCAPE"
            key = self._new_id(kind.lower())
            row = RegionPoint(key, kind, key, position)
            design = replace(design, region_points=(*design.region_points, row))
        self._change_design(design, row.id)

    def _replace_marker(self, key, **values):
        row = next((row for row in self.marker_rows if row.id == key), None)
        if row is None:
            return
        field = "region_points" if isinstance(row, RegionPoint) else "spawn_points"
        design = self._design()
        updated = tuple(replace(item, **values) if item.id == key else item for item in getattr(design, field))
        self._change_design(replace(design, **{field: updated}), key)

    def _move_marker(self, key, position):
        try:
            self._replace_marker(key, position=position)
        except DocumentError as error:
            self._edit_error(error)

    def _save_marker(self):
        key = self.view.marker_id
        row = next((row for row in self.marker_rows if row.id == key), None)
        if row is None:
            return
        change = {"point_id": self.point_name.text().strip(), "requires_landing": self.landing.isChecked()} if isinstance(row, RegionPoint) else {"spawn_index": self.slot.value() - 1}
        try:
            # Spin boxes round for display. Preserve components the user did not edit.
            position = tuple(old if abs(field.value() - old) <= 0.0000005 else field.value()
                             for field, old in zip((self.marker_x, self.marker_y), row.position))
            self._replace_marker(key, position=position, **change)
        except DocumentError as error:
            self._edit_error(error)

    def _delete_marker(self):
        key = self.view.marker_id
        if key:
            design = self._design()
            self._change_design(replace(design, region_points=tuple(row for row in design.region_points if row.id != key),
                                        spawn_points=tuple(row for row in design.spawn_points if row.id != key)))

    def _save_environment(self):
        try:
            environment = RegionEnvironment(*(field.text().strip() for field in
                                            (self.environment_path, self.environment_uid, self.environment_color)))
            self._change_design(replace(self._design(), environment=environment), self.view.marker_id)
        except DocumentError as error:
            self._edit_error(error)

    def _refresh_region_choices(self):
        previous = self.destination.currentText()
        regions = self.region_index.keys() | {item["id"] for item in self._regions or ()} | {self._values()[0]}
        self.destination.blockSignals(True)
        self.destination.clear()
        self.destination.addItems(sorted(regions))
        self.destination.setCurrentText(previous or self._values()[0])
        self.destination.blockSignals(False)
        self._refresh_entry_choices(self.destination.currentText())

    def _refresh_entry_choices(self, key):
        previous = self.entry_target.currentText()
        record = self.region_index.get(key)
        if key == self._values()[0]:
            entries = {point.point_id for point in self._design().region_points if point.kind == "ENTRY"}
            status = "local"
        else:
            entries = set(record.current_entries or ()) if record else set()
            status = record.state if record else NOT_INDEXED
            if record and status == INDEXED and record.entries is None:
                status = "entries_unavailable"
        self.destination_status.setText(tr(f"index_{status}"))
        self.destination_status.setToolTip(str(record.path) if record else "")
        self.entry_target.clear()
        self.entry_target.addItems(sorted(entries))
        if previous in entries:
            self.entry_target.setCurrentText(previous)

    def _connection_text(self, link):
        if link.region_id == self._values()[0]:
            state = "local"
        else:
            record = self.region_index.get(link.region_id)
            state = record.state if record else NOT_INDEXED
            if record and state == INDEXED and record.entries is None:
                state = "entries_unavailable"
        return f"{link.exit_id} → {link.region_id} / {link.entry_id} · {tr(f'index_{state}')}"

    def _refresh_index_labels(self):
        self._refresh_region_choices()
        self._populate_connections(self.connection_list.currentRow())

    def _populate_connections(self, selection=-1):
        self.connection_list.clear()
        for link in self._design().connections:
            self.connection_list.addItem(self._connection_text(link))
        self.connection_list.setCurrentRow(selection)

    def _connection_tab_changed(self, index):
        if index == 1:
            self._recheck_region_index()

    def _connection_destination_changed(self, destination):
        self._recheck_region_index(destination)
        self._refresh_entry_choices(destination)

    def _recheck_region_index(self, destination=None):
        checked = {key: row.recheck() if destination is None or key == destination else row
                   for key, row in self.region_index.items()}
        if checked != self.region_index:
            self.region_index = checked
            self._refresh_index_labels()
            self._invalidate_validation()

    def _index_region_files(self):
        names, _ = QFileDialog.getOpenFileNames(self, tr("index_regions"), self._last_folder(), tr("document_filter"))
        if not names:
            return
        index = {}
        try:
            for name in names:
                record = IndexedRegion.read(Path(name))
                if record.region_id in index:
                    raise DocumentError(f"중복 지역 ID · {record.region_id}")
                index[record.region_id] = record
        except (OSError, DocumentError) as error:
            self._edit_error(error)
            return
        self.region_index = index
        self._refresh_index_labels()
        self._invalidate_validation()

    def _add_connection(self):
        try:
            link = Connection(self.exit_id.currentText().strip(), self.destination.currentText().strip(),
                              self.entry_target.currentText().strip())
            design = self._design()
            self._change_design(replace(design, connections=(*design.connections, link)), self.view.marker_id)
        except DocumentError as error:
            self._edit_error(error)

    def _remove_connection(self):
        index = self.connection_list.currentRow()
        if index >= 0:
            design = self._design()
            self._change_design(replace(design, connections=design.connections[:index] + design.connections[index + 1:]),
                                self.view.marker_id)
