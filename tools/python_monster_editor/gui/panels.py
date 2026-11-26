"""Loot editor, read-only summary and the overview workspace.

All three show a ``DocumentSession`` and never keep a copy of the document. The loot editor emits edits;
it does not apply them.
"""

from pathlib import Path

from PySide6.QtCore import QRect, Qt, Signal
from PySide6.QtGui import QImageReader, QPixmap
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QGridLayout, QGroupBox,
                               QHBoxLayout, QHeaderView, QLabel, QLineEdit, QPushButton, QSpinBox, QTableWidget,
                               QTextBrowser, QVBoxLayout, QWidget)

from rtcmonster import DocumentError, insert_item, inspect_image, move_item, remove_item, set_value
from rtcmonster import png

from . import strings

THUMBNAIL_EDGE = 160
DECODE_LIMIT_MB = 128
SUMMARY_SECTIONS = ("assets", "animations", "presentation", "collision", "attack_patterns", "behavior",
                    "source_binding")


# ------------------------------------------------------------------------------------------------- images
_thumbnails = {}


_inspected = {}


def image_digest(project_root, relative):
    """``(sha256 or None, state)`` of a project image after the core's structural check. Never raises.

    The check reads and hashes the whole file, and panels ask after every edit, so the answer is kept
    per file identity (size and modification time). A file that was replaced is checked again.
    """
    try:
        stat = (Path(project_root) / relative).stat()
        key = (str(project_root), relative, stat.st_size, stat.st_mtime_ns)
    except (OSError, ValueError):
        key = None
    if key is None or key not in _inspected:
        try:
            answer = (inspect_image(project_root, relative)[2], "ok")
        except FileNotFoundError:
            answer = (None, "missing")
        except (png.PngError, DocumentError, OSError):
            answer = (None, "structure_failed")
        if key is None:
            return answer
        _inspected[key] = answer
        while len(_inspected) > 256:
            _inspected.pop(next(iter(_inspected)))
    return _inspected[key]


def forget_image_checks(project_root=None, relative=None):
    """Forget structural-check answers so the files are read and hashed again.

    The cache key is the file's size and modification time: fast, and wrong only for a file rewritten
    with both unchanged. An explicit refresh calls this, so "refresh" always means a real re-read.
    """
    for key in [key for key in _inspected if (project_root is None or key[0] == str(project_root))
                and (relative is None or key[1] == relative)]:
        del _inspected[key]


def load_thumbnail(project_root, relative, rect=None):
    """``(QPixmap or None, state)`` for a project image. Never raises.

    Two checks, kept apart in the returned state: the core's structural PNG check, then a real decode by
    Qt. The decode is limited in memory, and only the requested rectangle is read. Results are cached by
    file content, so a changed file is decoded again and an unchanged one never is.
    """
    if not relative:
        return None, "none"
    if project_root is None:
        return None, "unchecked"
    digest, state = image_digest(project_root, relative)
    if digest is None:
        return None, state
    key = (str(project_root), relative, digest, tuple(rect) if rect else None)
    if key not in _thumbnails:
        reader = QImageReader(str(Path(project_root) / relative))
        reader.setAllocationLimit(DECODE_LIMIT_MB)
        if rect:
            reader.setClipRect(QRect(*rect))
        image = reader.read()
        if image.isNull():
            _thumbnails[key] = (None, "decode_failed")
        else:
            pixmap = QPixmap.fromImage(image)
            if max(pixmap.width(), pixmap.height()) > THUMBNAIL_EDGE:
                pixmap = pixmap.scaled(THUMBNAIL_EDGE, THUMBNAIL_EDGE, Qt.AspectRatioMode.KeepAspectRatio,
                                       Qt.TransformationMode.FastTransformation)
            _thumbnails[key] = (pixmap, "ok")
        while len(_thumbnails) > 64:
            _thumbnails.pop(next(iter(_thumbnails)))
    return _thumbnails[key]


def representative_frame(data):
    """``(image path, rect)`` of the picture that stands for the monster, or ``("", None)``."""
    if data["metadata"]["thumbnail"]:
        return data["metadata"]["thumbnail"], None
    images = {row["id"]: row for row in data["assets"]["images"]}
    clips = {row["id"]: row for row in data["animations"]["clips"]}
    wanted = [data["presentation"]["roles"]["idle"]] + list(clips)
    for clip_id in wanted:
        clip = clips.get(clip_id)
        if clip and clip["frames"] and clip["frames"][0]["image"] in images:
            frame = clip["frames"][0]
            return images[frame["image"]]["path"], frame["rect"]
    return "", None


# --------------------------------------------------------------------------------------------- loot editor
class LootEditor(QWidget):
    """Edits ``loot``. The rows live in the draft only; no LootTableDefinition is written in this step."""
    edits_requested = Signal(list, str)

    def __init__(self):
        super().__init__()
        self._session = None
        self._items = None
        self._shown = None
        self._loading = False
        layout = QVBoxLayout(self)
        form = QFormLayout()
        self.table_id = QLineEdit()
        self.table_id.editingFinished.connect(self._table_id_changed)
        form.addRow(strings.field_label("loot.loot_table_id"), self.table_id)
        self.managed = QCheckBox("이 문서가 전리품 목록을 직접 관리")
        self.managed.clicked.connect(self._managed_changed)
        form.addRow(self.managed)
        self.multiplier = QCheckBox(strings.field_label("loot.apply_difficulty_multiplier"))
        self.multiplier.clicked.connect(lambda checked: self._request(
            [set_value(("loot", "apply_difficulty_multiplier"), bool(checked))], "난이도 배율 적용 변경"))
        form.addRow(self.multiplier)
        layout.addLayout(form)
        self.notice = QLabel()
        self.notice.setWordWrap(True)
        layout.addWidget(self.notice)
        self.table = QTableWidget(0, 4)
        self.table.setHorizontalHeaderLabels(["Item ID", "가중치", "최소 수량", "최대 수량"])
        self.table.horizontalHeader().setSectionResizeMode(0, QHeaderView.ResizeMode.Stretch)
        self.table.verticalHeader().setVisible(False)
        self.table.setSelectionBehavior(QTableWidget.SelectionBehavior.SelectRows)
        layout.addWidget(self.table, 1)
        buttons = QHBoxLayout()
        self.add_button, self.remove_button = QPushButton("항목 추가"), QPushButton("항목 삭제")
        self.up_button, self.down_button = QPushButton("위로"), QPushButton("아래로")
        for button, slot in ((self.add_button, self.add_row), (self.remove_button, self.remove_row),
                             (self.up_button, lambda: self.move_row(-1)), (self.down_button, lambda: self.move_row(1))):
            button.clicked.connect(slot)
            buttons.addWidget(button)
        buttons.addStretch(1)
        layout.addLayout(buttons)

    def set_session(self, session):
        self._session = session
        self._shown = None
        self.refresh()

    def set_items(self, item_ids):
        """IDs of the project's ItemDefinitions, or None when no project is connected."""
        self._items = None if item_ids is None else list(item_ids)
        self._shown = None
        self.refresh()

    def _request(self, edits, label):
        if not self._loading:
            self.edits_requested.emit(edits, label)

    def _entries(self):
        return self._session.document.data["loot"]["entries"]

    def refresh(self, force=False):
        """Show the session's loot. ``force`` rebuilds even an unchanged table, to undo a rejected input."""
        if self._session is None:
            return
        loot = self._session.document.data["loot"]
        editable = self._session.is_editable(("loot",))
        # Document snapshots share the sections an edit did not touch, so identity tells whether the
        # table is already showing this value. Rebuilding every cell widget for an unrelated edit was
        # a large part of the cost of one edit.
        if not force and self._shown is not None and self._shown[0] is loot and self._shown[1] == editable:
            return
        self._shown = (loot, editable)
        self._loading = True
        entries = loot["entries"]
        self.table_id.setText(loot["loot_table_id"])
        self.managed.setChecked(entries is not None)
        self.multiplier.setChecked(loot["apply_difficulty_multiplier"])
        if entries is None:
            self.notice.setText(
                "기존 Loot Table을 참조합니다. 그 표는 같은 ID를 쓰는 다른 몬스터와 공유되므로, 표의 내용을 고치면 "
                "다른 몬스터에도 영향이 갑니다. 이 편집기는 실제 Loot Table을 수정하지 않습니다."
                if loot["loot_table_id"] else "전리품이 없습니다.")
        else:
            self.notice.setText("전리품 목록은 이 초안 문서에만 저장됩니다. 게임의 Loot Table은 바뀌지 않습니다."
                                + ("" if self._items is not None else " (프로젝트 미연결: Item ID를 확인할 수 없습니다)"))
        rows = entries or []
        self.table.setRowCount(len(rows))
        for index, row in enumerate(rows):
            combo = QComboBox()
            combo.setEditable(True)
            combo.addItems(self._items or [])
            combo.setCurrentText(row["item_id"])
            known = self._items is None or row["item_id"] in self._items
            combo.setToolTip("" if known else "프로젝트에 없는 Item ID입니다")
            combo.setStyleSheet("" if known else "QComboBox { color: #e07a5f; }")
            combo.activated.connect(lambda _i, index=index, combo=combo: self._cell(index, "item_id", combo.currentText()))
            combo.lineEdit().editingFinished.connect(
                lambda index=index, combo=combo: self._cell(index, "item_id", combo.currentText()))
            weight = QDoubleSpinBox()
            weight.setDecimals(3)
            weight.setRange(-1e6, 1e6)
            weight.setKeyboardTracking(False)
            weight.setValue(row["weight"])
            weight.editingFinished.connect(lambda index=index, box=weight: self._cell(index, "weight", box.value()))
            low, high = QSpinBox(), QSpinBox()
            for box, key in ((low, "min_amount"), (high, "max_amount")):
                box.setRange(-9999, 99999)
                box.setKeyboardTracking(False)
                box.setValue(row[key])
                box.editingFinished.connect(lambda index=index, box=box, key=key: self._cell(index, key, box.value()))
            for column, widget in enumerate((combo, weight, low, high)):
                widget.setEnabled(editable)
                self.table.setCellWidget(index, column, widget)
        for widget in (self.table_id, self.managed, self.multiplier, self.add_button, self.remove_button,
                       self.up_button, self.down_button):
            widget.setEnabled(editable)
        for widget in (self.add_button, self.remove_button, self.up_button, self.down_button):
            widget.setEnabled(editable and entries is not None)
        self._loading = False

    def _cell(self, index, key, value):
        entries = self._entries()
        if entries is None or index >= len(entries):
            return
        if isinstance(value, float) and value.is_integer():
            value = int(value)
        if entries[index][key] != value:
            self._request([set_value(("loot", "entries", index, key), value)], "전리품 항목 수정")

    def _table_id_changed(self):
        if self._session and self.table_id.text() != self._session.document.data["loot"]["loot_table_id"]:
            self._request([set_value(("loot", "loot_table_id"), self.table_id.text())], "Loot Table ID 변경")

    def _managed_changed(self, checked):
        self._request([set_value(("loot", "entries"), [] if checked else None)],
                      "전리품 목록 관리 방식 변경")

    def add_row(self):
        item = (self._items or ["item_id"])[0]
        self._request([insert_item(("loot", "entries"), {"item_id": item, "weight": 1, "min_amount": 1,
                                                          "max_amount": 1})], "전리품 항목 추가")

    def remove_row(self):
        row = self.table.currentRow()
        if row >= 0:
            self._request([remove_item(("loot", "entries", row))], "전리품 항목 삭제")

    def move_row(self, delta):
        row = self.table.currentRow()
        target = row + delta
        if row >= 0 and 0 <= target < self.table.rowCount():
            self._request([move_item(("loot", "entries", row), target)], "전리품 항목 순서 변경")
            self.table.setCurrentCell(target, 0)

    def focus_path(self, path):
        if len(path) >= 3 and path[1] == "entries" and isinstance(path[2], int) and path[2] < self.table.rowCount():
            self.table.setCurrentCell(path[2], 0)
            widget = self.table.cellWidget(path[2], {"item_id": 0, "weight": 1, "min_amount": 2,
                                                     "max_amount": 3}.get(path[3] if len(path) > 3 else "", 0))
            if widget is not None:
                widget.setFocus()
        elif len(path) >= 2 and path[1] == "loot_table_id":
            self.table_id.setFocus()


# ------------------------------------------------------------------------------------------------ summary
class SummaryPanel(QTextBrowser):
    """Read-only view of the sections whose editors come in later steps."""

    def __init__(self):
        super().__init__()
        self.setOpenLinks(False)
        self._session = None
        self._highlight = ""
        self._shown = None

    def set_session(self, session):
        self._session = session
        self._shown = None
        self.refresh()

    def highlight(self, section):
        self._highlight = section
        self.refresh()
        self.scrollToAnchor(section)

    def showEvent(self, event):
        super().showEvent(event)
        self.refresh()

    def toHtml(self):
        self.refresh(visible_only=False)        # a reader always gets the current text
        return super().toHtml()

    def toPlainText(self):
        self.refresh(visible_only=False)
        return super().toPlainText()

    def refresh(self, visible_only=True):
        """Regenerate the text only when it would differ, and only while someone can see it.

        The summary is one HTML document. Building it after every edit was most of an edit's cost on
        a large monster, although most edits do not touch the sections it shows. Snapshots share
        untouched sections, so comparing the sections by identity is exact.
        """
        if self._session is None:
            self._shown = None
            self.setHtml("")
            return
        data = self._session.document.data
        if visible_only and not self.isVisible():
            return                      # showEvent, or the next reader, refreshes
        state = [data[section] for section in SUMMARY_SECTIONS] + [self._highlight, self._session]
        if self._shown is not None and len(self._shown) == len(state)                 and all(old is new for old, new in zip(self._shown, state)):
            return
        self._shown = state
        collision, behavior = data["collision"], data["behavior"]
        registry = self._session.document.schema.registry

        def title(section, text):
            mark = " style='background:#3d4a5c'" if section == self._highlight else ""
            return f"<h4{mark}><a name='{section}'></a>{text} <small>(읽기 전용 · 이후 단계에서 편집)</small></h4>"

        parts = [title("animations", "Animation Clips")]
        parts.append("<ul>" + "".join(
            f"<li><code>{clip['id']}</code> — {len(clip['frames'])} frame, {clip['fps']} fps"
            f"{', loop' if clip['loop'] else ''}</li>" for clip in data["animations"]["clips"]) + "</ul>"
            if data["animations"]["clips"] else "<p>없음</p>")
        parts.append(title("assets", "Images"))
        parts.append("<ul>" + "".join(f"<li><code>{row['id']}</code> — {row['path']} ({row['width']}×{row['height']})</li>"
                                      for row in data["assets"]["images"]) + "</ul>"
                     if data["assets"]["images"] else "<p>없음</p>")
        parts.append(title("presentation", "Presentation"))
        roles = ", ".join(f"{role}={clip}" for role, clip in data["presentation"]["roles"].items() if clip) or "없음"
        parts.append(f"<p>offset {list(data['presentation']['visual_offset'])}, scale "
                     f"{list(data['presentation']['visual_scale'])}<br>roles: {roles}</p>")
        parts.append(title("collision", "Collision"))
        parts.append(f"<p>Body: {dict(collision['body']['shape'])}<br>Hurtbox {len(collision['hurtboxes'])}개, "
                     f"Hitbox {len(collision['hitboxes'])}개, Hurtbox override {len(collision['hurtbox_overrides'])}개</p>")
        parts.append(title("attack_patterns", "Attack Patterns"))
        parts.append("<ul>" + "".join(
            f"<li><code>{row['id']}</code> — {row['kind']}, {row['duration']} s, 쿨다운 {row['cooldown']} s, "
            f"이벤트 {len(row['events'])}개</li>" for row in data["attack_patterns"]) + "</ul>"
            if data["attack_patterns"] else "<p>없음</p>")
        parts.append(title("behavior", "Behavior States"))
        rows = []
        for state in behavior["states"]:
            module = registry.modules.get(state["module"])
            support = strings.SUPPORT.get(module.support, module.support) if module else "등록되지 않은 모듈"
            targets = ", ".join(f"→{transition['to']}" for transition in state["transitions"]) or "–"
            rows.append(f"<li><code>{state['id']}</code> — {state['module']} <small>({support})</small> {targets}</li>")
        parts.append(f"<p>시작 상태: <code>{behavior['initial_state']}</code></p><ul>{''.join(rows)}</ul>")
        binding = data["source_binding"]
        parts.append(title("source_binding", "Source Binding"))
        if binding is None:
            parts.append("<p>초안입니다. 게임 리소스에 묶여 있지 않습니다.</p>")
        else:
            unsupported = "".join(f"<li><code>{row['path']}</code>: {row['reason']}</li>" for row in binding["unsupported"])
            parts.append(f"<p>runtime: {binding['runtime']}<br>정의: {binding['definition_path']}<br>"
                         f"원본 파일 {len(binding['files'])}개</p>"
                         + (f"<p>표현할 수 없는 항목:</p><ul>{unsupported}</ul>" if unsupported else ""))
        self.setHtml("".join(parts))


# ----------------------------------------------------------------------------------------------- overview
class OverviewPanel(QWidget):
    """The central workspace of STEP 2. Later workspaces are added next to it as tabs."""

    def __init__(self):
        super().__init__()
        self._session = None
        layout = QVBoxLayout(self)
        top = QHBoxLayout()
        self.thumbnail = QLabel()
        self.thumbnail.setFixedSize(THUMBNAIL_EDGE + 8, THUMBNAIL_EDGE + 8)
        self.thumbnail.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.thumbnail.setStyleSheet("QLabel { border: 1px solid #556; background: #1b202a; }")
        top.addWidget(self.thumbnail)
        text = QVBoxLayout()
        self.name = QLabel()
        self.name.setStyleSheet("QLabel { font-size: 20px; font-weight: bold; }")
        self.identity = QLabel()
        self.identity.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self.description = QLabel()
        self.description.setWordWrap(True)
        for widget in (self.name, self.identity, self.description):
            text.addWidget(widget)
        text.addStretch(1)
        top.addLayout(text, 1)
        layout.addLayout(top)
        box = QGroupBox("문서 요약")
        grid = QGridLayout(box)
        self.values = {}
        for index, (key, label) in enumerate((
                ("binding", "Source Binding"), ("image", "대표 이미지"), ("revision", "문서 Revision"),
                ("clips", "Animation Clip"), ("patterns", "Attack Pattern"), ("states", "AI State"),
                ("boxes", "Hurtbox / Hitbox"), ("validation", "검증 상태"), ("file", "파일"))):
            grid.addWidget(QLabel(label), index, 0)
            value = QLabel()
            value.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
            value.setWordWrap(True)
            grid.addWidget(value, index, 1)
            self.values[key] = value
        grid.setColumnStretch(1, 1)
        layout.addWidget(box)
        layout.addStretch(1)
        self.empty = QLabel("문서가 열려 있지 않습니다.\n파일 → 새 몬스터, 또는 왼쪽 카탈로그에서 몬스터를 선택하세요.")
        self.empty.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(self.empty)
        self._box = box

    def show_session(self, session, project_root, binding_state, validation_text):
        self._session = session
        visible = session is not None
        for widget in (self.thumbnail, self.name, self.identity, self.description, self._box):
            widget.setVisible(visible)
        self.empty.setVisible(not visible)
        if not visible:
            return "none"
        data = session.document.data
        self.name.setText(data["metadata"]["display_name"] or "(이름 없음)")
        self.identity.setText(f"Monster ID: {data['monster_id']}    등급: {strings.choice_label(data['metadata']['rank'])}"
                              + (f"    분류: {data['metadata']['category']}" if data["metadata"]["category"] else ""))
        self.description.setText(data["metadata"]["description"])
        path, rect = representative_frame(data)
        pixmap, state = load_thumbnail(project_root, path, rect)
        if pixmap is None:
            self.thumbnail.setPixmap(QPixmap())
            self.thumbnail.setText(strings.IMAGE_STATE[state])
        else:
            self.thumbnail.setText("")
            self.thumbnail.setPixmap(pixmap)
        collision = data["collision"]
        self.values["binding"].setText(strings.BINDING[binding_state])
        self.values["image"].setText(f"{path or '–'}  ({strings.IMAGE_STATE[state]}; Godot import: "
                                     f"{strings.IMAGE_STATE['unchecked']})")
        self.values["revision"].setText(session.document.fingerprint[:16] + ("  · 수정됨" if session.dirty else "  · 저장됨"))
        self.values["clips"].setText(f"{len(data['animations']['clips'])}개")
        self.values["patterns"].setText(f"{len(data['attack_patterns'])}개")
        self.values["states"].setText(f"{len(data['behavior']['states'])}개")
        self.values["boxes"].setText(f"{len(collision['hurtboxes'])} / {len(collision['hitboxes'])}")
        self.values["validation"].setText(validation_text)
        self.values["file"].setText(str(session.path) if session.path else "(저장되지 않음)")
        return state
