"""Main window for creating, viewing and reopening standalone map drafts."""

from dataclasses import replace
from pathlib import Path

from PySide6.QtCore import QSignalBlocker, Qt, QTimer, Slot
from PySide6.QtGui import QAction, QKeySequence
from PySide6.QtWidgets import (
    QDockWidget, QFileDialog, QFormLayout, QLabel, QLineEdit, QMainWindow,
    QMessageBox, QPlainTextEdit, QScrollArea, QSpinBox, QToolBar, QTreeWidget, QTreeWidgetItem,
    QVBoxLayout, QWidget,
)

from document import (
    MAX_EXTENT, MIN_EXTENT, SUFFIX, DocumentConflict, DocumentError,
    MapDocument, document_revision, read_document, write_document,
)
from editing import EditingMixin, MetadataEdit
from godot_ui import GodotMixin
from region_ui import RegionMixin
from strings import tr
from viewport import MapView
from wizard_ui import RegionWizard, WizardEdit

APP_NAME = "ReturnToCage Map Editor"
UI_STYLE = """
QMainWindow { background: #20252f; }
QMenuBar, QToolBar, QStatusBar { background: #242a35; }
QToolBar { border: none; border-bottom: 1px solid #394253; padding: 5px; spacing: 5px; }
QToolBar QToolButton { padding: 6px 10px; border-radius: 4px; }
QToolBar QToolButton:hover, QToolBar QToolButton:checked { background: #354756; }
QDockWidget::title { background: #2b3443; padding: 8px 10px; }
QTreeWidget, QPlainTextEdit { background: #1e2430; border: 1px solid #373f4e; }
QTreeWidget::item { padding: 4px 0; }
QLineEdit, QSpinBox { background: #181e28; border: 1px solid #465367; border-radius: 3px; padding: 5px; }
QLineEdit:focus, QSpinBox:focus { border-color: #78cebc; }
QLabel#panelTitle { color: #9de1d0; font-weight: bold; }
QLabel#viewportHint { color: #bec9d7; padding: 3px 10px; }
QGraphicsView#mapViewport { border: 1px solid #384052; }
"""


class MainWindow(GodotMixin, RegionMixin, EditingMixin, QMainWindow):
    def __init__(self, settings):
        super().__init__()
        self.settings = settings
        self.draft = MapDocument(display_name=tr("default_name"))
        self.path = None
        self.disk_hash = None
        self.resize(1200, 780)
        self.setMinimumSize(760, 510)
        self.setStyleSheet(UI_STYLE)
        self.view = MapView()
        content = QWidget()
        layout = QVBoxLayout(content)
        layout.setContentsMargins(4, 4, 4, 3)
        layout.addWidget(self.view, 1)
        hint = QLabel(tr("quick_help"))
        hint.setObjectName("viewportHint")
        layout.addWidget(hint)
        self.setCentralWidget(content)
        self._build_docks()
        self._build_region_dock()
        self._build_actions()
        self.region_status = QLabel()
        self.cursor_status = QLabel("x 0 · y 0")
        self.zoom_status = QLabel()
        self.draft_status = QLabel()
        self.tool_status = QLabel(tr("select"))
        for label in (self.region_status, self.cursor_status, self.zoom_status, self.tool_status, self.draft_status):
            label.setContentsMargins(8, 0, 8, 0)
            self.statusBar().addPermanentWidget(label)
        self.view.zoom_changed.connect(self._show_zoom)
        self.view.world_position_changed.connect(
            lambda point: self.cursor_status.setText(f"x {point.x():.0f} · y {point.y():.0f}")
        )
        if geometry := settings.value("window/geometry"):
            self.restoreGeometry(geometry)
        if state := settings.value("window/docks"):
            self.restoreState(state)
        self._install_draft(self.draft)
        if root := self.settings.value("library/root", type=str):
            self._set_project_root(Path(root))
        QTimer.singleShot(0, self.view.fit_map)

    def _dock(self, key, widget, area):
        dock = QDockWidget(tr(key), self)
        dock.setObjectName(f"{key}Dock")
        dock.setWidget(widget)
        self.addDockWidget(area, dock)
        return dock

    def _build_docks(self):
        self.structure = QTreeWidget()
        self.structure.setHeaderHidden(True)
        self.tree_region = QTreeWidgetItem(self.structure)
        self.tree_bounds = QTreeWidgetItem(self.tree_region, [tr("bounds")])
        self.tree_region.setExpanded(True)
        self.structure_dock = self._dock("structure", self.structure, Qt.DockWidgetArea.LeftDockWidgetArea)
        self.structure.itemDoubleClicked.connect(lambda *_: self.view.fit_map())

        panel = QWidget()
        layout = QVBoxLayout(panel)
        layout.setContentsMargins(12, 12, 12, 12)
        heading = QLabel(tr("document"))
        heading.setObjectName("panelTitle")
        layout.addWidget(heading)
        form = QFormLayout()
        self.region_id = QLineEdit()
        self.region_id.setMaxLength(64)
        self.region_id.setPlaceholderText("new_region")
        self.display_name = QLineEdit()
        self.display_name.setMaxLength(120)
        self.width_field = QSpinBox()
        self.height_field = QSpinBox()
        for spin in (self.width_field, self.height_field):
            spin.setRange(MIN_EXTENT, MAX_EXTENT)
            spin.setSuffix(tr("unit"))
            spin.setKeyboardTracking(False)
            spin.valueChanged.connect(self._fields_changed)
        for label, field in (("region_id", self.region_id), ("display_name", self.display_name),
                             ("width", self.width_field), ("height", self.height_field)):
            form.addRow(tr(label), field)
        self.region_id.textChanged.connect(self._fields_changed)
        self.display_name.textChanged.connect(self._fields_changed)
        layout.addLayout(form)
        self._build_editing_docks(layout)
        layout.addStretch()
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(panel)
        self.inspector_dock = self._dock("inspector", scroll, Qt.DockWidgetArea.RightDockWidgetArea)
        self.output = QPlainTextEdit()
        self.output.setReadOnly(True)
        self.output.setMaximumBlockCount(200)
        self.output_dock = self._dock("output", self.output, Qt.DockWidgetArea.BottomDockWidgetArea)
        self.resizeDocks([self.library_dock, self.inspector_dock], [210, 228], Qt.Orientation.Horizontal)
        self.resizeDocks([self.output_dock], [95], Qt.Orientation.Vertical)

    def _action(self, key, callback, shortcut=None, checked=None):
        action = QAction(tr(key), self)
        if shortcut:
            action.setShortcut(shortcut)
        if checked is None:
            action.triggered.connect(callback)
        else:
            action.setCheckable(True)
            action.setChecked(checked)
            action.toggled.connect(callback)
        return action

    def _build_actions(self):
        toolbar = QToolBar(tr("document"))
        toolbar.setObjectName("editorToolbar")
        self.addToolBar(toolbar)
        file_menu = self.menuBar().addMenu(tr("file"))
        for key, callback, shortcut, on_toolbar in (
            ("new", self.new_document, QKeySequence.StandardKey.New, True),
            ("open", self.open_dialog, QKeySequence.StandardKey.Open, True),
            ("save", self.save, QKeySequence.StandardKey.Save, True),
            ("save_as", self.save_as, QKeySequence.StandardKey.SaveAs, False),
            ("exit", self.close, QKeySequence.StandardKey.Quit, False),
        ):
            action = self._action(key, callback, shortcut)
            file_menu.addAction(action)
            if on_toolbar:
                toolbar.addAction(action)
        self._build_godot_actions(file_menu)
        self.wizard_action = self._action("region_wizard", self._open_region_wizard)
        file_menu.addAction(self.wizard_action)
        toolbar.addSeparator()
        view_menu = self.menuBar().addMenu(tr("view"))
        self._build_editing_actions(toolbar, view_menu)
        self._region_actions()
        toolbar.addSeparator()
        for key, callback, shortcut in (
            ("fit", self.view.fit_map, "F"),
            ("actual", lambda: self.view.set_zoom(1.0), "1"),
            ("zoom_in", lambda: self.view.set_zoom(self.view.zoom * 1.15), "Ctrl+="),
            ("zoom_out", lambda: self.view.set_zoom(self.view.zoom / 1.15), "Ctrl+-"),
        ):
            action = self._action(key, callback, shortcut)
            view_menu.addAction(action)

        toolbar.addSeparator()
        grid = self._action("grid", self.view.set_grid_visible, "G",
                            checked=self.settings.value("view/grid", True, type=bool))
        self.view.set_grid_visible(grid.isChecked())
        view_menu.addAction(grid)
        view_menu.addSeparator()
        for dock in (self.library_dock, self.layers_dock, self.structure_dock, self.inspector_dock, self.output_dock,
                     self.region_dock):
            view_menu.addAction(dock.toggleViewAction())
        help_menu = self.menuBar().addMenu(tr("help"))
        help_menu.addAction(self._action("about", lambda: QMessageBox.information(self, APP_NAME, tr("about_body"))))

    def _values(self):
        return self.region_id.text(), self.display_name.text(), self.width_field.value(), self.height_field.value()

    @property
    def dirty(self):
        return not self.undo.isClean() or self.draft.source != self.saved_source

    def _fields_changed(self, _=None):
        values = self._values()
        if values != self._metadata:
            field = next(index for index, value in enumerate(values) if value != self._metadata[index])
            self.undo.push(MetadataEdit(self, self._metadata, values, field))

    def _apply_metadata(self, values):
        self._metadata = values
        for widget, setter, value in zip(
            (self.region_id, self.display_name, self.width_field, self.height_field),
            (self.region_id.setText, self.display_name.setText, self.width_field.setValue, self.height_field.setValue),
            values,
        ):
            with QSignalBlocker(widget):
                if widget in (self.region_id, self.display_name):
                    if widget.text() != value:
                        setter(value)
                elif widget.value() != value:
                    setter(value)
        self._update_document_status()

    def _update_document_status(self):
        region_id, name, width, height = self._values()
        if (width, height) != (self.view.map_scene.bounds.width(), self.view.map_scene.bounds.height()):
            self.view.set_bounds(width, height)
        label = name or region_id or tr("default_name")
        self.tree_region.setText(0, label)
        self.region_status.setText(f"{tr('region')} · {label}")
        self.draft_status.setText(tr("dirty") if self.dirty else tr("saved" if self.path else "draft"))
        self.setWindowTitle(f"{label}{' *' if self.dirty else ''} — {APP_NAME}")

    @Slot(int)
    def _undo_index_changed(self, _index):
        self._update_document_status()

    def _show_zoom(self, value):
        grid = self.view.map_scene.grid_size
        self.zoom_status.setText(f"{value:.0%}   ·   {tr('grid')} {grid}")

    def _open_region_wizard(self):
        known_ids = {item["id"] for item in self._regions or ()}
        if self.path is not None or self.draft.source is not None or self.draft.design is not None:
            known_ids.add(self._values()[0])
        dialog = RegionWizard(self, known_ids)
        if dialog.exec() and self._confirm_changes():
            edit = WizardEdit(self, dialog.document)
            self._install_draft(edit.before)
            self.undo.push(edit)

    def _install_draft(self, document, path=None, disk_hash=None):
        self.draft, self.path, self.disk_hash = document, path, disk_hash
        self.saved_source = document.source
        self.undo.clear()
        self._apply_metadata((document.region_id, document.display_name, document.width, document.height))
        self._sync_objects()
        self._sync_region_design()
        self._refresh_godot_actions()
        self.view.fit_map()

    def _confirm_changes(self):
        if not self.dirty:
            return True
        box = QMessageBox(self)
        box.setWindowTitle(tr("confirm_title"))
        box.setText(tr("confirm_body"))
        save = box.addButton(tr("save"), QMessageBox.ButtonRole.AcceptRole)
        discard = box.addButton(tr("discard"), QMessageBox.ButtonRole.DestructiveRole)
        cancel = box.addButton(tr("cancel"), QMessageBox.ButtonRole.RejectRole)
        box.setDefaultButton(save)
        box.setEscapeButton(cancel)
        box.exec()
        clicked = box.clickedButton()
        return clicked == discard or (clicked == save and self.save())

    def new_document(self):
        if self._confirm_changes():
            self._install_draft(MapDocument(display_name=tr("default_name")))

    def open_dialog(self):
        name, _ = QFileDialog.getOpenFileName(self, tr("open"), self._last_folder(), tr("document_filter"))
        if name and self._confirm_changes():
            try:
                self.open_document(Path(name))
            except (OSError, DocumentError) as error:
                self._report_error(error)

    def open_document(self, path):
        path = path.absolute()
        draft, disk_hash = read_document(path)
        self._install_draft(draft, path, disk_hash)
        self.settings.setValue("file/folder", str(path.parent))
        self.output.appendPlainText(tr("opened").format(path=path))

    def save(self):
        if self.path is None:
            return self.save_as()
        return self._save_with_feedback(self.path, self.disk_hash)

    def save_as(self):
        dialog = QFileDialog(self, tr("save_as"), self._last_folder(), tr("document_filter"))
        dialog.setAcceptMode(QFileDialog.AcceptMode.AcceptSave)
        dialog.setDefaultSuffix(SUFFIX[1:])
        dialog.setOption(QFileDialog.Option.DontConfirmOverwrite)
        region_id = self.region_id.text()
        suggested = region_id if region_id.isascii() and region_id.isidentifier() else self.draft.region_id
        dialog.selectFile(f"{suggested}{SUFFIX}")
        if dialog.exec():
            return self._save_as_path(Path(dialog.selectedFiles()[0]))
        return False

    def _save_as_path(self, path):
        path = path.absolute()
        try:
            revision = document_revision(path)
            if path == self.path and revision != self.disk_hash:
                raise DocumentConflict("the open file changed on disk")
        except (OSError, DocumentError) as error:
            self._report_error(error)
            return False
        if revision is not None:
            yes, no = QMessageBox.StandardButton.Yes, QMessageBox.StandardButton.No
            if QMessageBox.question(self, tr("overwrite_title"), tr("overwrite_body").format(path=path),
                                    yes | no, no) != yes:
                return False
        return self._save_with_feedback(path, revision)

    def _last_folder(self):
        return self.settings.value("file/folder", str(Path.home()), type=str)

    def _save_with_feedback(self, path, expected_hash):
        try:
            self.save_document(path, expected_hash)
        except (OSError, DocumentError) as error:
            self._report_error(error)
            return False
        return True

    def save_document(self, path, expected_hash=None):
        path = path.absolute()
        region_id, name, width, height = self._values()
        draft = replace(self.draft, region_id=region_id, display_name=name, width=width, height=height)
        disk_hash = write_document(path, draft, expected_hash)
        self.draft, self.path, self.disk_hash = draft, path, disk_hash
        self.saved_source = draft.source
        self.settings.setValue("file/folder", str(path.parent))
        self.undo.setClean()
        self._update_document_status()
        self.output.appendPlainText(tr("written").format(path=path))

    def _report_error(self, error):
        conflict = isinstance(error, DocumentConflict)
        title = tr("conflict" if conflict else "invalid")
        self.output.appendPlainText(f"{title} · {error}")
        QMessageBox.warning(self, title, tr("conflict_detail") if conflict else str(error))

    def closeEvent(self, event):
        if self._bridge_thread is not None:
            self._bridge_close = True
            self._cancel_godot()
            event.ignore()
            return
        if not self._confirm_changes():
            event.ignore()
            return
        self._stop_texture_scan()
        self.settings.setValue("window/geometry", self.saveGeometry())
        self.settings.setValue("window/docks", self.saveState())
        self.settings.setValue("view/grid", self.view.map_scene.show_grid)
        self.settings.setValue("view/snap", self.view.snap_enabled)
        self.settings.sync()
        super().closeEvent(event)
