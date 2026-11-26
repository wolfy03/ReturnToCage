"""Animation and collision workspace (MONSTER-STEP 3).

Controls in a tabbed side column, the preview canvas with the frame strip beside it, all over the one
``DocumentSession`` the rest of the editor uses. The canvas (``preview_canvas``), the decoded-frame cache
(``frame_cache``) and the playback clock (``application.playback``) are separate so other workspaces can
use the same ones.

The workspace never changes the document. Every action becomes edits from ``application.animation`` (or a
plain ``set_value``) emitted as ``edits_requested(edits, label)``; the window applies them, so one action
is one undo step. A drag on the canvas shows a preview shape and emits once, when the button is released -
a document edit normalises the whole document and is too slow to run on every mouse move.

All geometry comes from ``rtcmonster.geometry``: the canvas only maps actor space to the screen.

Selection is ``(clip, frame, shape slot)`` and belongs to the workspace. Other views drive it with
``select_clip`` / ``select_frame`` / ``select_shape`` / ``highlight_box`` / ``seek`` and follow it through
``selection_changed``.

While the clip is playing the frame under the cursor changes by itself, so shapes cannot be edited then:
the canvas is read-only until playback is paused or stopped.
"""

from PySide6.QtCore import QElapsedTimer, QSize, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QIcon
from PySide6.QtWidgets import (QAbstractItemView, QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QGroupBox,
                               QHBoxLayout, QLabel, QLineEdit, QListView, QListWidget, QListWidgetItem, QPushButton,
                               QScrollArea, QSpinBox, QSplitter, QTabWidget, QVBoxLayout, QWidget)

from application import animation as logic
from application.playback import Playback
from application.references import ReferenceBlocked
from rtcmonster import DocumentError, png, set_value
from rtcmonster.schema import LOOPING_ROLES, REQUIRED_ROLES, ROLES

from . import frame_cache, strings
from .frame_cache import load_frame
from .preview_canvas import HANDLE_PIXELS, KIND_COLORS, PreviewCanvas

__all__ = ["AnimationWorkspace", "HANDLE_PIXELS", "KIND_COLORS", "PreviewCanvas", "load_frame"]

STRIP_ICON = 56
TICK_MS = 16


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
    selection_changed = Signal(str, int, object)     # clip id, frame, ShapeSlot or None

    def __init__(self):
        super().__init__()
        self._session = None
        self._project_root = None
        self._loading = False
        self._clip_id = ""
        self._frame = 0
        self._slot = None
        self._shown = None
        self._announced = None
        self.prompts = None                     # set by the window; without it nothing that needs an answer runs
        self.playback = Playback()
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
        self.rename_clip_button = QPushButton(text["rename"])
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
        for button in (self.grid_button, self.images_button):
            row.addWidget(button)
        layout.addLayout(row)
        row = QHBoxLayout()
        for button in (self.rename_clip_button, self.remove_clip_button):
            row.addWidget(button)
        layout.addLayout(row)

        # ---- middle: canvas, playback, frame strip
        self.canvas = PreviewCanvas()
        self.play_button = QPushButton(text["play"])
        self.play_button.setCheckable(True)
        self.stop_button = QPushButton(text["stop"])
        self.stop_button.setToolTip(text["stop_tip"])
        self.play_button.setToolTip(text["play_tip"])
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
        self.duplicate_frame_button = QPushButton(text["duplicate_frame"])
        self.remove_frame_button = QPushButton(text["remove_frame"])
        for widget, tip in ((self.duration, "duration_tip"), (self.frame_left, "frame_earlier_tip"),
                            (self.frame_right, "frame_later_tip"), (self.remove_frame_button, "remove_frame_tip"),
                            (self.duplicate_frame_button, "duplicate_frame_tip")):
            widget.setToolTip(text[tip])
        middle = QWidget()
        column = QVBoxLayout(middle)
        row = QHBoxLayout()
        row.addWidget(self.play_button)
        row.addWidget(self.stop_button)
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
        for button in (self.frame_left, self.frame_right, self.duplicate_frame_button, self.remove_frame_button):
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
        self.hit_frame = QSpinBox()
        self.hit_frame.setKeyboardTracking(False)
        self.hit_frame.setToolTip(text["hit_frame_tip"])
        form.addRow(text["hit_frame"], self.hit_frame)
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
        self.rename_shape = QPushButton(text["rename"])
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
        for button in (self.add_hurtbox, self.add_hitbox):
            row.addWidget(button)
        layout.addLayout(row)
        row = QHBoxLayout()
        for button in (self.rename_shape, self.remove_shape):
            row.addWidget(button)
        layout.addLayout(row)
        self.runtime_note = QLabel(text["runtime_note"])
        self.runtime_note.setWordWrap(True)
        layout.addWidget(self.runtime_note)
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
        self.rename_clip_button.clicked.connect(self.rename_clip)
        self.clip_list.currentRowChanged.connect(self._clip_row_changed)
        self.strip.currentRowChanged.connect(self._frame_row_changed)
        self.play_button.toggled.connect(self._set_playing)
        self.stop_button.clicked.connect(self.stop)
        self.flip.toggled.connect(self._view_changed)
        self.zoom.valueChanged.connect(self._view_changed)
        self.canvas.zoom_requested.connect(self.zoom.setValue)
        self.canvas.drag_cancelled.connect(self._drag_cancelled)
        self.hit_frame.editingFinished.connect(self._hit_frame_edited)
        self.duplicate_frame_button.clicked.connect(self.duplicate_frame)
        self.rename_shape.clicked.connect(self.rename_selected_shape)
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
        self.canvas.cancel_drag("document")     # a drag belongs to the document it started in
        self.stop()
        if project_root != self._project_root and self._project_root is not None:
            frame_cache.forget_project(self._project_root)
        self._session, self._project_root = session, project_root
        self._clip_id, self._frame, self._slot, self._shown = "", 0, None, None
        self.notice.setText("")                 # a refusal belongs to the document it was about
        self.refresh()

    def set_project_root(self, project_root):
        if project_root != self._project_root:
            self.canvas.cancel_drag("project")
            self.stop()
            if self._project_root is not None:
                frame_cache.forget_project(self._project_root)
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

    @property
    def document(self):
        return self._session.document if self._session is not None else None

    def _request(self, edits, label, select=None):
        """Ask the window to apply edits as one undo step. Returns True when the document changed.

        ``select`` is ``(clip id, frame)`` to show afterwards. It is adopted for the refresh the window
        triggers, and put back when the edit is refused: the selection never runs ahead of the document.
        """
        if not edits or self._loading or self._session is None:
            return False
        self.canvas.cancel_drag("edit")
        before, previous = self._session.document, (self._clip_id, self._frame)
        if select is not None:
            self._clip_id, self._frame = select
        self.edits_requested.emit(list(edits), strings.ANIMATION["labels"].get(label, label))
        if self._session is not None and self._session.document is not before:
            return True
        if select is not None:
            self._clip_id, self._frame = previous
            self.refresh()
        return False

    def _attempt(self, build):
        """Run a helper that may refuse; show the refusal instead of raising into Qt."""
        try:
            edits = build()
        except (DocumentError, png.PngError, OSError, ValueError) as error:
            self.notice.setText(strings.ANIMATION["refused"].format(error=error))
            return None
        self.notice.setText("")
        return edits

    def _confirm(self, text):
        return self.prompts is not None and bool(self.prompts.confirm(strings.ANIMATION["title"], text))

    def _choose(self, text, options):
        """One of ``options`` picked by the user, or None."""
        if self.prompts is None or not options:
            return None
        return self.prompts.choose(strings.ANIMATION["title"], text, list(options))

    def _announce(self):
        state = (self._clip_id, self._frame, self._slot)
        if state != self._announced:
            self._announced = state
            self.selection_changed.emit(self._clip_id, self._frame, self._slot)

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
        if self.playback.clip is not clip:
            # Another clip, or this clip after an edit: keep playing through an edit of the same clip.
            same = self.playback.clip is not None and clip is not None and self.playback.clip["id"] == clip["id"]
            state, time = self.playback.state, self.playback.time
            self.playback.set_clip(clip)
            if same and self.playback.available:
                self.playback.state = state
                self.playback.seek(time)
            if not self.playback.playing:
                self._sync_play_button()
        attack = clip is not None and data["presentation"]["roles"]["attack"] == clip["id"]
        self.hit_frame.setRange(0, max(0, len(clip["frames"]) - 1) if attack else 64)
        self.hit_frame.setValue(data["presentation"]["attack_hit_frame"])
        presentation = data["presentation"]
        for box, value in ((self.scale_x, presentation["visual_scale"][0]), (self.scale_y, presentation["visual_scale"][1]),
                           (self.offset_x, presentation["visual_offset"][0]), (self.offset_y, presentation["visual_offset"][1])):
            box.setValue(value)
        self._show_shapes()
        self._show_canvas()
        self._enable()
        self._loading = False
        self._announce()

    def _show_frame(self):
        """The cheap path for "another frame of the same clip": no list is rebuilt."""
        self._loading = True
        clip = self.current_clip()
        if clip is not None and clip["frames"]:
            self._frame = max(0, min(self._frame, len(clip["frames"]) - 1))
            self.strip.setCurrentRow(self._frame)
            self.duration.setValue(clip["frames"][self._frame]["duration"])
        self._show_shapes()
        self._show_canvas()
        self._enable()
        self._loading = False
        self._announce()

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
            widget.setEnabled(shape is not None and self.editable("collision") and not self.playback.playing)
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
        self.canvas.set_facing(-1 if self.flip.isChecked() else 1)
        self.canvas.set_zoom(self.zoom.value())
        playing = self.playback.playing
        if playing and not message:
            message = strings.ANIMATION["playing_read_only"]
        # The context names what the shapes belong to. A drag started against another one is cancelled.
        context = (id(self._session), self._clip_id, self._frame)
        self.canvas.show_frame(pixmap, size, data["presentation"], shapes, self.editable("collision") and not playing,
                               message, context)
        self.canvas.select(self._slot)
        if clip is not None and clip["frames"]:
            start, end = self.playback.frame_window if self.playback.clip is clip and self.playback.frame == self._frame \
                else (0.0, 0.0)
            self.time_label.setText(strings.ANIMATION["time"].format(
                frame=self._frame, count=len(clip["frames"]), seconds=self.playback.duration,
                position=self.playback.position, start=start, end=end,
                state=strings.ANIMATION["playback_state"][self.playback.state]))
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
                (self.rename_clip_button, "animations", clip is not None),
                (self.duplicate_frame_button, "animations", frames),
                (self.hit_frame, "presentation",
                 clip is not None and self.data["presentation"]["roles"]["attack"] == clip["id"]),
                (self.rename_shape, "collision", self._slot is not None and self._slot.kind != "body"),
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
        self.stop_button.setEnabled(frames)
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
            # An explicit refresh re-reads the file even when its size and time did not move.
            row = self.data["assets"]["images"][logic.image_index(self.data, image_id)]
            frame_cache.forget_image(self._project_root, row["path"])
            more = self._attempt(lambda image_id=image_id: logic.refresh_image(self.data, self._project_root, image_id))
            if more is None:
                return
            edits += more
        self._shown = None                      # the strip shows these pixels; draw it again
        if not self._request(edits, "refresh"):
            self.refresh()

    def remove_image(self):
        ids = self.selected_images()
        if len(ids) != 1 or self.document is None:
            return
        text = strings.ANIMATION
        try:
            edits = logic.remove_image(self.document, ids[0])
        except ReferenceBlocked as blocked:
            # Frames are never deleted to free an image. The user may point them at another image instead.
            others = [row["id"] for row in self.data["assets"]["images"] if row["id"] != ids[0]]
            chosen = self._choose(text["image_in_use"].format(image=ids[0], count=len(blocked.usages),
                                                              clips=", ".join(logic.image_users(self.data, ids[0]))),
                                  others)
            if chosen is None:
                self.notice.setText(text["refused"].format(error=blocked))
                return
            edits = self._attempt(lambda: logic.remove_image(self.document, ids[0], replace_with=chosen))
        except DocumentError as error:
            self.notice.setText(text["refused"].format(error=error))
            return
        self._request(edits or [], "remove_image")

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
        """Remove the selected clip, after showing what goes with it.

        Roles and hurtbox overrides are the clip's own presentation: they are listed and removed with it
        once the user agrees. An attack pattern, a behaviour state or an event that names the clip is
        never dropped - the user picks the clip those should use instead, or the removal does not happen.
        """
        if self.current_clip() is None or self.document is None:
            return
        text, clip_id = strings.ANIMATION, self._clip_id
        usages = logic.clip_usages(self.document, clip_id)
        hard = [usage for usage in usages if not usage.soft]
        replacement = None
        if hard:
            others = [clip["id"] for clip in self.data["animations"]["clips"] if clip["id"] != clip_id]
            replacement = self._choose(text["clip_in_use"].format(
                clip=clip_id, usages="\n".join("· " + usage.where for usage in hard)), others)
            if replacement is None:
                self.notice.setText(text["clip_blocked"].format(clip=clip_id, usages=", ".join(u.where for u in hard)))
                return
        soft = [usage for usage in usages if usage.soft]
        if soft and not self._confirm(text["clip_removal"].format(
                clip=clip_id, usages="\n".join("· " + usage.where for usage in soft))):
            return
        edits = self._attempt(lambda: logic.remove_clip(self.document, clip_id, replace_with=replacement))
        self._request(edits or [], "remove_clip")

    def rename_clip(self):
        if self.current_clip() is None or self.prompts is None:
            return
        old = self._clip_id
        new = self.prompts.text(strings.ANIMATION["title"], strings.ANIMATION["rename_clip"].format(clip=old), old)
        if not new or new == old:
            return
        edits = self._attempt(lambda: logic.rename_clip(self.document, old, new.strip()))
        if edits:
            self._request(edits, "rename", select=(new.strip(), self._frame))

    def select_clip(self, clip_id, frame=0):
        self.canvas.cancel_drag("clip")
        self.stop()
        self._clip_id, self._frame, self._slot = clip_id, frame, None
        self.refresh()

    def select_frame(self, frame):
        """Show one frame of the current clip. Playback, if running, continues from that frame."""
        clip = self.current_clip()
        if clip is None or not clip["frames"]:
            return
        self._frame = max(0, min(int(frame), len(clip["frames"]) - 1))
        self.playback.seek_frame(self._frame)
        self._show_frame()

    def seek(self, seconds):
        """Show the frame ``seconds`` into the current clip (for a timeline view)."""
        self.playback.seek(seconds)
        self._frame = self.playback.frame
        self._show_frame()

    def _clip_row_changed(self, row):
        if self._loading or row < 0:
            return
        self.select_clip(self.clip_list.item(row).data(Qt.ItemDataRole.UserRole))

    def _frame_row_changed(self, row):
        if self._loading or row < 0:
            return
        self.select_frame(row)

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
        """Move the selected frame one place. Its hurtbox override and the attack hit frame move with it,
        in the same undo step; the moved frame stays selected."""
        clip = self.current_clip()
        target = self._frame + delta
        if clip is None or not 0 <= target < len(clip["frames"]):
            return False
        edits = self._attempt(lambda: logic.move_frame(self.data, self._clip_id, self._frame, target))
        return self._request(edits or [], "move_frame", select=(self._clip_id, target))

    def duplicate_frame(self):
        if self.current_clip() is None:
            return False
        edits = self._attempt(lambda: logic.duplicate_frame(self.data, self._clip_id, self._frame))
        return self._request(edits or [], "duplicate_frame", select=(self._clip_id, self._frame + 1))

    def remove_frame(self):
        """Remove the selected frame, after saying what goes with it or has to be decided."""
        clip = self.current_clip()
        if clip is None or not clip["frames"]:
            return False
        text, frame = strings.ANIMATION, self._frame
        impact = self._attempt(lambda: logic.frame_removal_impact(self.data, self._clip_id, frame))
        if impact is None:
            return False
        if impact["last"]:
            self.notice.setText(text["last_frame"])
            return False
        hit_frame = None
        if impact["hit_frame"]:
            # Which frame shows the strike now is a decision about the attack, so it is asked, not guessed.
            remaining = [index for index in range(len(clip["frames"])) if index != frame]
            labels = [text["frame_option"].format(frame=index) for index in remaining]
            chosen = self._choose(text["hit_frame_removed"].format(frame=frame), labels)
            if chosen is None:
                self.notice.setText(text["hit_frame_blocked"].format(frame=frame))
                return False
            old = remaining[labels.index(chosen)]
            hit_frame = old - (1 if old > frame else 0)
        if impact["override"] and not self._confirm(text["frame_override_removed"].format(frame=frame)):
            return False
        edits = self._attempt(lambda: logic.remove_frame(self.data, self._clip_id, frame, hit_frame=hit_frame))
        return self._request(edits or [], "remove_frame")

    def _hit_frame_edited(self):
        if self._loading or self.data is None:
            return
        value = self.hit_frame.value()
        if value != self.data["presentation"]["attack_hit_frame"]:
            self._request([set_value(("presentation", "attack_hit_frame"), value)], "hit_frame")

    # ---------------------------------------------------------------------------------------- playback
    def _sync_play_button(self):
        self.play_button.blockSignals(True)
        self.play_button.setChecked(self.playback.playing)
        self.play_button.blockSignals(False)
        self.play_button.setText(strings.ANIMATION["pause" if self.playback.playing else "play"])
        if not self.playback.playing:
            self._timer.stop()

    def _set_playing(self, playing):
        """The play button: play or continue, and pause. Stop is its own button."""
        if playing:
            self.canvas.cancel_drag("playback")       # the frame is about to change under the cursor
            if self.playback.state != "paused" or self.playback.finished:
                self.playback.seek_frame(0)
            elif self.playback.frame != self._frame:
                self.playback.seek_frame(self._frame)  # the user picked another frame while paused
            if self.playback.play():
                self._clock.start()
                self._timer.start()
        else:
            self.playback.pause()
        self._sync_play_button()
        if self.data is not None:
            self._frame = self.playback.frame if self.playback.available else self._frame
            self._show_frame()

    def stop(self):
        """Stop and go back to the first frame."""
        was = self.playback.state
        self.playback.stop()
        self._sync_play_button()
        if was != "stopped" and self.data is not None and self.current_clip() is not None:
            self._frame = 0
            self._show_frame()

    def _tick(self):
        self.advance(self._clock.restart() / 1000)

    def advance(self, seconds):
        """Let ``seconds`` of real time pass (the timer calls this; tests call it directly)."""
        if self.current_clip() is None:
            self.stop()
            return
        changed = self.playback.advance(seconds)
        if changed or not self.playback.playing:
            self._frame = self.playback.frame
            self._sync_play_button()
            self._show_frame()

    def show_time(self, seconds):
        """Show the frame ``seconds`` into the clip, by the same rule the game uses (one-shot clips hold)."""
        clip = self.current_clip()
        if clip is None or not clip["frames"]:
            self.stop()
            return
        self.playback.seek(seconds)
        if self.playback.finished:
            self.playback.pause()
            self._sync_play_button()
        if self.playback.frame != self._frame:
            self._frame = self.playback.frame
            self._show_frame()

    def _drag_cancelled(self, reason):
        if reason in ("escape", "focus", "capture", "button"):
            self.notice.setText(strings.ANIMATION["drag_cancelled"])

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
            mixed = logic.frame_sizes_differ(self.data, self._clip_id)
            self._request(self._attempt(lambda: logic.bottom_center_edits(self.data, self._clip_id,
                                                                          self.foot_margin.value())) or [],
                          "anchor")
            if mixed:
                # One visual_offset serves every frame in Schema V1; say so instead of pretending otherwise.
                self.notice.setText(strings.ANIMATION["anchor_mixed"])

    # ------------------------------------------------------------------------------------------ shapes
    def select_shape(self, slot):
        self.canvas.cancel_drag("selection")
        self._slot = slot
        self.refresh()

    def highlight_box(self, kind, box_id):
        """Emphasise a box by ID without selecting it (an attack event pointing at its hitbox). Returns the slot."""
        slot = next((slot for slot in self._slots() if slot.kind == kind and slot.label == box_id), None) \
            if self.data is not None else None
        self.canvas.highlight(slot)
        return slot

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
        self._announce()

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
        """Remove the selected box. A hitbox an attack event still names needs a replacement first."""
        slot = self._slot
        if slot is None or self.document is None:
            return False
        text = strings.ANIMATION
        try:
            edits = logic.remove_box(self.document, slot)
        except ReferenceBlocked as blocked:
            name = logic.box_id(self.data, slot)
            others = [box["id"] for box in self.data["collision"]["hitboxes"] if box["id"] != name]
            chosen = self._choose(text["hitbox_in_use"].format(
                hitbox=name, usages="\n".join("· " + usage.where for usage in blocked.usages)), others)
            if chosen is None:
                self.notice.setText(text["refused"].format(error=blocked))
                return False
            edits = self._attempt(lambda: logic.remove_box(self.document, slot, replace_with=chosen))
        except DocumentError as error:
            self.notice.setText(text["refused"].format(error=error))
            return False
        self.notice.setText("")
        previous, self._slot = self._slot, None
        if not self._request(edits or [], "remove_box"):
            self._slot = previous
            self.refresh()
            return False
        return True

    def rename_selected_shape(self):
        slot = self._slot
        if slot is None or slot.kind == "body" or self.prompts is None:
            return
        old = logic.box_id(self.data, slot)
        new = self.prompts.text(strings.ANIMATION["title"], strings.ANIMATION["rename_box"].format(box=old), old)
        if not new or new.strip() == old:
            return
        edits = self._attempt(lambda: logic.rename_box(self.document, slot, new.strip()))
        self._request(edits or [], "rename")

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
