"""Monster catalog and validation findings. Both display core objects and decide nothing themselves."""

from PySide6.QtCore import Qt, Signal
from PySide6.QtGui import QBrush, QColor
from PySide6.QtWidgets import (QComboBox, QHBoxLayout, QLabel, QLineEdit, QTreeWidget, QTreeWidgetItem, QVBoxLayout,
                               QWidget)

from rtcmonster import DOMAINS

from . import strings

ENTRY_ROLE = Qt.ItemDataRole.UserRole
PROBLEM_ROLE = Qt.ItemDataRole.UserRole + 1
FILTERS = (("all", "전체"), ("game", "게임 콘텐츠"), ("draft", "초안"), ("problem", "문제 있음"))
REGISTRATION_COLORS = {"draft": "#8ab4f8", "discovered": "#c9a227", "registry_verified": "#4f9d69",
                       "not_in_registry": "#c8553d"}


class CatalogPanel(QWidget):
    """Game monsters, drafts and problems. Built from ``MonsterCatalog``; no monster is named in code."""
    entry_activated = Signal(object)
    selection_changed = Signal(object)

    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        row = QHBoxLayout()
        self.search = QLineEdit()
        self.search.setPlaceholderText("검색: ID, 이름, 태그, 분류, 등급")
        self.search.setClearButtonEnabled(True)
        self.filter = QComboBox()
        for key, label in FILTERS:
            self.filter.addItem(label, key)
        row.addWidget(self.search, 1)
        row.addWidget(self.filter)
        layout.addLayout(row)
        self.state = QLabel()
        self.state.setWordWrap(True)
        layout.addWidget(self.state)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["몬스터", "상태"])
        self.tree.setRootIsDecorated(True)
        self.tree.setUniformRowHeights(True)
        layout.addWidget(self.tree, 1)
        self._catalog = None
        self._import_support = {}
        self._wanted = None         # the entry the user chose; kept while a filter hides it
        self._rebuilding = False
        self.search.textChanged.connect(self._rebuild)
        self.filter.currentIndexChanged.connect(self._rebuild)
        self.tree.itemActivated.connect(self._activated)
        self.tree.currentItemChanged.connect(self._current_changed)

    def set_catalog(self, catalog, import_support=None, connected=True):
        """Show a catalog. The current selection, search text and filter are kept."""
        self._catalog = catalog
        if import_support is not None:
            self._import_support = dict(import_support)
        if not connected:
            self.state.setText("프로젝트 미연결: 게임 몬스터를 표시할 수 없고 ID 중복을 확인할 수 없습니다.")
        elif not catalog.available:
            self.state.setText("프로젝트의 몬스터 폴더를 읽지 못했습니다. 아래 목록은 완전하지 않을 수 있습니다.")
        elif catalog.registry_checked:
            self.state.setText("Godot Registry 확인 결과를 반영했습니다.")
        else:
            self.state.setText("파일로 발견한 목록입니다. 게임 등록 여부는 Godot Registry 검증으로 확인하세요.")
        self._rebuild()

    def _current_changed(self, current, _previous):
        entry = current.data(0, ENTRY_ROLE) if current else None
        if not self._rebuilding:
            self._wanted = None if entry is None else (entry.source, entry.monster_id, entry.path)
        self.selection_changed.emit(entry)

    def selected_entry(self):
        item = self.tree.currentItem()
        return item.data(0, ENTRY_ROLE) if item else None

    def _matches(self, entry):
        words = self.search.text().lower().split()
        haystack = " ".join((entry.monster_id, entry.display_name, entry.category, entry.rank, *entry.tags)).lower()
        return all(word in haystack for word in words)

    def _rebuild(self):
        key = self._wanted
        self._rebuilding = True
        try:
            self._fill(key)
        finally:
            self._rebuilding = False

    def _fill(self, key):
        self.tree.clear()
        catalog = self._catalog
        if catalog is None:
            return
        mode = self.filter.currentData()
        troubled = {problem.path for problem in catalog.problems} | {
            entry.path for entry in catalog.entries
            if any(problem.id == entry.monster_id for problem in catalog.problems)}
        groups = {"game": QTreeWidgetItem(["게임 콘텐츠"]), "draft": QTreeWidgetItem(["작업 중인 초안"])}
        restore = None
        for entry in sorted(catalog.entries, key=lambda row: (row.source, row.monster_id, row.path)):
            if mode in ("game", "draft") and entry.source != mode:
                continue
            if mode == "problem" and entry.path not in troubled:
                continue
            if not self._matches(entry):
                continue
            status = strings.REGISTRATION[entry.registration]
            if entry.path in troubled:
                status += " · 문제 있음"
            if entry.source == "game" and entry.monster_id in self._import_support:
                status += " · " + strings.IMPORT_STATUS[self._import_support[entry.monster_id]]
            if entry.bound_to:
                status += " · 기존 몬스터 수정본"
            item = QTreeWidgetItem([f"{entry.display_name or '(이름 없음)'}  [{entry.monster_id}]", status])
            item.setData(0, ENTRY_ROLE, entry)
            item.setToolTip(0, entry.path)
            item.setForeground(1, QBrush(QColor(REGISTRATION_COLORS[entry.registration])))
            groups[entry.source].addChild(item)
            if key == (entry.source, entry.monster_id, entry.path):
                restore = item
        for group in groups.values():
            if group.childCount() or mode == "all":
                group.setText(0, f"{group.text(0)} ({group.childCount()})")
                self.tree.addTopLevelItem(group)
                group.setExpanded(True)
        if catalog.problems and mode in ("all", "problem"):
            problems = QTreeWidgetItem([f"문제가 발견된 콘텐츠 ({len(catalog.problems)})"])
            for problem in catalog.problems:
                item = QTreeWidgetItem([f"{strings.PROBLEMS.get(problem.code, problem.code)}"
                                        + (f"  [{problem.id}]" if problem.id else ""), problem.path])
                item.setData(0, PROBLEM_ROLE, problem)
                item.setToolTip(0, f"{problem.code}\n{problem.path}\n{problem.detail}")
                item.setToolTip(1, problem.detail)
                item.setForeground(0, QBrush(QColor(strings.STATUS_COLORS["FAIL"])))
                problems.addChild(item)
            self.tree.addTopLevelItem(problems)
            problems.setExpanded(True)
        self.tree.resizeColumnToContents(0)
        self.tree.setColumnWidth(0, min(self.tree.columnWidth(0), 340))
        if restore is not None:
            self.tree.setCurrentItem(restore)

    def entries_shown(self):
        """Entries currently visible, for tests and for keyboard navigation."""
        shown = []
        for index in range(self.tree.topLevelItemCount()):
            group = self.tree.topLevelItem(index)
            shown += [group.child(row).data(0, ENTRY_ROLE) for row in range(group.childCount())
                      if group.child(row).data(0, ENTRY_ROLE) is not None]
        return shown

    def select(self, source, monster_id):
        for index in range(self.tree.topLevelItemCount()):
            group = self.tree.topLevelItem(index)
            for row in range(group.childCount()):
                entry = group.child(row).data(0, ENTRY_ROLE)
                if entry is not None and (entry.source, entry.monster_id) == (source, monster_id):
                    self.tree.setCurrentItem(group.child(row))
                    return True
        return False

    def _activated(self, item, _column):
        entry = item.data(0, ENTRY_ROLE)
        if entry is not None:
            self.entry_activated.emit(entry)


class ValidationPanel(QWidget):
    """Eleven domain states and the list of findings. NOT_EVALUATED is never drawn like PASS."""
    finding_activated = Signal(object)

    def __init__(self):
        super().__init__()
        layout = QVBoxLayout(self)
        layout.setContentsMargins(4, 4, 4, 4)
        chips = QHBoxLayout()
        self.chips = {}
        for domain in DOMAINS:
            chip = QLabel()
            chip.setAlignment(Qt.AlignmentFlag.AlignCenter)
            chip.setMargin(3)
            chips.addWidget(chip)
            self.chips[domain] = chip
        chips.addStretch(1)
        layout.addLayout(chips)
        self.banner = QLabel()
        self.banner.setWordWrap(True)
        layout.addWidget(self.banner)
        self.tree = QTreeWidget()
        self.tree.setHeaderLabels(["상태", "영역", "Finding Code", "위치", "대상", "설명", "관련 리소스", "수정 위치"])
        self.tree.setRootIsDecorated(False)
        self.tree.setUniformRowHeights(True)
        layout.addWidget(self.tree, 1)
        self.tree.itemActivated.connect(lambda item, _column: self.finding_activated.emit(
            item.data(0, Qt.ItemDataRole.UserRole)))
        self.show_report(None, "none")

    def show_report(self, report, state):
        """``state`` is current / stale / none (see application.work)."""
        self.tree.clear()
        for domain, chip in self.chips.items():
            status = report.status(domain) if report is not None else "NOT_EVALUATED"
            color = strings.STATUS_COLORS[status] if state == "current" else "#555b66"
            chip.setText(f"{strings.DOMAINS[domain]}\n{strings.STATUS[status]}")
            chip.setProperty("status", status)
            chip.setStyleSheet(f"QLabel {{ background: {color}; color: white; border-radius: 3px; }}")
        if report is None:
            self.banner.setText("검증 결과가 없습니다. 검증 → 현재 문서 검증 (F6)")
            return
        if state == "stale":
            self.banner.setText("⚠ 이 결과는 오래되었습니다. 문서나 프로젝트가 검증 이후 바뀌었습니다. 다시 검증하세요.")
        else:
            blocking = len(report.blocking)
            self.banner.setText(f"실패 {blocking}건 · 미검사 영역: "
                                + (", ".join(strings.DOMAINS[d] for d in report.unverified) or "없음")
                                + " · 미검사는 통과가 아닙니다.")
        order = {"FAIL": 0, "WARNING": 1, "NOT_EVALUATED": 2, "PASS": 3}
        for finding in sorted(report.findings, key=lambda row: order[row.status]):
            if finding.status == "PASS":
                continue
            item = QTreeWidgetItem([strings.STATUS[finding.status], strings.DOMAINS[finding.domain], finding.code,
                                    finding.path, finding.subject, finding.detail or finding.summary,
                                    ", ".join(finding.related), strings.REMEDY[finding.remedy]])
            item.setData(0, Qt.ItemDataRole.UserRole, finding)
            item.setToolTip(5, finding.summary)
            color = strings.STATUS_COLORS[finding.status] if state == "current" else "#8a8f99"
            item.setForeground(0, QBrush(QColor(color)))
            self.tree.addTopLevelItem(item)
        for column in (0, 1, 2, 3):
            self.tree.resizeColumnToContents(column)
        self.tree.setColumnWidth(5, max(self.tree.columnWidth(5), 420))

    def findings_shown(self):
        return [self.tree.topLevelItem(index).data(0, Qt.ItemDataRole.UserRole)
                for index in range(self.tree.topLevelItemCount())]
