"""Object library, layer list and selection inspector."""

from dataclasses import dataclass
import json
from pathlib import Path

from PySide6.QtCore import QMimeData, QPoint, QSignalBlocker, Qt, Signal
from PySide6.QtGui import QColor, QDrag, QIcon, QPixmap
from PySide6.QtWidgets import (
    QAbstractItemView, QComboBox, QFormLayout, QLineEdit,
    QTreeWidget, QTreeWidgetItem, QVBoxLayout, QWidget,
)

from objects import DocumentError, OBJECT_TYPES, validate_texture
from strings import tr
from viewport import LIBRARY_MIME

ROLE = Qt.ItemDataRole.UserRole


@dataclass(frozen=True)
class Asset:
    type: str
    path: str = ""

    def __post_init__(self):
        validate_texture(self.path)
        if self.type not in OBJECT_TYPES or self.path and self.type != "decoration":
            raise DocumentError("invalid library asset")

    @property
    def label(self):
        return Path(self.path).stem if self.path else tr(self.type)


class LibraryTree(QTreeWidget):
    def mimeTypes(self):
        return [LIBRARY_MIME]

    def startDrag(self, _supported_actions):
        items = self.selectedItems()
        if items:
            drag = QDrag(self)
            drag.setMimeData(self.mimeData(items))
            if not items[0].icon(0).isNull():
                drag.setPixmap(items[0].icon(0).pixmap(40, 32))
            drag.exec(Qt.DropAction.CopyAction)

    def mimeData(self, items):
        mime = QMimeData()
        if items and (asset := items[0].data(0, ROLE)):
            mime.setData(LIBRARY_MIME, json.dumps([asset.type, asset.path]).encode())
        return mime


class LibraryPanel(QWidget):
    asset_selected = Signal(object)

    def __init__(self, textures):
        super().__init__()
        self.textures = textures
        self.assets = ()
        self.search = QLineEdit(placeholderText=tr("asset_search"))
        self.tree = LibraryTree()
        self.tree.setHeaderHidden(True)
        self.tree.setDragEnabled(True)
        self.tree.setDragDropMode(QAbstractItemView.DragDropMode.DragOnly)
        self.tree.currentItemChanged.connect(self._select)
        self.search.textChanged.connect(self._filter)
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.addWidget(self.search)
        layout.addWidget(self.tree)
        self.set_paths(())

    @property
    def asset(self):
        item = self.tree.currentItem()
        return item.data(0, ROLE) if item is not None else None

    def set_paths(self, paths):
        previous = self.asset
        self.tree.clear()
        self.groups = {kind: QTreeWidgetItem(self.tree, [tr(f"{kind}_group")]) for kind in OBJECT_TYPES}
        self.assets = [Asset("platform"), Asset("decoration"), *(Asset("decoration", path) for path in paths)]
        for asset in self.assets:
            group = self.groups[asset.type]
            item = QTreeWidgetItem(group, [asset.label])
            item.setData(0, ROLE, asset)
            item.setToolTip(0, asset.path or tr(asset.type))
            if not asset.path:
                preview = QPixmap(24, 16)
                preview.fill(QColor("#81baa9" if asset.type == "platform" else "#ac8cbb"))
                item.setIcon(0, QIcon(preview))
            if asset == previous or previous is None and asset.type == "platform":
                self.tree.setCurrentItem(item)
        for group in self.groups.values():
            group.setFlags(group.flags() & ~Qt.ItemFlag.ItemIsDragEnabled & ~Qt.ItemFlag.ItemIsSelectable)
            group.setExpanded(True)
        self._filter(self.search.text())

    def _filter(self, text):
        query = text.strip().casefold()
        for group in self.groups.values():
            found = False
            for index in range(group.childCount()):
                item = group.child(index)
                asset = item.data(0, ROLE)
                match = query in f"{asset.label} {asset.type} {group.text(0)} {asset.path}".casefold()
                item.setHidden(not match)
                found |= match
            group.setHidden(not found)
        self.refresh_icons()

    def refresh_icons(self):
        # Decode only visible rows. The viewport shares the bounded preview cache.
        point = QPoint(5, 0)
        height = self.tree.viewport().height()
        while point.y() < height:
            item = self.tree.itemAt(point)
            asset = item.data(0, ROLE) if item else None
            if asset and asset.path and item.icon(0).isNull():
                preview = self.textures.lookup(asset.path)
                if preview.isNull():
                    preview = QPixmap(24, 16)
                    preview.fill(QColor("#ac8cbb"))
                item.setIcon(0, QIcon(preview))
            bottom = self.tree.visualItemRect(item).bottom() if item else point.y()
            point.setY(max(point.y() + 1, bottom + 1))

    def showEvent(self, event):
        super().showEvent(event)
        self.refresh_icons()

    def _select(self, current, _previous):
        if current and (asset := current.data(0, ROLE)):
            self.asset_selected.emit(asset)


class LayerPanel(QTreeWidget):
    layer_edited = Signal(str, bool, bool)

    def __init__(self):
        super().__init__()
        self.setHeaderLabels([tr("layer"), tr("visible"), tr("locked")])
        self.setRootIsDecorated(False)
        self.setColumnWidth(0, 98)
        self.setColumnWidth(1, 44)
        self.itemChanged.connect(self._edited)

    @property
    def layer_id(self):
        item = self.currentItem()
        return item.data(0, ROLE) if item else None

    def populate(self, layers, counts):
        current_id = self.layer_id
        existing = [self.topLevelItem(index) for index in range(self.topLevelItemCount())]
        with QSignalBlocker(self):
            if [item.data(0, ROLE) for item in existing] != [layer.id for layer in layers]:
                self.clear()
                existing = [QTreeWidgetItem(self) for layer in layers]
            for item, layer in zip(existing, layers):
                name = tr(f"layer_{layer.id}", layer.name)
                item.setText(0, f"{name} ({counts[layer.id]})")
                item.setData(0, ROLE, layer.id)
                for column, value in ((1, layer.visible), (2, layer.locked)):
                    item.setCheckState(column, Qt.CheckState.Checked if value else Qt.CheckState.Unchecked)
                if layer.id == current_id or self.currentItem() is None:
                    self.setCurrentItem(item)

    def select_layer(self, layer_id):
        for index in range(self.topLevelItemCount()):
            item = self.topLevelItem(index)
            if item.data(0, ROLE) == layer_id:
                self.setCurrentItem(item)
                break

    def _edited(self, item, column):
        if column in (1, 2):
            checked = Qt.CheckState.Checked
            self.layer_edited.emit(item.data(0, ROLE), item.checkState(1) == checked, item.checkState(2) == checked)


class ObjectInspector(QWidget):
    property_edited = Signal(str, str)

    def __init__(self):
        super().__init__()
        self.form = QFormLayout(self)
        self.form.setContentsMargins(0, 0, 0, 0)
        self.fields = {}
        for key in ("object_id", "x", "y", "object_width", "object_height", "rotation", "scale_x", "scale_y", "texture"):
            field = self.fields[key] = QLineEdit()
            field.setReadOnly(key == "object_id")
            field.editingFinished.connect(lambda key=key: self._submit(key))
            self.form.addRow(tr(key), field)
        for key in ("layer", "one_way"):
            field = self.fields[key] = QComboBox()
            field.activated.connect(lambda _index, key=key: self._combo(key))
            self.form.addRow(tr(key), field)

    def _submit(self, key):
        field = self.fields[key]
        if field.isModified() and not field.isReadOnly():
            field.setModified(False)
            self.property_edited.emit(key, field.text())

    def _combo(self, key):
        value = self.fields[key].currentData()
        if value is not None:
            self.property_edited.emit(key, str(value))

    def populate(self, models, layers, image_size, preview=False):
        self.setVisible(bool(models))
        if not models:
            return
        platforms = all(obj.type == "platform" for obj in models)
        decorations = all(obj.type == "decoration" for obj in models)
        base_sizes = [image_size(obj.properties.texture_path) for obj in models] if decorations else []
        values = {
            "object_id": [obj.id for obj in models],
            "x": [obj.position[0] for obj in models],
            "y": [obj.position[1] for obj in models],
            "object_width": [obj.size[0] for obj in models],
            "object_height": [obj.size[1] for obj in models],
            "rotation": [obj.rotation for obj in models],
            "scale_x": [obj.size[0] / base[0] for obj, base in zip(models, base_sizes)],
            "scale_y": [obj.size[1] / base[1] for obj, base in zip(models, base_sizes)],
            "texture": [obj.properties.texture_path for obj in models] if decorations else [],
        }
        for key, entries in values.items():
            field = self.fields[key]
            self.form.setRowVisible(field, bool(entries))
            if not entries or field.hasFocus() and field.isModified() and not preview:
                continue
            common = all(entry == entries[0] for entry in entries)
            field.setPlaceholderText("" if common else tr("mixed"))
            first = entries[0]
            field.setText((format(first, ".8g") if isinstance(first, (int, float)) else first) if common else "")
        destinations = [(tr(f"layer_{layer.id}", layer.name), layer.id)
                        for layer in layers if layer.visible and not layer.locked]
        self._options("layer", destinations, [obj.layer_id for obj in models])
        self._options("one_way", [(tr("solid"), "false"), (tr("one_way_enabled"), "true")],
                      [str(obj.properties.one_way).lower() for obj in models] if platforms else [])

    def _options(self, key, options, values):
        combo = self.fields[key]
        self.form.setRowVisible(combo, bool(values))
        with QSignalBlocker(combo):
            combo.clear()
            if not values:
                return
            common = all(value == values[0] for value in values)
            if not common:
                combo.addItem(tr("mixed"))
            for label, value in options:
                combo.addItem(label, value)
            if common:
                combo.setCurrentIndex(combo.findData(values[0]))

