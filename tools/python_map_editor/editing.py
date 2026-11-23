"""Editor commands and the connection between the document and Qt widgets."""

from collections import Counter
from dataclasses import asdict, replace
import json
from pathlib import Path
import sys
import tempfile
from uuid import uuid4

from PySide6.QtCore import QMimeData, QProcess, Qt
from PySide6.QtGui import QActionGroup, QKeySequence, QUndoCommand, QUndoStack
from PySide6.QtWidgets import QApplication, QFileDialog

from document import MAX_FILE_BYTES
from objects import DocumentError, MapObject, ObjectProperties
from panels import Asset, LayerPanel, LibraryPanel, ObjectInspector
from strings import tr

CLIPBOARD_MIME = "application/x-rtc-objects"
DEFAULT_SIZE = {"platform": (192, 24), "decoration": (64, 64)}
DEFAULT_LAYER = {"platform": "terrain", "decoration": "decorations"}


class MapEdit(QUndoCommand):
    def __init__(self, window, label, before, after, selection):
        super().__init__(tr(label))
        self.window = window
        self.before = before
        self.after = after
        self.previous_selection = window.view.selected_ids()
        self.selection = selection

    def redo(self):
        self.window._apply_objects(self.after, self.selection)

    def undo(self):
        self.window._apply_objects(self.before, self.previous_selection)


class MetadataEdit(QUndoCommand):
    def __init__(self, window, before, after, field):
        super().__init__(tr("edit_metadata"))
        self.window = window
        self.before = before
        self.after = after
        self.field = field

    def id(self):
        return self.field

    def mergeWith(self, other):
        self.after = other.after
        return True

    def redo(self):
        self.window._apply_metadata(self.after)

    def undo(self):
        self.window._apply_metadata(self.before)


class EditingMixin:
    def _build_editing_docks(self, inspector_layout):
        self.undo = QUndoStack(self)
        self.undo.setUndoLimit(100)
        self.undo.indexChanged.connect(self._undo_index_changed)
        self.library = LibraryPanel(self.view.textures)
        self.layer_panel = LayerPanel()
        self.object_inspector = ObjectInspector()
        inspector_layout.addWidget(self.object_inspector)
        self.library_dock = self._dock("library", self.library, Qt.DockWidgetArea.LeftDockWidgetArea)
        self.layers_dock = self._dock("layers", self.layer_panel, Qt.DockWidgetArea.LeftDockWidgetArea)
        self.tabifyDockWidget(self.structure_dock, self.layers_dock)
        self.layers_dock.raise_()
        self.view.map_scene.selectionChanged.connect(self._update_selection)
        self.view.preview_changed.connect(self._update_preview)
        self.view.gesture_finished.connect(self._finish_gesture)
        self.view.asset_dropped.connect(self._drop_asset)
        self.layer_panel.layer_edited.connect(self._edit_layer)
        self.object_inspector.property_edited.connect(self._edit_property)
        self.library.asset_selected.connect(lambda asset: self.layer_panel.select_layer(DEFAULT_LAYER[asset.type]))
        self.library.tree.itemDoubleClicked.connect(self._place_at_center)
        self.library.tree.verticalScrollBar().valueChanged.connect(self.library.refresh_icons)
        self.library_scan = None
        self.library_generation = 0

    def _build_editing_actions(self, toolbar, view_menu):
        menu = self.menuBar().addMenu(tr("edit"))
        self.undo_action = self.undo.createUndoAction(self, tr("undo"))
        self.redo_action = self.undo.createRedoAction(self, tr("redo"))
        for action, key in ((self.undo_action, QKeySequence.StandardKey.Undo),
                            (self.redo_action, QKeySequence.StandardKey.Redo)):
            action.setShortcuts(QKeySequence.keyBindings(key))
            toolbar.addAction(action)
            menu.addAction(action)
        for key, callback, shortcut in (
            ("delete", self._delete_selection, QKeySequence.StandardKey.Delete),
            ("copy", self._copy_selection, QKeySequence.StandardKey.Copy),
            ("paste", self._paste_selection, QKeySequence.StandardKey.Paste),
            ("duplicate", self._duplicate_selection, "Ctrl+D"),
        ):
            action = self._action(key, callback, shortcut)
            action.setShortcutContext(Qt.ShortcutContext.WidgetShortcut)
            self.view.addAction(action)
            menu.addAction(action)
        toolbar.addSeparator()
        self.tool_group = QActionGroup(self)
        self.tool_actions = {}
        for key, shortcut in (("select", "V"), ("rectangle", "R"), ("paint", "B"), ("erase", "E"), ("pan", "H")):
            action = self._action(key, lambda enabled, key=key: self._set_tool(key) if enabled else None,
                                  shortcut, checked=key == "select")
            action.setToolTip(tr(f"{key}_tip"))
            self.tool_group.addAction(action)
            self.tool_actions[key] = action
            toolbar.addAction(action)
        snap_action = self._action("snap", self._set_snap, checked=self.settings.value("view/snap", True, type=bool))
        self._set_snap(snap_action.isChecked())
        view_menu.addAction(snap_action)
        toolbar.addAction(snap_action)
        menu.addSeparator()
        menu.addAction(self._action("project_location", self._choose_project))

    def _set_tool(self, tool):
        self.view.set_tool(tool)
        self.tool_status.setText(tr(tool))

    def _set_snap(self, enabled):
        self.view.snap_enabled = enabled

    def _choose_project(self):
        name = QFileDialog.getExistingDirectory(self, tr("project_location"),
                                                str(self.view.textures.root or self._last_folder()))
        if name:
            self._set_project_root(Path(name))

    def _set_project_root(self, root):
        root = root.absolute()
        self._stop_texture_scan()
        self.settings.setValue("library/root", str(root))
        self.view.textures.root = root
        self._invalidate_validation()
        self.view.textures.images.clear()
        self.library.set_paths(())
        self.view.viewport().update()
        generation = self.library_generation
        directory = tempfile.TemporaryDirectory(prefix="rtc-textures-")
        output = Path(directory.name) / "textures.json"
        process = QProcess(self)
        self.library_scan = process, directory
        prefix = [] if getattr(sys, "frozen", False) else [str(Path(__file__).with_name("main.py"))]
        process.finished.connect(lambda code, status: self._install_library(generation, output, code, status))
        process.errorOccurred.connect(lambda error: self._scan_error(generation, error))
        process.start(sys.executable, [*prefix, "--scan-textures", str(root), str(output)])

    def _stop_texture_scan(self):
        self.library_generation += 1
        if self.library_scan is not None:
            process, directory = self.library_scan
            self.library_scan = None
            if process.state() != QProcess.ProcessState.NotRunning:
                process.kill()
                process.waitForFinished(500)
            directory.cleanup()
            process.deleteLater()

    def _scan_error(self, generation, error):
        if generation == self.library_generation and error == QProcess.ProcessError.FailedToStart:
            self._stop_texture_scan()

    def _install_library(self, generation, output, code, status):
        if generation != self.library_generation:
            return
        try:
            if code == 0 and status == QProcess.ExitStatus.NormalExit:
                paths = json.loads(output.read_text(encoding="utf-8"))
                self.library.set_paths(paths)
        except (OSError, ValueError) as error:
            self._edit_error(error)
        finally:
            self._stop_texture_scan()

    def _commit(self, label, objects=None, layers=None, selection=None):
        current = self.draft
        candidate = replace(current, objects=current.objects if objects is None else tuple(objects),
                            layers=current.layers if layers is None else tuple(layers))
        before = current.objects, current.layers
        after = candidate.objects, candidate.layers
        if before != after:
            selected = self.view.selected_ids() if selection is None else frozenset(selection)
            self.undo.push(MapEdit(self, label, before, after, selected))

    def _apply_objects(self, content, selection):
        self.draft = replace(self.draft, objects=content[0], layers=content[1])
        self._sync_objects(selection)

    def _sync_objects(self, selection=()):
        if selection:
            self.view.select_marker("")
        self.view.sync_document(self.draft, selection)
        counts = Counter(obj.layer_id for obj in self.draft.objects)
        self.layer_panel.populate(self.draft.layers, counts)
        self._update_selection()

    def _selected_models(self):
        return [item.model for item in self.view.map_scene.selectedItems()]

    def _update_selection(self):
        self.object_inspector.populate(self._selected_models(), self.draft.layers, self.view.textures.natural_size)

    def _update_preview(self):
        models = []
        for item in self.view.map_scene.selectedItems():
            try:
                models.append(replace(item.model, position=item.pos().toTuple(),
                                      size=(item.rect().width(), item.rect().height())))
            except DocumentError:
                models.append(item.model)
        self.object_inspector.populate(models, self.draft.layers, self.view.textures.natural_size, preview=True)

    def _finish_gesture(self, mode, payload):
        try:
            if mode == "rectangle":
                point, size = payload
                self._place(Asset("platform"), (point,), size, label="rectangle")
            elif mode == "paint":
                if self.library.asset:
                    self._place(self.library.asset, payload, label="paint")
            elif mode == "erase":
                self._delete(payload, "erase")
            else:
                self._change_objects(mode, {key: replace(self.view.objects[key].model, position=position, size=size)
                                             for key, (position, size) in payload.items()})
        except DocumentError as error:
            self._edit_error(error)

    def _drop_asset(self, payload, position):
        try:
            if len(payload) > 4096:
                raise DocumentError("invalid library asset")
            data = json.loads(payload)
            if not isinstance(data, list) or len(data) != 2:
                raise DocumentError("invalid library asset")
            asset = Asset(*data)
            self._place(asset, (position.toTuple(),))
        except (ValueError, TypeError, RecursionError) as error:
            self._edit_error(error)

    def _place_at_center(self, item, column):
        if self.library.asset:
            center = self.view.mapToScene(self.view.viewport().rect().center())
            try:
                self._place(self.library.asset, (self.view.snapped(center).toTuple(),))
            except DocumentError as error:
                self._edit_error(error)

    def _editable_layers(self):
        return {layer.id for layer in self.draft.layers if layer.visible and not layer.locked}

    def _place(self, asset, points, size=None, label="add"):
        layer_id = self.layer_panel.layer_id or DEFAULT_LAYER[asset.type]
        if layer_id not in self._editable_layers():
            raise DocumentError(tr("locked_layer"))
        if size is None:
            size = self.view.textures.natural_size(asset.path) if asset.path else DEFAULT_SIZE[asset.type]
        occupied = {obj.position for obj in self.draft.objects
                    if obj.layer_id == layer_id and obj.type == asset.type and obj.properties.texture_path == asset.path}
        added = []
        for point in points:
            if label == "paint" and point in occupied:
                continue
            properties = ObjectProperties(texture_path=asset.path)
            added.append(MapObject(self._new_id(asset.type), asset.type, layer_id, point, size, properties=properties))
        self._commit(label, (*self.draft.objects, *added), selection=[obj.id for obj in added])

    @staticmethod
    def _new_id(kind):
        return f"{kind}_{uuid4().hex}"

    def _delete_selection(self):
        if self.view.marker_id:
            self._delete_marker()
        else:
            self._delete(self.view.selected_ids(), "delete")

    def _delete(self, ids, label):
        allowed = self._editable_layers()
        self._commit(label, (obj for obj in self.draft.objects if obj.id not in ids or obj.layer_id not in allowed),
                     selection=self.view.selected_ids() - ids)

    def _copy_selection(self):
        models = self._selected_models()
        if models:
            mime = QMimeData()
            mime.setData(CLIPBOARD_MIME, json.dumps([asdict(obj) for obj in models], ensure_ascii=False).encode())
            QApplication.clipboard().setMimeData(mime)

    def _paste_selection(self):
        mime = QApplication.clipboard().mimeData()
        if mime and mime.hasFormat(CLIPBOARD_MIME):
            try:
                data = mime.data(CLIPBOARD_MIME)
                if data.size() > MAX_FILE_BYTES:
                    raise DocumentError("clipboard data is too large")
                decoded = json.loads(bytes(data))
                if not isinstance(decoded, list):
                    raise DocumentError("invalid clipboard data")
                self._clone([MapObject.from_data(item) for item in decoded], "paste")
            except (ValueError, TypeError, RecursionError) as error:
                self._edit_error(error)

    def _duplicate_selection(self):
        self._clone(self._selected_models(), "duplicate")

    def _clone(self, models, label):
        if not models:
            return
        allowed = self._editable_layers()
        stride = self.view.map_scene.grid_size
        try:
            added = []
            for obj in models:
                target = obj.layer_id
                if target not in allowed:
                    target = self.layer_panel.layer_id
                if target not in allowed:
                    raise DocumentError(tr("locked_layer"))
                points = (obj.position[0] + stride, obj.position[1] + stride)
                added.append(replace(obj, id=self._new_id(obj.type), layer_id=target, position=points))
            self._commit(label, (*self.draft.objects, *added), selection=[obj.id for obj in added])
        except DocumentError as error:
            self._edit_error(error)

    def _edit_layer(self, key, visible, locked):
        self._commit("edit_layer", layers=(replace(layer, visible=visible, locked=locked) if layer.id == key else layer
                                           for layer in self.draft.layers))

    def _change_objects(self, label, updates):
        allowed = self._editable_layers()
        self._commit(label, (updates.get(obj.id, obj) if obj.layer_id in allowed else obj
                             for obj in self.draft.objects))

    def _edit_property(self, key, value):
        try:
            updates = {}
            for obj in self._selected_models():
                if key in ("x", "y"):
                    position = list(obj.position)
                    position[key == "y"] = float(value)
                    new = replace(obj, position=position)
                elif key in ("object_width", "object_height", "scale_x", "scale_y"):
                    size = list(obj.size)
                    axis = int(key in ("object_height", "scale_y"))
                    scale = self.view.textures.natural_size(obj.properties.texture_path)[axis] if key.startswith("scale") else 1
                    size[axis] = float(value) * scale
                    new = replace(obj, size=size)
                elif key == "rotation":
                    new = replace(obj, rotation=float(value))
                elif key == "layer":
                    if value not in self._editable_layers():
                        raise DocumentError(tr("locked_layer"))
                    new = replace(obj, layer_id=value)
                elif key == "one_way":
                    new = replace(obj, properties=replace(obj.properties, one_way=value == "true"))
                else:
                    new = replace(obj, properties=replace(obj.properties, texture_path=value))
                updates[obj.id] = new
            self._change_objects("property", updates)
        except ValueError as error:
            self._edit_error(error)
        self._update_selection()

    def _edit_error(self, error):
        self.output.appendPlainText(f"{tr('invalid')} · {error}")
        self.statusBar().showMessage(str(error), 5000)
