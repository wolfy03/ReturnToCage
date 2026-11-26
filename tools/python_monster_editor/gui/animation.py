"""Animation and collision workspace (MONSTER-STEP 3).

Three columns over one ``DocumentSession``: images and clips on the left, the preview canvas with the
frame strip in the middle, clip settings, roles, the visual transform and the shape list on the right.

The workspace never changes the document. Every action becomes edits from ``application.animation`` (or a
plain ``set_value``) emitted as ``edits_requested(edits, label)``; the window applies them, so one action
is one undo step. A drag on the canvas shows a preview shape and emits once, when the button is released -
a document edit normalises the whole document and is too slow to run on every mouse move.

All geometry comes from ``rtcmonster.geometry``: the canvas only maps actor space to the screen.
"""

from pathlib import Path

from PySide6.QtCore import QElapsedTimer, QPointF, QRect, QRectF, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QIcon, QImageReader, QPainter, QPen, QPixmap, QTransform
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QGroupBox,
                               QHBoxLayout, QLabel, QLineEdit, QListView, QListWidget, QListWidgetItem, QPushButton,
                               QScrollArea, QSpinBox, QSplitter, QTabWidget, QVBoxLayout, QWidget)

from application import animation as logic
from rtcmonster import DocumentError, move_item, png, set_value
from rtcmonster.geometry import mirror_point, mirror_shape, shape_bounds, sprite_to_actor
from rtcmonster.schema import LOOPING_ROLES, REQUIRED_ROLES, ROLES
from rtcmonster.timing import clip_seconds, frame_at

from . import strings
from .panels import DECODE_LIMIT_MB, image_digest

KIND_COLORS = {"body": "#5aa9e6", "hurtbox": "#7fd18b", "override": "#d9a03f", "hitbox": "#e0605f"}
HANDLE_PIXELS = 7
STRIP_ICON = 56
TICK_MS = 16
# Full-resolution frames are kept, so the limit is what bounds memory: 128 frames of 256x256 RGBA is 32 MiB.
FRAME_CACHE = 128


# ------------------------------------------------------------------------------------------------- frames
_frames = {}


def load_frame(project_root, relative, rect=None):
    """``(QPixmap or None, state)`` of one frame at full resolution. Never raises.

    Same two checks as the overview thumbnail (structure, then a Qt decode limited in memory), cached by
    file content, but not scaled down: the canvas places collision shapes against these pixels.
    """
    if not relative:
        return None, "none"
    if project_root is None:
        return None, "unchecked"
    digest, state = image_digest(project_root, relative)
    if digest is None:
        return None, state
    key = (str(project_root), relative, digest, tuple(rect) if rect else None)
    if key not in _frames:
        reader = QImageReader(str(Path(project_root) / relative))
        reader.setAllocationLimit(DECODE_LIMIT_MB)
        if rect:
            reader.setClipRect(QRect(*rect))
        image = reader.read()
        _frames[key] = (None, "decode_failed") if image.isNull() else (QPixmap.fromImage(image), "ok")
        while len(_frames) > FRAME_CACHE:
            _frames.pop(next(iter(_frames)))
    return _frames[key]


# -------------------------------------------------------------------------------------------------- canvas
class PreviewCanvas(QWidget):
    """Draws one frame in actor space with the shapes over it, and edits the selected shape by dragging.

    The actor origin is the centre of the widget. ``facing`` -1 shows the monster turned left: the frame
    is mirrored by the document's own transform and every shape by ``mirror_shape``. A drag is converted
    back to the authored (facing right) space before it is reported.
    """

    shape_selected = Signal(object)            # ShapeSlot or None
    shape_committed = Signal(object, dict)     # ShapeSlot, new shape (authored space)

    def __init__(self):
        super().__init__()
        self.setMinimumSize(200, 160)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.ClickFocus)
        self.zoom = 4.0
        self.facing = 1
        self.pixmap = None
        self.frame_size = None
        self.presentation = None
        self.shapes = []                       # (ShapeSlot, shape) in drawing order
        self.selected = None
        self.editable = False
        self.message = ""
        self._drag = None                      # (mode, handle, start actor point, start shape)
        self._preview = None

    # ---- content
    def show_frame(self, pixmap, frame_size, presentation, shapes, editable, message=""):
        self.pixmap, self.frame_size, self.presentation = pixmap, frame_size, presentation
        self.shapes, self.editable, self.message = list(shapes), editable, message
        if self.selected is not None and self.selected not in [slot for slot, _shape in self.shapes]:
            self.selected = None
        self.update()

    def select(self, slot):
        self.selected = slot
        self.update()

    def shape_of(self, slot):
        if self._preview is not None and slot == self.selected:
            return self._preview
        for candidate, shape in self.shapes:
            if candidate == slot:
                return shape
        return None

    # ---- coordinates
    def to_view(self, point):
        return QPointF(self.width() / 2 + point[0] * self.zoom, self.height() / 2 + point[1] * self.zoom)

    def to_actor(self, position):
        return [(position.x() - self.width() / 2) / self.zoom, (position.y() - self.height() / 2) / self.zoom]

    def to_authored(self, position):
        """Widget position -> actor point in the authored (facing right) space."""
        return mirror_point(self.to_actor(position), self.facing)

    def frame_rect(self):
        """Where the frame is drawn, in widget coordinates, or None."""
        if self.frame_size is None or self.presentation is None:
            return None
        try:
            first = sprite_to_actor([0, 0], self.frame_size, self.presentation, self.facing)
            second = sprite_to_actor(list(self.frame_size), self.frame_size, self.presentation, self.facing)
        except ValueError:
            return None
        return QRectF(self.to_view(first), self.to_view(second)).normalized()

    def _view_shape_rect(self, shape):
        left, top, right, bottom = shape_bounds(mirror_shape(shape, self.facing))
        return QRectF(self.to_view([left, top]), self.to_view([right, bottom]))

    def handle_positions(self, slot):
        """``{handle: QPointF}`` of a shape's edge handles on screen, named in authored space."""
        shape = self.shape_of(slot)
        if shape is None:
            return {}
        return {handle: self.to_view(mirror_point(point, self.facing))
                for handle, point in logic.handle_points(shape).items()}

    # ---- painting
    def paintEvent(self, _event):
        painter = QPainter(self)
        painter.fillRect(self.rect(), QColor("#1b202a"))
        rect = self.frame_rect()
        if self.pixmap is not None and rect is not None:
            mirrored = self.facing < 0
            if self.presentation is not None and not self.presentation["faces_right_by_default"]:
                mirrored = not mirrored
            picture = self.pixmap.transformed(QTransform().scale(-1, 1)) if mirrored else self.pixmap
            painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, False)
            painter.drawPixmap(rect, picture, QRectF(picture.rect()))
            painter.setPen(QPen(QColor("#44506a"), 1, Qt.PenStyle.DotLine))
            painter.drawRect(rect)
        centre = self.to_view([0, 0])
        painter.setPen(QPen(QColor("#9aa5b8"), 1))
        painter.drawLine(QPointF(centre.x() - 8, centre.y()), QPointF(centre.x() + 8, centre.y()))
        painter.drawLine(QPointF(centre.x(), centre.y() - 8), QPointF(centre.x(), centre.y() + 8))
        for slot, shape in self.shapes:
            shape = self.shape_of(slot) or shape
            colour = QColor(KIND_COLORS[slot.kind])
            chosen = slot == self.selected
            pen = QPen(colour, 2 if chosen else 1, Qt.PenStyle.SolidLine if slot.enabled else Qt.PenStyle.DashLine)
            painter.setPen(pen)
            fill = QColor(colour)
            fill.setAlpha(70 if chosen else 28)
            painter.setBrush(fill)
            bounds = self._view_shape_rect(shape)
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
        painter.end()

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
            if chosen is not None and self._view_shape_rect(chosen).contains(position):
                return self.selected, None
        for slot, shape in reversed(self.shapes):        # the shape drawn last is on top
            if self._view_shape_rect(self.shape_of(slot) or shape).contains(position):
                return slot, None
        return None, None

    def mousePressEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton:
            return
        slot, handle = self._hit(event.position())
        if slot != self.selected:
            self.selected = slot
            self.shape_selected.emit(slot)
        if slot is not None and self.editable:
            self._drag = ("resize" if handle else "move", handle, self.to_authored(event.position()),
                          dict(self.shape_of(slot)))
        self.update()

    def mouseMoveEvent(self, event):
        self._drag_to(event.position())

    def _drag_to(self, position):
        if self._drag is None:
            return
        mode, handle, start, original = self._drag
        point = self.to_authored(position)
        if mode == "resize":
            self._preview = logic.resized_shape(original, handle, point)
        else:
            self._preview = logic.moved_shape(original, (point[0] - start[0], point[1] - start[1]))
        self.update()

    def mouseReleaseEvent(self, event):
        if event.button() != Qt.MouseButton.LeftButton or self._drag is None:
            return
        if self._preview is not None or self.to_authored(event.position()) != self._drag[2]:
            self._drag_to(event.position())       # the gesture ends where the button was released
        preview, original, slot = self._preview, self._drag[3], self.selected
        self._drag = self._preview = None
        if preview is not None and slot is not None and logic.rounded_shape(preview) != logic.rounded_shape(original):
            self.shape_committed.emit(slot, logic.rounded_shape(preview))     # one edit for the whole gesture
        self.update()


# ----------------------------------------------------------------------------------------------- workspace
def _spin(low, high, decimals=2, step=1.0):
    box = QDoubleSpinBox()
    box.setRange(low, high)
    box.setDecimals(decimals)
    box.setSingleStep(step)
    box.setKeyboardTracking(False)
    return box


class AnimationWorkspace(QWidget):
    edits_requested = Signal(list, str)
    browse_requested = Signal()                 # the window answers with set_image_path

    def __init__(self):
        super().__init__()
        self._session = None
        self._project_root = None
        self._loading = False
        self._clip_id = ""
        self._frame = 0
        self._slot = None
        self._shown = None
        self._clock = QElapsedTimer()
        self._timer = QTimer(self)
        self._timer.setInterval(TICK_MS)
        self._timer.timeout.connect(self._tick)
        text = strings.ANIMATION

        # ---- left: images and clips
        self.image_list, self.clip_list = QListWidget(), QListWidget()
        self.image_path = QLineEdit()
        self.image_path.setPlaceholderText(text["image_path_hint"])
        self.browse_button, self.register_button = QPushButton(text["browse"]), QPushButton(text["register"])
        self.refresh_image_button, self.remove_image_button = QPushButton(text["refresh_image"]), QPushButton(text["remove"])
        self.clip_id = QLineEdit()
        self.clip_id.setPlaceholderText(text["clip_id_hint"])
        self.columns, self.rows, self.count = QSpinBox(), QSpinBox(), QSpinBox()
        for box, low, high in ((self.columns, 1, 256), (self.rows, 1, 256), (self.count, 0, 256)):
            box.setRange(low, high)
        self.count.setSpecialValueText(text["all_frames"])
        self.grid_button, self.images_button = QPushButton(text["clip_from_grid"]), QPushButton(text["clip_from_images"])
        self.remove_clip_button = QPushButton(text["remove"])
        self.image_list.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        images = QGroupBox(text["images"])
        layout = QVBoxLayout(images)
        layout.addWidget(self.image_list)
        row = QHBoxLayout()
        row.addWidget(self.image_path, 1)
        row.addWidget(self.browse_button)
        layout.addLayout(row)
        row = QHBoxLayout()
        for button in (self.register_button, self.refresh_image_button, self.remove_image_button):
            row.addWidget(button)
        layout.addLayout(row)
        clips = QGroupBox(text["clips"])
        layout = QVBoxLayout(clips)
        layout.addWidget(self.clip_list)
        form = QFormLayout()
        form.addRow(text["clip_id"], self.clip_id)
        grid = QHBoxLayout()
        for label, box in ((text["columns"], self.columns), (text["rows"], self.rows), (text["count"], self.count)):
            grid.addWidget(QLabel(label))
            grid.addWidget(box)
        form.addRow(grid)
        layout.addLayout(form)
        row = QHBoxLayout()
        for button in (self.grid_button, self.images_button, self.remove_clip_button):
            row.addWidget(button)
        layout.addLayout(row)

        # ---- middle: canvas, playback, frame strip
        self.canvas = PreviewCanvas()
        self.play_button = QPushButton(text["play"])
        self.play_button.setCheckable(True)
        self.flip = QCheckBox(text["flip"])
        self.zoom = _spin(0.25, 32, 2, 0.5)
        self.zoom.setValue(self.canvas.zoom)
        self.time_label = QLabel()
        self.strip = QListWidget()
        self.strip.setViewMode(QListView.ViewMode.IconMode)
        self.strip.setFlow(QListView.Flow.LeftToRight)
        self.strip.setWrapping(False)
        self.strip.setIconSize(QSize(STRIP_ICON, STRIP_ICON))
        self.strip.setFixedHeight(STRIP_ICON + 44)
        self.strip.setMovement(QListView.Movement.Static)
        self.duration = _spin(0.01, 100, 2, 0.25)
        self.frame_left, self.frame_right = QPushButton(text["frame_earlier"]), QPushButton(text["frame_later"])
        self.remove_frame_button = QPushButton(text["remove_frame"])
        for widget, tip in ((self.duration, "duration_tip"), (self.frame_left, "frame_earlier_tip"),
                            (self.frame_right, "frame_later_tip"), (self.remove_frame_button, "remove_frame_tip")):
            widget.setToolTip(text[tip])
        middle = QWidget()
        column = QVBoxLayout(middle)
        row = QHBoxLayout()
        row.addWidget(self.play_button)
        row.addWidget(self.flip)
        row.addWidget(QLabel(text["zoom"]))
        row.addWidget(self.zoom)
        row.addStretch(1)
        column.addLayout(row)
        column.addWidget(self.time_label)
        column.addWidget(self.canvas, 1)
        column.addWidget(self.strip)
        row = QHBoxLayout()
        row.addWidget(QLabel(text["duration"]))
        row.addWidget(self.duration)
        for button in (self.frame_left, self.frame_right, self.remove_frame_button):
            row.addWidget(button)
        row.addStretch(1)
        column.addLayout(row)

        # ---- right: clip, roles, visual transform, shapes
        self.fps = _spin(0.1, 120, 2, 1)
        self.loop = QCheckBox(text["loop"])
        clip_box = QGroupBox(text["clip_settings"])
        form = QFormLayout(clip_box)
        form.addRow(text["fps"], self.fps)
        form.addRow(self.loop)
        self.roles = {}
        role_box = QGroupBox(text["roles"])
        form = QFormLayout(role_box)
        for role in ROLES:
            combo = QComboBox()
            combo.activated.connect(lambda _index, role=role, combo=combo: self._bind_role(role, combo.currentData()))
            form.addRow(strings.role_label(role), combo)
            self.roles[role] = combo
        self.scale_x, self.scale_y = _spin(0.01, 64, 3, 0.05), _spin(0.01, 64, 3, 0.05)
        self.offset_x, self.offset_y = _spin(-4096, 4096, 2, 1), _spin(-4096, 4096, 2, 1)
        self.foot_margin = _spin(0, 4096, 0, 1)
        self.anchor_button = QPushButton(text["bottom_center"])
        visual_box = QGroupBox(text["visual"])
        form = QFormLayout(visual_box)
        for label, first, second in ((text["visual_scale"], self.scale_x, self.scale_y),
                                     (text["visual_offset"], self.offset_x, self.offset_y)):
            row = QHBoxLayout()
            row.addWidget(first)
            row.addWidget(second)
            form.addRow(label, row)
        row = QHBoxLayout()
        row.addWidget(QLabel(text["foot_margin"]))
        row.addWidget(self.foot_margin)
        row.addWidget(self.anchor_button)
        form.addRow(row)
        self.shape_list = QListWidget()
        self.shape_list.setFixedHeight(120)
        self.shape_type = QComboBox()
        for kind in logic.SHAPE_KINDS:
            self.shape_type.addItem(strings.shape_label(kind), kind)
        self.center_x, self.center_y = _spin(-4096, 4096, 2, 1), _spin(-4096, 4096, 2, 1)
        self.extent_a, self.extent_b = _spin(0.01, 4096, 2, 1), _spin(0.01, 4096, 2, 1)
        self.extent_label = QLabel()
        self.enabled = QCheckBox(text["enabled"])
        self.add_hurtbox, self.add_hitbox = QPushButton(text["add_hurtbox"]), QPushButton(text["add_hitbox"])
        self.remove_shape = QPushButton(text["remove"])
        self.override_frame, self.override_clip = QPushButton(text["override_frame"]), QPushButton(text["override_clip"])
        self.override_clear = QPushButton(text["override_clear"])
        self.override_label = QLabel()
        self.override_label.setWordWrap(True)
        shape_box = QGroupBox(text["shapes"])
        layout = QVBoxLayout(shape_box)
        layout.addWidget(self.shape_list)
        form = QFormLayout()
        form.addRow(text["shape_type"], self.shape_type)
        row = QHBoxLayout()
        row.addWidget(self.center_x)
        row.addWidget(self.center_y)
        form.addRow(text["center"], row)
        row = QHBoxLayout()
        row.addWidget(self.extent_a)
        row.addWidget(self.extent_b)
        form.addRow(self.extent_label, row)
        form.addRow(self.enabled)
        layout.addLayout(form)
        row = QHBoxLayout()
        for button in (self.add_hurtbox, self.add_hitbox, self.remove_shape):
            row.addWidget(button)
        layout.addLayout(row)
        layout.addWidget(self.override_label)
        row = QHBoxLayout()
        for button in (self.override_frame, self.override_clip, self.override_clear):
            row.addWidget(button)
        layout.addLayout(row)
        # The catalog and inspector docks leave the workspace about 600 px on a 1360 px window, which is
        # not enough for three columns. The controls therefore share one tabbed side column and the
        # canvas gets everything else.
        def page(*boxes):
            body = QWidget()
            column = QVBoxLayout(body)
            for box in boxes:
                column.addWidget(box)
            column.addStretch(1)
            area = QScrollArea()
            area.setWidgetResizable(True)
            area.setWidget(body)
            return area

        self.side = QTabWidget()
        self.side.addTab(page(images, clips), text["tab_sources"])
        self.side.addTab(page(clip_box, role_box, visual_box), text["tab_clip"])
        self.side.addTab(page(shape_box), text["tab_shapes"])
        self.side.setMinimumWidth(200)

        self.notice = QLabel()
        self.notice.setWordWrap(True)
        splitter = QSplitter()
        for widget, stretch in ((self.side, 0), (middle, 1)):
            splitter.addWidget(widget)
            splitter.setStretchFactor(splitter.count() - 1, stretch)
        splitter.setSizes([310, 600])
        middle.setMinimumWidth(240)
        self.setMinimumSize(360, 240)           # an explicit minimum, so the columns never widen the window
        outer = QVBoxLayout(self)
        outer.addWidget(self.notice)
        outer.addWidget(splitter, 1)

        # ---- wiring
        self.browse_button.clicked.connect(self.browse_requested)
        self.register_button.clicked.connect(self.register_image)
        self.image_path.returnPressed.connect(self.register_image)
        self.refresh_image_button.clicked.connect(self.refresh_image)
        self.remove_image_button.clicked.connect(self.remove_image)
        self.grid_button.clicked.connect(self.add_grid_clip)
        self.images_button.clicked.connect(self.add_image_clip)
        self.remove_clip_button.clicked.connect(self.remove_clip)
        self.clip_list.currentRowChanged.connect(self._clip_row_changed)
        self.strip.currentRowChanged.connect(self._frame_row_changed)
        self.play_button.toggled.connect(self._set_playing)
        self.flip.toggled.connect(self._view_changed)
        self.zoom.valueChanged.connect(self._view_changed)
        self.duration.editingFinished.connect(self._duration_edited)
        self.frame_left.clicked.connect(lambda: self.move_frame(-1))
        self.frame_right.clicked.connect(lambda: self.move_frame(1))
        self.remove_frame_button.clicked.connect(self.remove_frame)
        self.fps.editingFinished.connect(lambda: self._clip_field("fps", self.fps.value()))
        self.loop.clicked.connect(lambda checked: self._clip_field("loop", bool(checked)))
        for box in (self.scale_x, self.scale_y, self.offset_x, self.offset_y):
            box.editingFinished.connect(self._visual_edited)
        self.anchor_button.clicked.connect(self.apply_bottom_center)
        self.shape_list.currentRowChanged.connect(self._shape_row_changed)
        self.shape_type.activated.connect(self._shape_fields_edited)
        for box in (self.center_x, self.center_y, self.extent_a, self.extent_b):
            box.editingFinished.connect(self._shape_fields_edited)
        self.enabled.clicked.connect(self._enabled_clicked)
        self.add_hurtbox.clicked.connect(lambda: self.add_box("hurtbox"))
        self.add_hitbox.clicked.connect(lambda: self.add_box("hitbox"))
        self.remove_shape.clicked.connect(self.remove_selected_shape)
        self.override_frame.clicked.connect(lambda: self.create_override(True))
        self.override_clip.clicked.connect(lambda: self.create_override(False))
        self.override_clear.clicked.connect(self.clear_override)
        self.canvas.shape_selected.connect(self._canvas_selected)
        self.canvas.shape_committed.connect(lambda slot, shape: self._request(logic.set_shape(slot, shape), "shape"))
        self.refresh()

    # ------------------------------------------------------------------------------------------- state
    def set_session(self, session, project_root=None):
        self._session, self._project_root = session, project_root
        self._clip_id, self._frame, self._slot, self._shown = "", 0, None, None
        self.play_button.setChecked(False)
        self.notice.setText("")                 # a refusal belongs to the document it was about
        self.refresh()

    def set_project_root(self, project_root):
        if project_root != self._project_root:
            self._project_root, self._shown = project_root, None
            self.refresh()

    def set_image_path(self, relative):
        self.image_path.setText(relative)

    @property
    def data(self):
        return self._session.document.data if self._session is not None else None

    def current_clip(self):
        if self.data is None:
            return None
        for clip in self.data["animations"]["clips"]:
            if clip["id"] == self._clip_id:
                return clip
        return None

    def current_frame(self):
        return self._frame

    def editable(self, section):
        return self._session is not None and self._session.is_editable((section,))

    def _request(self, edits, label):
        if edits and not self._loading:
            self.edits_requested.emit(list(edits), strings.ANIMATION["labels"].get(label, label))

    def _attempt(self, build):
        """Run a helper that may refuse; show the refusal instead of raising into Qt."""
        try:
            edits = build()
        except (DocumentError, png.PngError, OSError, ValueError) as error:
            self.notice.setText(strings.ANIMATION["refused"].format(error=error))
            return None
        self.notice.setText("")
        return edits

    # ----------------------------------------------------------------------------------------- refresh
    def refresh(self):
        """Show the session. Lists are rebuilt only when the section they show changed."""
        self._loading = True
        data = self.data
        has = data is not None
        for widget in (self.image_list, self.clip_list, self.strip, self.shape_list):
            widget.setEnabled(has)
        if not has:
            for widget in (self.image_list, self.clip_list, self.strip, self.shape_list):
                widget.clear()
            self._shown = None
            self.canvas.show_frame(None, None, None, [], False, strings.ANIMATION["no_document"])
            self._enable()
            self._loading = False
            return
        shown = self._shown or {}
        if shown.get("images") is not data["assets"]["images"]:
            chosen = {item.data(Qt.ItemDataRole.UserRole) for item in self.image_list.selectedItems()}
            self.image_list.clear()
            for row in data["assets"]["images"]:
                item = QListWidgetItem(f"{row['id']}  ({row['width']}×{row['height']})")
                item.setToolTip(row["path"])
                item.setData(Qt.ItemDataRole.UserRole, row["id"])
                self.image_list.addItem(item)
                item.setSelected(row["id"] in chosen)
        clips = data["animations"]["clips"]
        ids = [clip["id"] for clip in clips]
        if self._clip_id not in ids:
            self._clip_id, self._frame = (ids[0] if ids else ""), 0
        if shown.get("clips") is not clips or shown.get("roles") is not data["presentation"]["roles"]:
            self.clip_list.clear()
            for clip in clips:
                roles = logic.clip_roles(data, clip["id"])
                item = QListWidgetItem(f"{clip['id']}  · {len(clip['frames'])}f"
                                       + (f"  [{', '.join(roles)}]" if roles else ""))
                item.setData(Qt.ItemDataRole.UserRole, clip["id"])
                self.clip_list.addItem(item)
            for role, combo in self.roles.items():
                combo.clear()
                combo.addItem(strings.ANIMATION["no_clip"], "")
                for clip_id in ids:
                    combo.addItem(clip_id, clip_id)
                combo.setCurrentIndex(max(0, combo.findData(data["presentation"]["roles"][role])))
                missing = role in REQUIRED_ROLES and not data["presentation"]["roles"][role]
                combo.setToolTip(strings.ANIMATION["role_required"] if missing else
                                 strings.ANIMATION["role_loops"] if role in LOOPING_ROLES else "")
        self.clip_list.setCurrentRow(ids.index(self._clip_id) if self._clip_id in ids else -1)
        clip = self.current_clip()
        if clip is None or not clip["frames"]:
            self._frame = 0
        else:
            self._frame = min(self._frame, len(clip["frames"]) - 1)
        key = (clip, data["assets"]["images"], self._project_root)
        if shown.get("strip") is None or any(old is not new for old, new in zip(shown["strip"], key)):
            self.strip.clear()
            for index in range(len(clip["frames"]) if clip else 0):
                path, rect = logic.frame_source(data, clip, index)
                pixmap, _state = load_frame(self._project_root, path, rect)
                item = QListWidgetItem(str(index))
                if pixmap is not None:
                    item.setIcon(QIcon(pixmap.scaled(STRIP_ICON, STRIP_ICON, Qt.AspectRatioMode.KeepAspectRatio,
                                                     Qt.TransformationMode.FastTransformation)))
                item.setSizeHint(QSize(STRIP_ICON + 12, STRIP_ICON + 26))
                self.strip.addItem(item)
        self._shown = {"images": data["assets"]["images"], "clips": clips, "roles": data["presentation"]["roles"],
                       "strip": key}
        self.strip.setCurrentRow(self._frame if clip and clip["frames"] else -1)
        if clip is not None:
            self.fps.setValue(clip["fps"])
            self.loop.setChecked(clip["loop"])
            if clip["frames"]:
                self.duration.setValue(clip["frames"][self._frame]["duration"])
        presentation = data["presentation"]
        for box, value in ((self.scale_x, presentation["visual_scale"][0]), (self.scale_y, presentation["visual_scale"][1]),
                           (self.offset_x, presentation["visual_offset"][0]), (self.offset_y, presentation["visual_offset"][1])):
            box.setValue(value)
        self._show_shapes()
        self._show_canvas()
        self._enable()
        self._loading = False

    def _slots(self):
        return logic.shape_slots(self.data, self._clip_id or None, self._frame if self._clip_id else None)

    def _show_shapes(self):
        slots = self._slots()
        if self._slot not in slots:
            self._slot = None
        self.shape_list.clear()
        for slot in slots:
            item = QListWidgetItem(f"{strings.shape_kind_label(slot.kind)}: {slot.label}"
                                   + ("" if slot.enabled else strings.ANIMATION["disabled_suffix"]))
            item.setForeground(QColor(KIND_COLORS[slot.kind]))
            self.shape_list.addItem(item)
        self.shape_list.setCurrentRow(slots.index(self._slot) if self._slot in slots else -1)
        index = logic.active_override(self.data, self._clip_id, self._frame) if self._clip_id else None
        if index is None:
            self.override_label.setText(strings.ANIMATION["override_none"])
        else:
            row = self.data["collision"]["hurtbox_overrides"][index]
            self.override_label.setText(strings.ANIMATION["override_clip_state" if row["frame"] is None
                                                          else "override_frame_state"].format(frame=row["frame"]))
        self._show_shape_fields()

    def _show_shape_fields(self):
        slot = self._slot
        shape = logic.shape_at(self.data, slot) if slot is not None else None
        for widget in (self.shape_type, self.center_x, self.center_y, self.extent_a, self.extent_b, self.enabled):
            widget.setEnabled(shape is not None and self.editable("collision"))
        circle = shape is not None and shape["type"] == "circle"
        self.extent_label.setText(strings.ANIMATION["radius" if circle else "size"])
        self.extent_b.setVisible(not circle)
        if shape is None:
            return
        self.shape_type.setCurrentIndex(self.shape_type.findData(shape["type"]))
        self.center_x.setValue(shape["center"][0])
        self.center_y.setValue(shape["center"][1])
        if circle:
            self.extent_a.setValue(shape["radius"])
        else:
            self.extent_a.setValue(shape["size"][0])
            self.extent_b.setValue(shape["size"][1])
        self.enabled.setVisible(slot.kind in ("hurtbox", "override"))
        self.enabled.setChecked(slot.enabled)

    def _show_canvas(self):
        data, clip = self.data, self.current_clip()
        pixmap, size, message = None, None, ""
        if clip is not None and clip["frames"]:
            path, rect = logic.frame_source(data, clip, self._frame)
            size = logic.frame_size(data, clip, self._frame)
            pixmap, state = load_frame(self._project_root, path, rect)
            if pixmap is None:
                message = strings.IMAGE_STATE[state]
        elif clip is None:
            message = strings.ANIMATION["no_clip_selected"]
        shapes = [(slot, logic.shape_at(data, slot)) for slot in self._slots()]
        self.canvas.facing = -1 if self.flip.isChecked() else 1
        self.canvas.zoom = self.zoom.value()
        self.canvas.show_frame(pixmap, size, data["presentation"], shapes, self.editable("collision"), message)
        self.canvas.select(self._slot)
        if clip is not None and clip["frames"]:
            self.time_label.setText(strings.ANIMATION["time"].format(
                frame=self._frame, count=len(clip["frames"]), seconds=clip_seconds(clip)))
        else:
            self.time_label.setText("")

    def _enable(self):
        has = self.data is not None
        clip = self.current_clip()
        frames = bool(clip and clip["frames"])
        for widget, section, extra in (
                (self.image_path, "assets", True), (self.browse_button, "assets", self._project_root is not None),
                (self.register_button, "assets", self._project_root is not None),
                (self.refresh_image_button, "assets", self._project_root is not None),
                (self.remove_image_button, "assets", True),
                (self.clip_id, "animations", True), (self.columns, "animations", True), (self.rows, "animations", True),
                (self.count, "animations", True), (self.grid_button, "animations", True),
                (self.images_button, "animations", True), (self.remove_clip_button, "animations", clip is not None),
                (self.fps, "animations", clip is not None), (self.loop, "animations", clip is not None),
                (self.duration, "animations", frames), (self.frame_left, "animations", frames),
                (self.frame_right, "animations", frames), (self.remove_frame_button, "animations", frames),
                (self.scale_x, "presentation", True), (self.scale_y, "presentation", True),
                (self.offset_x, "presentation", True), (self.offset_y, "presentation", True),
                (self.anchor_button, "presentation", frames), (self.foot_margin, "presentation", True),
                (self.add_hurtbox, "collision", True), (self.add_hitbox, "collision", True),
                (self.remove_shape, "collision", self._slot is not None and self._slot.kind != "body"),
                (self.override_frame, "collision", frames), (self.override_clip, "collision", clip is not None),
                (self.override_clear, "collision", clip is not None)):
            widget.setEnabled(has and self.editable(section) and bool(extra))
        for combo in self.roles.values():
            combo.setEnabled(has and self.editable("presentation"))
        self.play_button.setEnabled(frames)
        if has and not self.editable("animations"):
            self.notice.setText(strings.ANIMATION["read_only"])

    # ------------------------------------------------------------------------------------------ images
    def selected_images(self):
        return [item.data(Qt.ItemDataRole.UserRole) for item in self.image_list.selectedItems()]

    def register_image(self):
        relative = self.image_path.text().strip()
        if not relative or self.data is None:
            return
        result = self._attempt(lambda: logic.register_image(self.data, self._project_root, relative))
        if result is not None:
            self._request(result[1], "register")
            self.image_path.clear()

    def refresh_image(self):
        edits = []
        for image_id in self.selected_images():
            more = self._attempt(lambda image_id=image_id: logic.refresh_image(self.data, self._project_root, image_id))
            if more is None:
                return
            edits += more
        self._request(edits, "refresh")

    def remove_image(self):
        ids = self.selected_images()
        if len(ids) == 1:
            self._request(self._attempt(lambda: logic.remove_image(self.data, ids[0])) or [],
                          "remove_image")

    # ------------------------------------------------------------------------------------------- clips
    def _new_clip_id(self):
        taken = [clip["id"] for clip in self.data["animations"]["clips"]]
        return self.clip_id.text().strip() or logic.unique_id("clip", taken)

    def add_grid_clip(self):
        ids = self.selected_images()
        if self.data is None or len(ids) != 1:
            self.notice.setText(strings.ANIMATION["select_one_image"])
            return
        clip_id = self._new_clip_id()
        edits = self._attempt(lambda: logic.clip_from_grid(self.data, ids[0], clip_id, self.columns.value(),
                                                           self.rows.value(), self.count.value() or None))
        if edits:
            self._clip_id, self._frame = clip_id, 0
            self._request(edits, "clip")
            self.clip_id.clear()

    def add_image_clip(self):
        ids = self.selected_images()
        if self.data is None or not ids:
            self.notice.setText(strings.ANIMATION["select_images"])
            return
        clip_id = self._new_clip_id()
        edits = self._attempt(lambda: logic.clip_from_images(self.data, clip_id, ids))
        if edits:
            self._clip_id, self._frame = clip_id, 0
            self._request(edits, "clip")
            self.clip_id.clear()

    def remove_clip(self):
        if self.current_clip() is not None:
            self._request(self._attempt(lambda: logic.remove_clip(self.data, self._clip_id)) or [],
                          "remove_clip")

    def select_clip(self, clip_id, frame=0):
        self._clip_id, self._frame, self._slot = clip_id, frame, None
        self.refresh()

    def _clip_row_changed(self, row):
        if self._loading or row < 0:
            return
        self.play_button.setChecked(False)
        self.select_clip(self.clip_list.item(row).data(Qt.ItemDataRole.UserRole))

    def _frame_row_changed(self, row):
        if self._loading or row < 0:
            return
        self._frame = row
        self.refresh()

    def _clip_path(self):
        return logic.CLIPS + (logic.clip_index(self.data, self._clip_id),)

    def _clip_field(self, key, value):
        clip = self.current_clip()
        if clip is None or self._loading or clip[key] == value:
            return
        self._request([set_value(self._clip_path() + (key,), value)], key)

    def _duration_edited(self):
        clip = self.current_clip()
        if clip is None or not clip["frames"] or self._loading:
            return
        value = round(self.duration.value(), 2)
        if clip["frames"][self._frame]["duration"] != value:
            self._request([set_value(self._clip_path() + ("frames", self._frame, "duration"), value)], "duration")

    def move_frame(self, delta):
        clip = self.current_clip()
        target = self._frame + delta
        if clip is None or not 0 <= target < len(clip["frames"]):
            return
        source, self._frame = self._frame, target
        self._request([move_item(self._clip_path() + ("frames", source), target)], "move_frame")

    def remove_frame(self):
        if self.current_clip() is not None:
            self._request(self._attempt(lambda: logic.remove_frame(self.data, self._clip_id, self._frame)) or [], "remove_frame")

    # ---------------------------------------------------------------------------------------- playback
    def _set_playing(self, playing):
        self.play_button.setText(strings.ANIMATION["pause" if playing else "play"])
        if playing:
            self._clock.start()
            self._timer.start()
        else:
            self._timer.stop()

    def _tick(self):
        self.show_time(self._clock.elapsed() / 1000)

    def show_time(self, seconds):
        """Show the frame ``seconds`` into the clip, by the same rule the game uses (one-shot clips hold)."""
        clip = self.current_clip()
        if clip is None or not clip["frames"]:
            self.play_button.setChecked(False)
            return
        frame = frame_at(clip, seconds)
        if frame != self._frame:
            self._frame = frame
            self.refresh()
        if not clip["loop"] and seconds >= clip_seconds(clip):
            self.play_button.setChecked(False)

    def _view_changed(self, *_args):
        if not self._loading and self.data is not None:
            self._show_canvas()

    # ------------------------------------------------------------------------------------ presentation
    def _bind_role(self, role, clip_id):
        if self._loading or self.data is None or self.data["presentation"]["roles"][role] == clip_id:
            return
        self._request(self._attempt(lambda: logic.bind_role(self.data, role, clip_id)) or [], "role")

    def _visual_edited(self):
        if self._loading or self.data is None:
            return
        presentation = self.data["presentation"]
        edits = []
        for key, boxes in (("visual_scale", (self.scale_x, self.scale_y)), ("visual_offset", (self.offset_x, self.offset_y))):
            value = [round(box.value(), box.decimals()) for box in boxes]
            if value != list(presentation[key]):
                edits.append(set_value(("presentation", key), value))
        self._request(edits, "visual")

    def apply_bottom_center(self):
        if self.current_clip() is not None:
            self._request(self._attempt(lambda: logic.bottom_center_edits(self.data, self._clip_id,
                                                                          self.foot_margin.value())) or [],
                          "anchor")

    # ------------------------------------------------------------------------------------------ shapes
    def select_shape(self, slot):
        self._slot = slot
        self.refresh()

    def _canvas_selected(self, slot):
        self._slot = slot
        if slot is not None:
            self.side.setCurrentIndex(2)
        self._loading = True
        slots = self._slots()
        self.shape_list.setCurrentRow(slots.index(slot) if slot in slots else -1)
        self._show_shape_fields()
        self._enable()
        self._loading = False

    def _shape_row_changed(self, row):
        if self._loading:
            return
        slots = self._slots()
        self.select_shape(slots[row] if 0 <= row < len(slots) else None)

    def _shape_fields_edited(self, *_args):
        if self._loading or self._slot is None:
            return
        current = logic.shape_at(self.data, self._slot)
        shape = logic.convert_shape(current, self.shape_type.currentData())
        if shape["type"] == current["type"]:
            shape["center"] = [self.center_x.value(), self.center_y.value()]
            if shape["type"] == "circle":
                shape["radius"] = self.extent_a.value()
            else:
                shape["size"] = [self.extent_a.value(), self.extent_b.value()]
        if logic.rounded_shape(shape) != logic.rounded_shape(current):
            self._request(logic.set_shape(self._slot, shape), "shape")

    def _enabled_clicked(self, checked):
        if self._loading or self._slot is None or self._slot.kind not in ("hurtbox", "override"):
            return
        self._request([set_value(self._slot.path[:-1] + ("enabled",), bool(checked))], "shape")

    def add_box(self, kind):
        if self.data is not None:
            result = self._attempt(lambda: logic.add_box(self.data, kind))
            if result is not None:
                self._request(result[1], "add_box")

    def remove_selected_shape(self):
        if self._slot is not None:
            slot, self._slot = self._slot, None
            self._request(self._attempt(lambda: logic.remove_box(slot)) or [], "remove_box")

    def create_override(self, for_frame):
        if self.current_clip() is not None:
            self._slot = None
            self._request(self._attempt(lambda: logic.create_override(
                self.data, self._clip_id, self._frame if for_frame else None)) or [], "override")

    def clear_override(self):
        if self.current_clip() is None:
            return
        index = logic.active_override(self.data, self._clip_id, self._frame)
        if index is None:
            return
        frame = self.data["collision"]["hurtbox_overrides"][index]["frame"]
        self._slot = None
        self._request(self._attempt(lambda: logic.remove_override(self.data, self._clip_id, frame)) or [],
                      "override")
