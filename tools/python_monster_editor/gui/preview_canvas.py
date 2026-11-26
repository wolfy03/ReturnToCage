"""The preview canvas: one frame in actor space with collision shapes over it.

Reusable on its own - the animation workspace owns one, and an attack-timeline view can own another. The
canvas knows nothing about documents, sessions, files or undo:

* it is *given* a pixmap, a frame size, the presentation block and ``(slot, shape)`` pairs;
* it *reports* intent through signals: ``shape_selected``, ``shape_committed`` (one finished drag),
  ``drag_cancelled``, ``zoom_requested``.

Coordinates, in the order they are applied (all formulas are ``rtcmonster.geometry``'s):

    frame pixel --sprite_to_actor(frame size, visual_offset, visual_scale, default facing, facing)-->
    actor-local point --(* zoom, + widget centre, + pan)--> widget pixel

Shapes are stored in actor space *as authored, facing right*. With ``facing`` -1 they are drawn through
``mirror_shape`` and a dragged point goes back through ``mirror_point`` before it is used, so what is
stored never depends on which way the preview happens to face. Zoom and pan are view state only and
never reach a shape; ``visual_scale`` scales the picture only and never a shape.

A drag is a session bound to what was on screen when it started (the caller's ``context`` token, the
slot, the facing and the shape). If any of those changes underneath it - another document, clip or
frame, an undo, a flip, the shape being deleted - the drag is cancelled, not applied to whatever is
there now. A cancelled drag reports nothing to commit.
"""

from dataclasses import dataclass
import math

from PySide6.QtCore import QEvent, QPointF, QRectF, Qt, Signal
from PySide6.QtGui import QColor, QImage, QPainter, QPen, QTransform
from PySide6.QtWidgets import QWidget

from application import animation as logic
from rtcmonster.geometry import mirror_point, mirror_shape, shape_bounds, sprite_to_actor

KIND_COLORS = {"body": "#5aa9e6", "hurtbox": "#7fd18b", "override": "#d9a03f", "hitbox": "#e0605f"}
HANDLE_PIXELS = 7
MIN_ZOOM, MAX_ZOOM = 0.25, 32.0
# Authored coordinates are limited to +-4096 by the schema; a drag far outside the widget stays inside it.
COORDINATE_LIMIT = 4096.0


@dataclass(frozen=True)
class DragSession:
    """Everything a drag was started against. Compared again before anything is committed."""
    context: object
    slot: object
    facing: int
    mode: str                # "move" or "resize"
    handle: object           # edge name for a resize, else None
    start: tuple             # authored actor point where the button went down
    original: dict           # the shape as it was


def usable_shape(shape):
    """True when a shape can be drawn: finite numbers and a positive extent."""
    try:
        left, top, right, bottom = shape_bounds(shape)
    except (ValueError, KeyError, TypeError):
        return False
    return all(math.isfinite(value) for value in (left, top, right, bottom)) and right > left and bottom > top


class PreviewCanvas(QWidget):
    shape_selected = Signal(object)            # ShapeSlot or None
    shape_committed = Signal(object, dict)     # ShapeSlot, new shape (authored space) - once per finished drag
    drag_started = Signal(object)              # ShapeSlot
    drag_cancelled = Signal(str)               # why
    zoom_requested = Signal(float)

    def __init__(self):
        super().__init__()
        self.setMinimumSize(200, 160)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.ClickFocus)
        self.zoom = 4.0
        self.pan = QPointF(0, 0)               # widget pixels; view state only
        self.facing = 1
        self.pixmap = None
        self.frame_size = None
        self.presentation = None
        self.shapes = []                       # (ShapeSlot, shape) in drawing order
        self.selected = None
        self.highlighted = None                # a slot another view points at (drawn emphasised, not selected)
        self.editable = False
        self.message = ""
        self.context = None
        self.background = QColor("#1b202a")
        self.guides = True                     # the origin cross and the frame outline
        self._drag = None                      # DragSession
        self._preview = None
        self._pan_from = None

    # ---- content
    def show_frame(self, pixmap, frame_size, presentation, shapes, editable, message="", context=None):
        """Replace what is shown. ``context`` identifies it (document state, clip, frame): a drag that was
        started against another context, or whose shape is gone or different now, is cancelled."""
        shapes = [(slot, shape) for slot, shape in shapes]
        if self._drag is not None:
            current = next((shape for slot, shape in shapes if slot == self._drag.slot), None)
            if context != self._drag.context:
                self.cancel_drag("context")
            elif current is None or not editable:
                self.cancel_drag("shape")
            elif logic.rounded_shape(current) != logic.rounded_shape(self._drag.original):
                self.cancel_drag("changed")
        self.pixmap, self.frame_size, self.presentation = pixmap, frame_size, presentation
        self.shapes, self.editable, self.message, self.context = shapes, editable, message, context
        if self.selected is not None and self.selected not in [slot for slot, _shape in self.shapes]:
            self.selected = None
        self.update()

    def select(self, slot):
        if self._drag is not None and slot != self._drag.slot:
            self.cancel_drag("selection")
        self.selected = slot
        self.update()

    def highlight(self, slot):
        self.highlighted = slot
        self.update()

    def set_facing(self, facing):
        facing = -1 if facing < 0 else 1
        if facing != self.facing:
            self.cancel_drag("facing")
            self.facing = facing
            self.update()

    def set_zoom(self, zoom):
        if isinstance(zoom, (int, float)) and math.isfinite(zoom):
            self.zoom = min(MAX_ZOOM, max(MIN_ZOOM, float(zoom)))
            self.update()

    def reset_view(self):
        self.pan = QPointF(0, 0)
        self.update()

    def shape_of(self, slot):
        if self._preview is not None and self._drag is not None and slot == self._drag.slot:
            return self._preview
        for candidate, shape in self.shapes:
            if candidate == slot:
                return shape
        return None

    # ---- drag state
    @property
    def dragging(self):
        return self._drag is not None

    def cancel_drag(self, reason="cancelled"):
        """Drop the drag in progress, if any. Nothing is committed. Returns True when there was one."""
        if self._drag is None:
            return False
        self._drag = self._preview = None
        self.update()
        self.drag_cancelled.emit(reason)
        return True

    # ---- coordinates
    def origin(self):
        return QPointF(self.width() / 2 + self.pan.x(), self.height() / 2 + self.pan.y())

    def to_view(self, point):
        origin = self.origin()
        return QPointF(origin.x() + point[0] * self.zoom, origin.y() + point[1] * self.zoom)

    def to_actor(self, position):
        origin = self.origin()
        return [(position.x() - origin.x()) / self.zoom, (position.y() - origin.y()) / self.zoom]

    def to_authored(self, position):
        """Widget position -> actor point in the authored (facing right) space, kept inside the schema's range."""
        x, y = mirror_point(self.to_actor(position), self.facing)
        return [max(-COORDINATE_LIMIT, min(COORDINATE_LIMIT, x)), max(-COORDINATE_LIMIT, min(COORDINATE_LIMIT, y))]

    def frame_rect(self):
        """Where the frame is drawn, in widget coordinates, or None."""
        if self.frame_size is None or self.presentation is None:
            return None
        try:
            first = sprite_to_actor([0, 0], self.frame_size, self.presentation, self.facing)
            second = sprite_to_actor(list(self.frame_size), self.frame_size, self.presentation, self.facing)
        except (ValueError, TypeError):
            return None
        return QRectF(self.to_view(first), self.to_view(second)).normalized()

    def picture_mirrored(self):
        """True when the pixmap is drawn flipped: the facing, turned once more for art that faces left."""
        mirrored = self.facing < 0
        if self.presentation is not None and not self.presentation["faces_right_by_default"]:
            mirrored = not mirrored
        return mirrored

    def view_shape_rect(self, shape):
        left, top, right, bottom = shape_bounds(mirror_shape(shape, self.facing))
        return QRectF(self.to_view([left, top]), self.to_view([right, bottom]))

    def handle_positions(self, slot):
        """``{handle: QPointF}`` of a shape's edge handles on screen, named in authored space."""
        shape = self.shape_of(slot)
        if shape is None or not usable_shape(shape):
            return {}
        return {handle: self.to_view(mirror_point(point, self.facing))
                for handle, point in logic.handle_points(shape).items()}

    # ---- painting
    def render_image(self):
        """What the canvas shows, as an image of exactly ``width x height`` pixels (no screen scaling)."""
        image = QImage(self.size(), QImage.Format.Format_ARGB32)
        image.fill(Qt.GlobalColor.transparent)
        painter = QPainter(image)
        self.paint(painter)
        painter.end()
        return image

    def paintEvent(self, _event):
        painter = QPainter(self)
        self.paint(painter)
        painter.end()

    def paint(self, painter):
        if self.background.alpha() > 0:
            painter.fillRect(self.rect(), self.background)
        rect = self.frame_rect()
        if self.pixmap is not None and rect is not None:
            picture = self.pixmap.transformed(QTransform().scale(-1, 1)) if self.picture_mirrored() else self.pixmap
            painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, False)
            painter.drawPixmap(rect, picture, QRectF(picture.rect()))
            if self.guides:
                painter.setPen(QPen(QColor("#44506a"), 1, Qt.PenStyle.DotLine))
                painter.drawRect(rect)
        if self.guides:
            centre = self.to_view([0, 0])
            painter.setPen(QPen(QColor("#9aa5b8"), 1))
            painter.drawLine(QPointF(centre.x() - 8, centre.y()), QPointF(centre.x() + 8, centre.y()))
            painter.drawLine(QPointF(centre.x(), centre.y() - 8), QPointF(centre.x(), centre.y() + 8))
        for slot, shape in self.shapes:
            shape = self.shape_of(slot) or shape
            if not usable_shape(shape):
                continue                        # a broken value is validation's to report, not a crash here
            colour = QColor(KIND_COLORS.get(slot.kind, "#cccccc"))
            chosen = slot == self.selected
            marked = chosen or slot == self.highlighted
            painter.setPen(QPen(colour, 2 if marked else 1,
                                Qt.PenStyle.SolidLine if slot.enabled else Qt.PenStyle.DashLine))
            fill = QColor(colour)
            fill.setAlpha(70 if marked else 28)
            painter.setBrush(fill)
            bounds = self.view_shape_rect(shape)
            if shape["type"] == "circle":
                painter.drawEllipse(bounds)
            else:
                painter.drawRect(bounds)
            if chosen and self.editable:
                painter.setBrush(QColor("#f2f2f2"))
                painter.setPen(QPen(QColor("#202020"), 1))
                for position in self.handle_positions(slot).values():
                    painter.drawRect(QRectF(position.x() - HANDLE_PIXELS / 2, position.y() - HANDLE_PIXELS / 2,
                                            HANDLE_PIXELS, HANDLE_PIXELS))
        painter.setBrush(Qt.BrushStyle.NoBrush)
        if self.message:
            painter.setPen(QColor("#c9a227"))
            painter.drawText(self.rect().adjusted(8, 6, -8, -6), Qt.AlignmentFlag.AlignTop | Qt.AlignmentFlag.AlignLeft,
                             self.message)

    # ---- input
    def _hit(self, position):
        """``(slot, handle or None)`` under a widget position.

        The selected shape wins - its handles first, then its area - so a shape chosen in the list can be
        dragged even where another shape lies over it. Otherwise the shape drawn last is on top.
        """
        if self.selected is not None:
            if self.editable:
                for handle, point in self.handle_positions(self.selected).items():
                    if abs(point.x() - position.x()) <= HANDLE_PIXELS and abs(point.y() - position.y()) <= HANDLE_PIXELS:
                        return self.selected, handle
            chosen = self.shape_of(self.selected)
            if chosen is not None and usable_shape(chosen) and self.view_shape_rect(chosen).contains(position):
                return self.selected, None
        for slot, shape in reversed(self.shapes):        # the shape drawn last is on top
            shape = self.shape_of(slot) or shape
            if usable_shape(shape) and self.view_shape_rect(shape).contains(position):
                return slot, None
        return None, None

    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.MiddleButton:
            self.cancel_drag("pan")
            self._pan_from = (event.position(), QPointF(self.pan))
            return
        if event.button() != Qt.MouseButton.LeftButton:
            self.cancel_drag("button")           # any other button abandons the drag
            return
        self.cancel_drag("restart")
        slot, handle = self._hit(event.position())
        if slot != self.selected:
            self.selected = slot
            self.shape_selected.emit(slot)
        shape = self.shape_of(slot) if slot is not None else None
        if shape is not None and self.editable and usable_shape(shape):
            self._drag = DragSession(self.context, slot, self.facing, "resize" if handle else "move", handle,
                                     tuple(self.to_authored(event.position())), dict(shape))
            self.drag_started.emit(slot)
        self.update()

    def mouseMoveEvent(self, event):
        if self._pan_from is not None:
            start, pan = self._pan_from
            self.pan = QPointF(pan.x() + event.position().x() - start.x(), pan.y() + event.position().y() - start.y())
            self.update()
            return
        self._drag_to(event.position())

    def _drag_to(self, position):
        drag = self._drag
        if drag is None:
            return
        point = self.to_authored(position)
        if drag.mode == "resize":
            self._preview = logic.resized_shape(drag.original, drag.handle, point)
        else:
            self._preview = logic.moved_shape(drag.original, (point[0] - drag.start[0], point[1] - drag.start[1]))
        self.update()

    def mouseReleaseEvent(self, event):
        if event.button() == Qt.MouseButton.MiddleButton:
            self._pan_from = None
            return
        drag = self._drag
        if event.button() != Qt.MouseButton.LeftButton or drag is None:
            return
        if self._preview is not None or tuple(self.to_authored(event.position())) != drag.start:
            self._drag_to(event.position())       # the gesture ends where the button was released
        preview = self._preview
        self._drag = self._preview = None
        self.update()
        # The same checks as show_frame, once more: nothing may have changed between the last move and now.
        current = next((shape for slot, shape in self.shapes if slot == drag.slot), None)
        if current is None or drag.context != self.context or drag.facing != self.facing \
                or logic.rounded_shape(current) != logic.rounded_shape(drag.original):
            self.drag_cancelled.emit("changed")
            return
        if preview is not None and usable_shape(preview) \
                and logic.rounded_shape(preview) != logic.rounded_shape(drag.original):
            self.shape_committed.emit(drag.slot, logic.rounded_shape(preview))     # one edit for the whole gesture

    def wheelEvent(self, event):
        steps = event.angleDelta().y() / 120
        if steps:
            self.zoom_requested.emit(min(MAX_ZOOM, max(MIN_ZOOM, self.zoom * (1.25 ** steps))))
        event.accept()

    def keyPressEvent(self, event):
        if event.key() == Qt.Key.Key_Escape and self.cancel_drag("escape"):
            event.accept()
            return
        super().keyPressEvent(event)

    def focusOutEvent(self, event):
        self.cancel_drag("focus")
        super().focusOutEvent(event)

    def hideEvent(self, event):
        self.cancel_drag("hidden")
        self._pan_from = None
        super().hideEvent(event)

    def event(self, event):
        if event.type() == QEvent.Type.UngrabMouse:       # the mouse capture was taken away mid-drag
            self.cancel_drag("capture")
            self._pan_from = None
        return super().event(event)
