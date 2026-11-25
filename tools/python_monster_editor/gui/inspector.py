"""Inspector built from schema metadata.

There is no form written per field. ``build`` walks ``document.schema.fields`` and asks the editor
registry for a widget that fits each node (its type, its range, its unit, its hint). A new schema field in
an editable section therefore appears in the inspector without any change here, and a new widget kind is
one ``register_editor`` call.

Widgets only show and collect input. A committed value is emitted as ``edit_requested(path, value)``; the
window applies it through the document session, which is the only place a document changes.
"""

from PySide6.QtCore import QEvent, Qt, Signal
from PySide6.QtGui import QKeySequence
from PySide6.QtWidgets import (QCheckBox, QComboBox, QDoubleSpinBox, QFormLayout, QGroupBox, QHBoxLayout, QLabel,
                               QLineEdit, QPlainTextEdit, QScrollArea, QSpinBox, QTabWidget, QVBoxLayout, QWidget)

from rtcmonster import format_path
from rtcmonster.spec import Arr, Bool, Choice, Id, Map, Num, Obj, Opt, ProjectPath, Str, field_capabilities

from . import strings

FORM_SECTIONS = ("metadata", "stats", "movement", "sensors")


class _UndoPassThrough:
    """Lets Ctrl+Z / Ctrl+Y reach the document while a text widget has nothing of its own to undo.

    Qt text widgets claim the undo keys for themselves. Typing in a field keeps that behaviour; once the
    field holds no uncommitted change, the keys fall through to the window's Undo/Redo actions.
    """

    def _install(self, widget):
        widget.installEventFilter(self)

    def _has_pending_text(self):
        return False

    def eventFilter(self, watched, event):
        if event.type() == QEvent.Type.ShortcutOverride and (
                event.matches(QKeySequence.StandardKey.Undo) or event.matches(QKeySequence.StandardKey.Redo)):
            if not self._has_pending_text():
                event.ignore()
                return True
        return super().eventFilter(watched, event)


class FieldEditor(QWidget):
    """Base of every inspector widget. ``committed`` fires once per finished edit, never per keystroke."""
    committed = Signal(object)

    def __init__(self, info):
        super().__init__()
        self.info = info
        self._layout = QHBoxLayout(self)
        self._layout.setContentsMargins(0, 0, 0, 0)
        self._value = None

    def set_value(self, value):
        self._value = value
        self._show(value)

    def value(self):
        return self._value

    def _commit(self, value):
        if value != self._value:
            self.committed.emit(value)

    def set_read_only(self, read_only):
        self.setEnabled(not read_only)

    def focus_field(self):
        self.setFocus()

    def _show(self, value):
        raise NotImplementedError


class TextEditor(_UndoPassThrough, FieldEditor):
    def __init__(self, info):
        super().__init__(info)
        self.edit = QLineEdit()
        self._layout.addWidget(self.edit)
        self.edit.editingFinished.connect(lambda: self._commit(self._read()))
        self._install(self.edit)

    def _has_pending_text(self):
        return self.edit.isModified()

    def _read(self):
        return self.edit.text()

    def _show(self, value):
        self.edit.setText("" if value is None else str(value))
        self.edit.setModified(False)

    def focus_field(self):
        self.edit.setFocus()
        self.edit.selectAll()


class TagsEditor(TextEditor):
    """A list of identifiers typed as comma-separated text."""

    def _read(self):
        return [part.strip() for part in self.edit.text().replace(" ", ",").split(",") if part.strip()]

    def _show(self, value):
        self.edit.setText(", ".join(value or ()))
        self.edit.setModified(False)


class MultilineEditor(_UndoPassThrough, FieldEditor):
    def __init__(self, info):
        super().__init__(info)
        self.edit = QPlainTextEdit()
        self.edit.setMinimumHeight(64)
        self.edit.setMaximumHeight(120)
        self.edit.setTabChangesFocus(True)
        self._layout.addWidget(self.edit)
        self.edit.installEventFilter(self)

    def _has_pending_text(self):
        return self.edit.document().isModified()

    def eventFilter(self, watched, event):
        if watched is self.edit and event.type() == QEvent.Type.FocusOut:
            self._commit(self.edit.toPlainText())
        return super().eventFilter(watched, event)

    def _show(self, value):
        if self.edit.toPlainText() != (value or ""):
            self.edit.setPlainText(value or "")
        self.edit.document().setModified(False)

    def focus_field(self):
        self.edit.setFocus()


class NumberEditor(_UndoPassThrough, FieldEditor):
    def __init__(self, info, nullable=False):
        super().__init__(info)
        integer = info["type"].startswith("integer")
        self.spin = QSpinBox() if integer else QDoubleSpinBox()
        low = info["minimum"] if info["minimum"] is not None else -1_000_000
        high = info["maximum"] if info["maximum"] is not None else 1_000_000
        if integer:
            self.spin.setRange(int(max(low, -2 ** 31)), int(min(high, 2 ** 31 - 1)))
        else:
            self.spin.setDecimals(3)
            # The editor does not clamp to the schema range: an out-of-range draft must stay visible and
            # is reported by validation. The range is shown in the tooltip instead.
            self.spin.setRange(-1e9, 1e9)
            self.spin.setSingleStep(max(0.01, (high - low) / 200) if high - low < 100 else 1)
        if info["unit"]:
            self.spin.setSuffix(f" {info['unit']}")
        self.spin.setKeyboardTracking(False)
        self.toggle = QCheckBox("설정") if nullable else None
        if self.toggle is not None:
            self._layout.addWidget(self.toggle)
            self.toggle.toggled.connect(self._toggled)
        self._layout.addWidget(self.spin, 1)
        self.spin.editingFinished.connect(lambda: self._commit(self._read()))
        self._install(self.spin)
        self._install(self.spin.lineEdit())
        self._integer = integer

    def _has_pending_text(self):
        return self.spin.lineEdit().isModified()

    def _read(self):
        if self.toggle is not None and not self.toggle.isChecked():
            return None
        value = self.spin.value()
        return value if self._integer or not float(value).is_integer() else int(value)

    def _toggled(self, checked):
        self.spin.setEnabled(checked)
        self._commit(self._read())

    def _show(self, value):
        for widget in (self.spin, self.toggle):
            if widget is not None:
                widget.blockSignals(True)
        if self.toggle is not None:
            self.toggle.setChecked(value is not None)
            self.spin.setEnabled(value is not None)
        if value is not None:
            self.spin.setValue(value)
        self.spin.lineEdit().setModified(False)
        for widget in (self.spin, self.toggle):
            if widget is not None:
                widget.blockSignals(False)

    def focus_field(self):
        self.spin.setFocus()
        self.spin.selectAll()


class BoolEditor(FieldEditor):
    def __init__(self, info):
        super().__init__(info)
        self.box = QCheckBox()
        self._layout.addWidget(self.box)
        self.box.clicked.connect(lambda checked: self._commit(bool(checked)))

    def _show(self, value):
        self.box.setChecked(bool(value))

    def focus_field(self):
        self.box.setFocus()


class ChoiceEditor(FieldEditor):
    def __init__(self, info):
        super().__init__(info)
        self.combo = QComboBox()
        for option in info["choices"]:
            self.combo.addItem(strings.choice_label(option), option)
        self._layout.addWidget(self.combo)
        self.combo.activated.connect(lambda _index: self._commit(self.combo.currentData()))

    def _show(self, value):
        self.combo.setCurrentIndex(max(0, self.combo.findData(value)))

    def focus_field(self):
        self.combo.setFocus()


class ReadOnlyValue(FieldEditor):
    """Shown for values the inspector has no editor for yet. Never editable."""

    def __init__(self, info):
        super().__init__(info)
        self.label = QLabel()
        self.label.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        self._layout.addWidget(self.label)

    def _show(self, value):
        self.label.setText("–" if value in (None, "", {}, []) else str(value))

    def set_read_only(self, read_only):
        pass


_EDITORS = []


def register_editor(matches, factory):
    """Register a widget for schema nodes. ``matches(node)`` is tried newest first, so a later, more
    specific registration wins over the generic ones below."""
    _EDITORS.insert(0, (matches, factory))


def editor_for(node):
    info = node.info()
    for matches, factory in _EDITORS:
        if matches(node):
            return factory(node, info)
    return ReadOnlyValue(info)


register_editor(lambda node: isinstance(node, Map), lambda node, info: ReadOnlyValue(info))
register_editor(lambda node: isinstance(node, (Str, Id, ProjectPath)), lambda node, info: TextEditor(info))
register_editor(lambda node: isinstance(node, Str) and (node.multiline or node.hint == "multiline"),
                lambda node, info: MultilineEditor(info))
register_editor(lambda node: isinstance(node, Arr) and isinstance(node.item, Id), lambda node, info: TagsEditor(info))
register_editor(lambda node: isinstance(node, Num), lambda node, info: NumberEditor(info))
register_editor(lambda node: isinstance(node, Opt) and isinstance(node.node, Num),
                lambda node, info: NumberEditor(info, nullable=True))
register_editor(lambda node: isinstance(node, Bool), lambda node, info: BoolEditor(info))
register_editor(lambda node: isinstance(node, Choice), lambda node, info: ChoiceEditor(info))


def describe_field(path, node, editability, support=None):
    """Tooltip text: what the field is, its range, and what the game does with it today.

    ``support`` overrides the node's own level when a containing group is weaker (a field inside a
    planned group is planned, whatever its own default says).
    """
    info = dict(node.info())
    if support is not None:
        info["support"] = support
    stages = field_capabilities(path, info["support"])
    lines = [format_path(path)]
    if info["description"]:
        lines.append(info["description"])
    if info["range"]:
        lines.append(f"범위: {info['range']}" + (f" {info['unit']}" if info["unit"] else ""))
    lines.append(f"기본값: {info['default']!r}")
    lines.append("지원: " + strings.SUPPORT.get(info["support"], info["support"]))
    lines.append("편집기: " + strings.EDITABILITY.get(editability, editability)
                 + (" · 편집 지원" if stages["editor_editable"] else " · 이후 단계에서 편집"))
    lines.append("데이터 런타임: " + ("지원" if stages["data_runtime"] else "미지원 (아직 없음)"))
    return "\n".join(lines)


class InspectorPanel(QWidget):
    edit_requested = Signal(tuple, object)

    def __init__(self):
        super().__init__()
        self.tabs = QTabWidget()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.tabs)
        self._editors = {}          # tuple path -> FieldEditor
        self._tab_of = {}           # section -> tab index
        self._session = None
        self.loot_editor = None
        self.summary = None

    def build(self, session, loot_editor, summary):
        """Create the forms for a document. Called when a document is opened, not on every edit."""
        self.tabs.clear()
        self._editors.clear()
        self._tab_of.clear()
        self._session = session
        self.loot_editor, self.summary = loot_editor, summary
        if session is None:
            return
        document = session.document
        forms = {}
        for section in FORM_SECTIONS:
            page = QWidget()
            form = QFormLayout(page)
            form.setFieldGrowthPolicy(QFormLayout.FieldGrowthPolicy.ExpandingFieldsGrow)
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setWidget(page)
            self._tab_of[section] = self.tabs.addTab(scroll, strings.SECTIONS[section])
            forms[section] = (form, {})
        seen = set()
        for path, node, _value in document.schema.fields(document.data):
            if not path or path[0] not in forms or path in seen or isinstance(node, Obj) \
                    or any(isinstance(key, int) for key in path) or len(path) > 3:
                continue
            if len(path) == 3 and not isinstance(document.schema.field(document.data, path[:2])[0], Obj):
                continue        # an entry inside a map or list is shown by its container
            seen.add(path)
            form, groups = forms[path[0]]
            target = form
            if len(path) == 3:
                if path[1] not in groups:
                    group = document.schema.field(document.data, path[:2])[0]
                    box = QGroupBox(strings.SUPPORT["planned"] if group.support == "planned" else path[1])
                    groups[path[1]] = QFormLayout(box)
                    form.addRow(box)
                target = groups[path[1]]
            editor = editor_for(node)
            editor.committed.connect(lambda value, path=path: self.edit_requested.emit(path, value))
            label = QLabel(strings.field_label(format_path(path)))
            group_support = document.schema.field(document.data, path[:2])[0].support if len(path) == 3 else None
            planned = node.support == "planned" or group_support == "planned"
            tip = describe_field(path, node, session.editability(path[0]), "planned" if planned else None)
            label.setToolTip(tip)
            editor.setToolTip(tip)
            if planned:
                label.setText(label.text() + "  ⓘ")
            target.addRow(label, editor)
            self._editors[path] = editor
        self._tab_of["loot"] = self.tabs.addTab(loot_editor, strings.SECTIONS["loot"])
        self._tab_of["summary"] = self.tabs.addTab(summary, strings.SECTIONS["summary"])
        self.refresh()

    def refresh(self):
        """Show the current document's values. Widgets are reused; nothing is rebuilt."""
        if self._session is None:
            return
        data = self._session.document.data
        for path, editor in self._editors.items():
            value = data
            for key in path:
                value = value[key]
            editor.set_value(value)
            editor.set_read_only(not self._session.is_editable(path))

    def editor(self, path):
        return self._editors.get(tuple(path))

    def focus_path(self, path):
        """Show the field a finding points at. Returns False when the inspector has no place for it."""
        path = tuple(path)
        if not path:
            return False
        for length in range(len(path), 0, -1):
            editor = self._editors.get(path[:length])
            if editor is not None:
                self.tabs.setCurrentIndex(self._tab_of[path[0]])
                editor.focus_field()
                return True
        section = path[0] if path[0] in self._tab_of else "summary"
        self.tabs.setCurrentIndex(self._tab_of[section])
        if section == "loot" and self.loot_editor is not None:
            self.loot_editor.focus_path(path)
        elif section == "summary" and self.summary is not None:
            self.summary.highlight(path[0])
        return section != "summary" or path[0] in ("assets", "animations", "presentation", "collision",
                                                   "attack_patterns", "behavior", "source_binding",
                                                   "editor_metadata", "monster_id")
