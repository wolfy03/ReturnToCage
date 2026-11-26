"""Dialogs, and ``Prompts``: every question the window asks the user.

The window never opens a message box or a file dialog directly; it asks its ``prompts`` object. Tests
replace that object with scripted answers, so a workflow can be driven without a modal dialog blocking it,
while the real dialogs below stay small enough to be tested on their own.
"""

from pathlib import Path
import re

from PySide6.QtWidgets import (QComboBox, QDialog, QDialogButtonBox, QFileDialog, QFormLayout, QHBoxLayout, QLabel,
                               QLineEdit, QMessageBox, QPlainTextEdit, QPushButton, QVBoxLayout, QWidget)

from rtcmonster import SUFFIX
from rtcmonster.spec import ID_PATTERN

from . import strings

SAVE, DISCARD, CANCEL = "save", "discard", "cancel"
RELOAD, SAVE_AS, OVERWRITE = "reload", "save_as", "overwrite"
ID_COLORS = {"available": "#4f9d69", "conflict": "#c8553d", "unknown": "#c9a227", "invalid": "#c8553d"}


class IdField(QWidget):
    """A Monster ID input that shows whether the ID is valid and free. ``check`` returns an IdCheck."""

    def __init__(self, check):
        super().__init__()
        self._check = check
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        self.edit = QLineEdit()
        self.edit.setPlaceholderText("snake_case (예: cave_spider)")
        self.status = QLabel()
        layout.addWidget(self.edit)
        layout.addWidget(self.status)
        self.state = "invalid"
        self.edit.textChanged.connect(self.refresh)
        self.refresh()

    def text(self):
        return self.edit.text().strip()

    def refresh(self):
        value = self.text()
        if not re.fullmatch(ID_PATTERN, value):
            self.state, text = "invalid", "소문자·숫자·밑줄만, 소문자로 시작 (최대 64자)"
        else:
            result = self._check(value)
            self.state = result.status
            text = strings.ID_STATUS[result.status]
            if result.conflicts:
                text += ": " + ", ".join(result.conflicts)
        self.status.setText(text)
        self.status.setStyleSheet(f"QLabel {{ color: {ID_COLORS[self.state]}; }}")

    @property
    def acceptable(self):
        """A conflict blocks. UNKNOWN does not: without a project a draft may still be created."""
        return self.state in ("available", "unknown")


class NewMonsterDialog(QDialog):
    def __init__(self, parent, id_check, drafts_folder):
        super().__init__(parent)
        self.setWindowTitle("새 몬스터")
        form = QFormLayout(self)
        self.monster_id = IdField(id_check)
        self.display_name = QLineEdit()
        self.rank = QComboBox()
        for value in ("normal", "elite", "boss"):
            self.rank.addItem(strings.choice_label(value), value)
        self.category = QLineEdit()
        self.category.setPlaceholderText("선택 (예: beetle)")
        self.description = QPlainTextEdit()
        self.description.setMaximumHeight(80)
        self.folder = QLineEdit(str(drafts_folder or ""))
        browse = QPushButton("찾아보기…")
        browse.clicked.connect(self._browse)
        row = QHBoxLayout()
        row.addWidget(self.folder, 1)
        row.addWidget(browse)
        form.addRow("Monster ID", self.monster_id)
        form.addRow("표시 이름", self.display_name)
        form.addRow("등급 (Rank)", self.rank)
        form.addRow("분류", self.category)
        form.addRow("설명", self.description)
        form.addRow("초안 저장 폴더", row)
        self.note = QLabel("등급은 아직 게임에 적용되지 않는 예정 항목입니다. 폴더를 비우면 저장할 때 위치를 묻습니다.")
        self.note.setWordWrap(True)
        form.addRow(self.note)
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        form.addRow(self.buttons)
        self.monster_id.edit.textChanged.connect(self._update)
        self.display_name.textChanged.connect(self._update)
        self._update()

    def _browse(self):
        folder = QFileDialog.getExistingDirectory(self, "초안 저장 폴더", self.folder.text())
        if folder:
            self.folder.setText(folder)

    def _update(self):
        self.buttons.button(QDialogButtonBox.StandardButton.Ok).setEnabled(
            self.monster_id.acceptable and bool(self.display_name.text().strip()))

    def values(self):
        return {"monster_id": self.monster_id.text(), "display_name": self.display_name.text().strip(),
                "rank": self.rank.currentData(), "category": self.category.text().strip(),
                "description": self.description.toPlainText(), "folder": self.folder.text().strip(),
                "id_state": self.monster_id.state}


class CloneDialog(QDialog):
    def __init__(self, parent, source_document, id_check):
        super().__init__(parent)
        self.setWindowTitle("몬스터 복제")
        form = QFormLayout(self)
        form.addRow(QLabel(f"원본: {source_document.data['metadata']['display_name']} [{source_document.monster_id}]"))
        self.monster_id = IdField(id_check)
        self.monster_id.edit.setText(source_document.monster_id + "_copy")
        self.display_name = QLineEdit(source_document.data["metadata"]["display_name"] + " (복제)")
        form.addRow("새 Monster ID", self.monster_id)
        form.addRow("표시 이름", self.display_name)
        note = QLabel("복제본은 새 초안입니다. 원본의 게임 리소스에 묶이지 않고, 원본 파일은 바뀌지 않습니다.")
        note.setWordWrap(True)
        form.addRow(note)
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        form.addRow(self.buttons)
        self.monster_id.edit.textChanged.connect(self._update)
        self._update()

    def _update(self):
        self.buttons.button(QDialogButtonBox.StandardButton.Ok).setEnabled(
            self.monster_id.acceptable and self.monster_id.text() != "")

    def values(self):
        return {"monster_id": self.monster_id.text(), "display_name": self.display_name.text().strip()}


class ProjectSettingsDialog(QDialog):
    def __init__(self, parent, values):
        super().__init__(parent)
        self.setWindowTitle("프로젝트 설정")
        self.setMinimumWidth(620)
        form = QFormLayout(self)
        self.fields = {}
        for key, label, folder in (("project_root", "ReturnToCage 프로젝트 폴더", True),
                                   ("godot_path", "Godot 실행 파일", False),
                                   ("drafts_folder", "몬스터 초안 작업 폴더", True),
                                   ("logs_folder", "로그 · 테스트 결과 폴더 (선택)", True)):
            edit = QLineEdit(values.get(key, ""))
            button = QPushButton("찾아보기…")
            button.clicked.connect(lambda _checked=False, edit=edit, folder=folder: self._browse(edit, folder))
            row = QHBoxLayout()
            row.addWidget(edit, 1)
            row.addWidget(button)
            form.addRow(label, row)
            self.fields[key] = edit
        note = QLabel("프로젝트를 비워 두어도 문서를 만들고 편집·저장할 수 있습니다. 그 경우 프로젝트가 필요한 검사는 "
                      "'미검사'로 표시됩니다. Godot은 몬스터 가져오기와 Registry 검증에만 쓰이며, 버전은 "
                      "'Godot → 연결 및 버전 검사'에서 확인합니다.")
        note.setWordWrap(True)
        form.addRow(note)
        self.error = QLabel()
        self.error.setWordWrap(True)
        self.error.setStyleSheet("QLabel { color: #e07a5f; }")
        form.addRow(self.error)
        self.buttons = QDialogButtonBox(QDialogButtonBox.StandardButton.Ok | QDialogButtonBox.StandardButton.Cancel)
        self.buttons.accepted.connect(self.accept)
        self.buttons.rejected.connect(self.reject)
        form.addRow(self.buttons)

    def _browse(self, edit, folder):
        if folder:
            chosen = QFileDialog.getExistingDirectory(self, "폴더 선택", edit.text())
        else:
            chosen, _ = QFileDialog.getOpenFileName(self, "Godot 실행 파일", edit.text())
        if chosen:
            edit.setText(chosen)

    def values(self):
        return {key: edit.text().strip() for key, edit in self.fields.items()}


class Prompts:
    """The real user interface for questions. Each method returns plain data."""

    def __init__(self, parent):
        self.parent = parent

    def unsaved_changes(self, name):
        box = QMessageBox(self.parent)
        box.setIcon(QMessageBox.Icon.Warning)
        box.setWindowTitle("저장되지 않은 변경사항")
        box.setText(f"'{name}'에 저장하지 않은 변경사항이 있습니다.")
        save = box.addButton("저장", QMessageBox.ButtonRole.AcceptRole)
        discard = box.addButton("저장하지 않음", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton("취소", QMessageBox.ButtonRole.RejectRole)
        box.exec()
        return SAVE if box.clickedButton() is save else DISCARD if box.clickedButton() is discard else CANCEL

    def conflict(self, path):
        box = QMessageBox(self.parent)
        box.setIcon(QMessageBox.Icon.Warning)
        box.setWindowTitle("파일이 외부에서 변경됨")
        box.setText(f"{path}\n\n이 파일이 편집기 밖에서 바뀌었습니다. 저장하지 않았습니다.")
        reload_ = box.addButton("디스크의 문서 다시 열기", QMessageBox.ButtonRole.ActionRole)
        save_as = box.addButton("다른 이름으로 저장", QMessageBox.ButtonRole.ActionRole)
        overwrite = box.addButton("내 변경으로 덮어쓰기", QMessageBox.ButtonRole.DestructiveRole)
        box.addButton("취소", QMessageBox.ButtonRole.RejectRole)
        box.exec()
        clicked = box.clickedButton()
        return RELOAD if clicked is reload_ else SAVE_AS if clicked is save_as else \
            OVERWRITE if clicked is overwrite else CANCEL

    def confirm(self, title, text):
        return QMessageBox.question(self.parent, title, text) == QMessageBox.StandardButton.Yes

    def open_path(self, folder):
        path, _ = QFileDialog.getOpenFileName(self.parent, "몬스터 문서 열기", str(folder or ""),
                                              f"Monster Document (*{SUFFIX})")
        return Path(path) if path else None

    def save_path(self, suggested):
        # The editor asks about overwriting itself, with the revision the user saw.
        path, _ = QFileDialog.getSaveFileName(self.parent, "다른 이름으로 저장", str(suggested),
                                              f"Monster Document (*{SUFFIX})",
                                              options=QFileDialog.Option.DontConfirmOverwrite)
        if not path:
            return None
        return Path(path if path.lower().endswith(SUFFIX) else path + SUFFIX)

    def new_monster(self, id_check, drafts_folder):
        dialog = NewMonsterDialog(self.parent, id_check, drafts_folder)
        return dialog.values() if dialog.exec() == QDialog.DialogCode.Accepted else None

    def clone(self, document, id_check):
        dialog = CloneDialog(self.parent, document, id_check)
        return dialog.values() if dialog.exec() == QDialog.DialogCode.Accepted else None

    def project_settings(self, values):
        dialog = ProjectSettingsDialog(self.parent, values)
        return dialog.values() if dialog.exec() == QDialog.DialogCode.Accepted else None

    def image_path(self, project_root):
        path, _ = QFileDialog.getOpenFileName(self.parent, "PNG 이미지 선택", str(project_root), "PNG (*.png)")
        return Path(path) if path else None

    def error(self, title, text):
        QMessageBox.critical(self.parent, title, text)

    def info(self, title, text):
        QMessageBox.information(self.parent, title, text)
