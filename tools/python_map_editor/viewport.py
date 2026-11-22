"""Godot-style 2D coordinates rendered by Qt Graphics View."""

from dataclasses import replace
import math

from PySide6.QtCore import QLineF, QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter, QPainterPath, QPen
from PySide6.QtWidgets import QGraphicsItem, QGraphicsScene, QGraphicsView

from graphics import ObjectItem, TextureCache
from objects import HANDLES, MAX_OBJECTS, MIN_SIZE, rotate, snap


class MapScene(QGraphicsScene):
    grid_size = 32
    show_grid = True

    def __init__(self, parent=None):
        super().__init__(parent)
        self.bounds = QRectF()

    def set_bounds(self, width, height):
        self.bounds = QRectF(0, 0, width, height)
        self.refresh_world_rect()
        self.invalidate()

    def refresh_world_rect(self):
        margin = max(self.bounds.width(), self.bounds.height(), 1024)
        surrounding = self.bounds.adjusted(-margin, -margin, margin, margin)
        self.setSceneRect(surrounding.united(self.itemsBoundingRect()))

    def drawBackground(self, painter, rect):
        painter.fillRect(rect, QColor("#171b24"))
        inside = rect.intersected(self.bounds)
        painter.fillRect(inside, QColor("#202631"))
        if self.show_grid:
            scale = painter.worldTransform().m11()
            stride = self.grid_size * (4 if scale < 0.45 else 1)
            x = math.floor(inside.left() / stride) * stride
            y = math.floor(inside.top() / stride) * stride
            vertical = [QLineF(x0, inside.top(), x0, inside.bottom())
                        for x0 in range(x, math.ceil(inside.right()), stride) if x0 >= inside.left()]
            horizontal = [QLineF(inside.left(), y0, inside.right(), y0)
                          for y0 in range(y, math.ceil(inside.bottom()), stride) if y0 >= inside.top()]
            painter.setPen(QPen(QColor("#323b4a"), 0))
            painter.drawLines(vertical + horizontal)
        painter.setPen(QPen(QColor("#66bda9"), 0))
        painter.drawRect(self.bounds)
        painter.setPen(QPen(QColor("#8ed7c6"), 0))
        painter.drawLine(QLineF(-12, 0, 12, 0))
        painter.drawLine(QLineF(0, -12, 0, 12))


class CanvasView(QGraphicsView):
    zoom_changed = Signal(float)
    world_position_changed = Signal(QPointF)
    MIN_ZOOM = 0.02
    MAX_ZOOM = 8.0

    def __init__(self, parent=None):
        super().__init__(parent)
        self.map_scene = MapScene(self)
        self.setScene(self.map_scene)
        self.setObjectName("mapViewport")
        self.setMouseTracking(True)
        self.setRenderHint(QPainter.RenderHint.Antialiasing)
        self.setTransformationAnchor(QGraphicsView.ViewportAnchor.NoAnchor)
        self._drag_button = None
        self._drag_pos = None
        self._pan_mode = False

    @property
    def zoom(self):
        return self.transform().m11()

    def set_bounds(self, width, height):
        self.map_scene.set_bounds(width, height)

    def set_grid_visible(self, visible):
        self.map_scene.show_grid = visible
        self.map_scene.invalidate()

    def set_pan_mode(self, enabled):
        self._pan_mode = enabled
        self.viewport().setCursor(Qt.CursorShape.OpenHandCursor if enabled else Qt.CursorShape.ArrowCursor)

    def set_zoom(self, value, anchor=None):
        value = min(self.MAX_ZOOM, max(self.MIN_ZOOM, value))
        if anchor is None:
            anchor = self.viewport().rect().center()
        previous = self.mapToScene(anchor)
        self.scale(value / self.zoom, value / self.zoom)
        offset = self.mapToScene(anchor) - previous
        self.translate(offset.x(), offset.y())
        self.zoom_changed.emit(self.zoom)

    def fit_map(self):
        area = self.map_scene.bounds
        if not area.isEmpty():
            available = self.viewport().rect().adjusted(30, 30, -30, -30)
            self.set_zoom(min(available.width() / area.width(), available.height() / area.height()))
            self.centerOn(area.center())

    def wheelEvent(self, event):
        delta = event.angleDelta().y()
        if delta:
            self.set_zoom(self.zoom * (1.15 ** (delta / 120)), event.position().toPoint())
            event.accept()
        else:
            super().wheelEvent(event)

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.MiddleButton or (
                self._pan_mode and event.button() == Qt.MouseButton.LeftButton):
            self._drag_button = event.button()
            self._drag_pos = event.position().toPoint()
            self.viewport().setCursor(Qt.CursorShape.ClosedHandCursor)
            event.accept()
        else:
            super().mousePressEvent(event)

    def mouseMoveEvent(self, event):
        position = event.position().toPoint()
        if self._drag_button is not None and event.buttons() & self._drag_button:
            delta = position - self._drag_pos
            horizontal, vertical = self.horizontalScrollBar(), self.verticalScrollBar()
            horizontal.setValue(horizontal.value() - delta.x())
            vertical.setValue(vertical.value() - delta.y())
            self._drag_pos = position
            event.accept()
        else:
            if self._drag_button is not None:
                self._drag_button = None
                self.set_pan_mode(self._pan_mode)
            super().mouseMoveEvent(event)
        self.world_position_changed.emit(self.mapToScene(position))

    def mouseReleaseEvent(self, event):
        if event.button() == self._drag_button:
            self._drag_button = None
            self.set_pan_mode(self._pan_mode)
            event.accept()
        else:
            super().mouseReleaseEvent(event)

LIBRARY_MIME = "application/x-rtc-library"


class MapView(CanvasView):
    gesture_finished = Signal(str, object)
    preview_changed = Signal()
    asset_dropped = Signal(object, QPointF)

    def __init__(self):
        super().__init__()
        self.textures = TextureCache()
        self.objects = {}
        self.tool = "select"
        self.snap_enabled = True
        self.brush_spacing = 32
        self.gesture = None
        self.setAcceptDrops(True)
        self.viewport().setAcceptDrops(True)
        self.map_scene.selectionChanged.connect(self.viewport().update)

    def sync_document(self, document, selection):
        self.cancel_gesture()
        scene = self.map_scene
        old = scene.blockSignals(True)
        try:
            objects = {model.id: model for model in document.objects}
            layers = {layer.id: (index, layer) for index, layer in enumerate(document.layers)}
            for key in self.objects.keys() - objects.keys():
                scene.removeItem(self.objects.pop(key))
            for key, model in objects.items():
                item = self.objects.get(key)
                order, layer = layers[model.layer_id]
                if item is None:
                    item = self.objects[key] = ObjectItem(model, self.textures)
                    scene.addItem(item)
                item.set_model(model)
                item.set_layer(layer, order)
                item.setSelected(key in selection and layer.visible and not layer.locked)
        finally:
            scene.blockSignals(old)
        scene.refresh_world_rect()
        self.viewport().update()

    def selected_ids(self):
        return frozenset(item.model.id for item in self.map_scene.selectedItems() if isinstance(item, ObjectItem))

    def set_tool(self, tool):
        self.cancel_gesture()
        self.tool = tool
        self.set_pan_mode(tool == "pan")

    def snapped(self, point, stride=None):
        stride = self.map_scene.grid_size if stride is None and self.snap_enabled else stride
        return QPointF(snap(point.x(), stride), snap(point.y(), stride))

    def hit_object(self, position):
        flag = QGraphicsItem.GraphicsItemFlag.ItemIsSelectable
        return next((item for item in self.items(position) if isinstance(item, ObjectItem)
                     and item.flags() & flag), None)

    def _handles(self):
        items = self.map_scene.selectedItems()
        if self.tool == "select" and len(items) == 1 and items[0].model.type == "platform":
            return items[0], HANDLES
        return None, ()

    def drawForeground(self, painter, rect):
        item, handles = self._handles()
        radius = 4 / self.zoom
        painter.setPen(QPen(QColor("#17232a"), 0))
        painter.setBrush(QColor("#a3f0df"))
        for direction in handles:
            point = item.handle_point(direction)
            painter.drawRect(QRectF(point.x() - radius, point.y() - radius, radius * 2, radius * 2))
        if self.gesture and self.gesture["mode"] in ("rectangle", "box"):
            g = self.gesture
            painter.setPen(QPen(QColor("#a3f0df"), 0, Qt.PenStyle.DashLine))
            painter.setBrush(QColor(99, 193, 171, 45))
            painter.drawRect(QRectF(g["anchor"], g["current"]).normalized())
        if self.gesture and self.gesture["mode"] == "paint":
            for x, y in self.gesture["points"]:
                painter.drawEllipse(QPointF(x, y), radius, radius)

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton or self.tool == "pan":
            if event.button() == Qt.MouseButton.MiddleButton:
                self.cancel_gesture()
            super().mousePressEvent(event)
            return
        self.setFocus()
        position = event.position().toPoint()
        point = self.mapToScene(position)
        mode = self.tool
        data = {}
        if mode == "select":
            item, handles = self._handles()
            direction = None
            if item is not None:
                inner = item.rect().adjusted(item.rect().width() / 4, item.rect().height() / 4,
                                             -item.rect().width() / 4, -item.rect().height() / 4)
                if not inner.contains(item.mapFromScene(point)):
                    distances = [(self.mapFromScene(item.handle_point(handle)) - position).manhattanLength()
                                 for handle in handles]
                    closest = min(range(len(handles)), key=distances.__getitem__)
                    if distances[closest] <= 9:
                        direction = handles[closest]
            if direction:
                mode = "resize"
                data = {"before": {item.model.id: item.model}, "direction": direction,
                        "offset": item.handle_point(direction) - point}
            else:
                item = self.hit_object(position)
                extend = event.modifiers() & (Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.ShiftModifier)
                if item is None:
                    mode = "box"
                    if not extend:
                        self.map_scene.clearSelection()
                else:
                    if extend:
                        item.setSelected(not item.isSelected())
                    elif not item.isSelected():
                        self.map_scene.clearSelection()
                        item.setSelected(True)
                    if not item.isSelected():
                        event.accept()
                        return
                    mode = "move"
                    data = {"before": {key: self.objects[key].model for key in self.selected_ids()},
                            "primary": item.model.id}
        anchor = self.snapped(point) if mode == "rectangle" else point
        self.gesture = {"mode": mode, "start": position, "anchor": anchor, "current": anchor,
                        "active": False, "points": {}, "removed": set(), **data}
        if mode in ("paint", "erase"):
            self._update_gesture(position)
        event.accept()

    def _update_gesture(self, position):
        g = self.gesture
        point = self.mapToScene(position)
        mode = g["mode"]
        if mode in ("move", "resize", "box") and not g["active"]:
            if (position - g["start"]).manhattanLength() < 4:
                return
            g["active"] = True
        if mode == "move":
            primary = QPointF(*g["before"][g["primary"]].position)
            delta = self.snapped(primary + point - g["anchor"]) - primary
            for key, obj in g["before"].items():
                self.objects[key].setPos(QPointF(*obj.position) + delta)
            self.preview_changed.emit()
        elif mode == "resize":
            obj, = g["before"].values()
            local = rotate(((point + g["offset"]) - QPointF(*obj.position)).toTuple(), -obj.rotation)
            size = list(obj.size)
            center = [0.0, 0.0]
            for axis, direction in enumerate(g["direction"]):
                if direction:
                    fixed = -direction * size[axis] / 2
                    stride = self.map_scene.grid_size if self.snap_enabled else None
                    size[axis] = max(MIN_SIZE, snap(direction * (local[axis] - fixed), stride))
                    center[axis] = fixed + direction * size[axis] / 2
            dx, dy = rotate(center, obj.rotation)
            item = self.objects[obj.id]
            item.setRect(-size[0] / 2, -size[1] / 2, *size)
            item.setPos(obj.position[0] + dx, obj.position[1] + dy)
            self.preview_changed.emit()
        elif mode in ("paint", "erase"):
            # Sample fast moves as well as discrete mouse events, including the release.
            previous = g["current"]
            stride = self.map_scene.grid_size if self.snap_enabled else self.brush_spacing
            delta = point - previous
            spacing = stride / 2 if mode == "paint" else 4 / self.zoom
            count = max(1, math.ceil(math.hypot(delta.x(), delta.y()) / spacing))
            for index in range(1, count + 1):
                sample = previous + delta * (index / count)
                if mode == "paint":
                    if len(g["points"]) < MAX_OBJECTS:
                        g["points"][self.snapped(sample, stride).toTuple()] = None
                else:
                    item = self.hit_object(self.mapFromScene(sample))
                    if item and item.model.id not in g["removed"]:
                        g["removed"].add(item.model.id)
                        item.setOpacity(0.24)
        g["current"] = self.snapped(point) if mode == "rectangle" else point
        self.viewport().update()

    def mouseMoveEvent(self, event):
        if self.gesture and not self._drag_button:
            position = event.position().toPoint()
            if event.buttons() & Qt.MouseButton.LeftButton:
                self._update_gesture(position)
            self.world_position_changed.emit(self.mapToScene(position))
            event.accept()
        else:
            super().mouseMoveEvent(event)

    def mouseReleaseEvent(self, event):
        if not self.gesture or event.button() != Qt.MouseButton.LeftButton:
            super().mouseReleaseEvent(event)
            return
        self._update_gesture(event.position().toPoint())
        g = self.gesture
        mode = g["mode"]
        payload = None
        if mode in ("move", "resize") and g["active"]:
            payload = {}
            for key in g["before"]:
                item = self.objects[key]
                payload[key] = (item.pos().toTuple(), (item.rect().width(), item.rect().height()))
        elif mode == "rectangle":
            rect = QRectF(g["anchor"], g["current"]).normalized()
            if (event.position().toPoint() - g["start"]).manhattanLength() >= 4:
                payload = rect.center().toTuple(), (max(MIN_SIZE, rect.width()), max(MIN_SIZE, rect.height()))
        elif mode == "paint":
            payload = tuple(g["points"])
        elif mode == "erase":
            payload = g["removed"]
        elif mode == "box" and g["active"]:
            path = QPainterPath()
            path.addRect(QRectF(g["anchor"], g["current"]).normalized())
            self.map_scene.setSelectionArea(path, Qt.ItemSelectionOperation.AddToSelection,
                                            Qt.ItemSelectionMode.IntersectsItemShape)
        self.cancel_gesture()
        if payload:
            self.gesture_finished.emit(mode, payload)
        event.accept()

    def cancel_gesture(self):
        if self.gesture is None:
            return
        g, self.gesture = self.gesture, None
        for key, model in g.get("before", {}).items():
            item = self.objects[key]
            item.model = None
            item.set_model(model)
        for key in g["removed"]:
            self.objects[key].setOpacity(1)
        self.preview_changed.emit()
        self.viewport().update()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape:
            if self.gesture:
                self.cancel_gesture()
            else:
                self.map_scene.clearSelection()
            event.accept()
        else:
            super().keyPressEvent(event)

    def dragEnterEvent(self, event):
        if event.mimeData().hasFormat(LIBRARY_MIME):
            event.acceptProposedAction()

    def dragMoveEvent(self, event):
        if event.mimeData().hasFormat(LIBRARY_MIME):
            event.acceptProposedAction()

    def dropEvent(self, event):
        if event.mimeData().hasFormat(LIBRARY_MIME):
            self.asset_dropped.emit(bytes(event.mimeData().data(LIBRARY_MIME)),
                                    self.snapped(self.mapToScene(event.position().toPoint())))
            event.acceptProposedAction()
