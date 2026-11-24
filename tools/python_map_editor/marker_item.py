"""Screen-sized markers drawn over world-space terrain."""

from PySide6.QtCore import QPointF, QRectF, Qt
from PySide6.QtGui import QColor, QPen, QPolygonF
from PySide6.QtWidgets import QGraphicsItem

from region_design import RegionPoint


class MarkerItem(QGraphicsItem):
    def __init__(self, model):
        super().__init__()
        self.setFlag(QGraphicsItem.GraphicsItemFlag.ItemIgnoresTransformations)
        self.setAcceptedMouseButtons(Qt.MouseButton.NoButton)
        self.setZValue(1000)
        self.active = False
        self.issue = False
        self.set_model(model)

    def set_model(self, model):
        self.model = model
        self.point = isinstance(model, RegionPoint)
        self.label = model.point_id if self.point else f"Slot {model.spawn_index + 1}"
        self.setToolTip(f"{model.kind} · {self.label}" if self.point else self.label)
        self.setPos(*model.position)
        self.update()

    def boundingRect(self):
        return QRectF(-11, -24, 22, 26) if self.point else QRectF(-10, 1, 20, 22)

    def paint(self, painter, option, widget=None):
        outline = "#ff626a" if self.issue else "#ffffff" if self.active else "#1c2430"
        painter.setPen(QPen(QColor(outline), 2))
        if self.point:
            entry = self.model.kind == "ENTRY"
            painter.setBrush(QColor("#78d8af" if entry else "#ffc178"))
            tip = QPointF(0, 0)
            if entry:
                painter.drawPolygon(QPolygonF([tip, QPointF(-9, -18), QPointF(9, -18)]))
            else:
                painter.drawPolygon(QPolygonF([tip, QPointF(-9, -10), QPointF(0, -21), QPointF(9, -10)]))
        else:
            painter.setBrush(QColor("#90c9ff"))
            painter.drawEllipse(QRectF(-8, 3, 16, 16))
            painter.setPen(QColor("#132539"))
            painter.drawText(QRectF(-8, 3, 16, 16), Qt.AlignmentFlag.AlignCenter, str(self.model.spawn_index + 1))
