"""Godot-style 2D coordinates rendered by Qt Graphics View."""

import math

from PySide6.QtCore import QLineF, QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QPainter, QPen
from PySide6.QtWidgets import QGraphicsScene, QGraphicsView


class MapScene(QGraphicsScene):
    grid_size = 32
    show_grid = True

    def __init__(self, parent=None):
        super().__init__(parent)
        self.bounds = QRectF()

    def set_bounds(self, width, height):
        self.bounds = QRectF(0, 0, width, height)
        margin = max(width, height, 1024)
        self.setSceneRect(self.bounds.adjusted(-margin, -margin, margin, margin))
        self.invalidate()

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


class MapView(QGraphicsView):
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
