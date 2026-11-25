"""GUI workflows on the real window with real Qt widgets.

Two kinds of test live here and are named apart:

* ``test_input_...`` send key presses and mouse clicks through ``QTest`` to the same widgets a person uses.
  Window-level shortcuts (Ctrl+S, Ctrl+Z ...) only work on a real windowing system, so those tests are
  skipped on the ``offscreen`` platform and run on Windows.
* the others call the window's public methods; they cover what happens after an input arrives.

Modal dialogs are answered by ``ScriptedPrompts``; the dialog classes themselves are tested directly.
"""

import json
import os

import pytest

pytest.importorskip("PySide6")

from PySide6.QtCore import QPoint, Qt  # noqa: E402
from PySide6.QtGui import QInputMethodEvent, QKeySequence  # noqa: E402
from PySide6.QtTest import QTest  # noqa: E402
from PySide6.QtWidgets import QApplication, QDialogButtonBox  # noqa: E402

from conftest import PROJECT, load  # noqa: E402
from application.settings import Settings  # noqa: E402
from gui import dialogs, panels, strings  # noqa: E402
from gui.inspector import ReadOnlyValue, editor_for, register_editor, _EDITORS  # noqa: E402
from gui.main_window import MainWindow  # noqa: E402
from gui.testing import ScriptedPrompts  # noqa: E402
from rtcmonster import (DOMAINS, FAIL, encode, new_document, read_document, set_value, write_document)  # noqa: E402
from rtcmonster.spec import Num  # noqa: E402

FIXTURE = PROJECT / "tools/python_monster_editor/tests/fixtures/contract_probe.json"


@pytest.fixture(scope="session")
def app():
    application = QApplication.instance() or QApplication([])
    yield application


@pytest.fixture
def native(app):
    if app.platformName() == "offscreen":
        pytest.skip("window shortcuts need a real windowing system; run on Windows")


@pytest.fixture
def drafts(tmp_path):
    folder = tmp_path / "한글 초안"
    folder.mkdir()
    return folder


@pytest.fixture
def window(app, tmp_path, drafts):
    prompts = ScriptedPrompts()
    view = MainWindow(Settings(tmp_path / "settings.json"), prompts)
    view.apply_project_settings({"project_root": "", "godot_path": "", "drafts_folder": str(drafts)})
    view.show()
    QTest.qWaitForWindowExposed(view)
    yield view
    if view.session is not None and view.session.dirty:
        prompts.expect("unsaved_changes", dialogs.DISCARD)
    view.close()
    view.deleteLater()
    app.processEvents()


def new_values(monster_id="cave_spider", name="Cave Spider", folder="", **extra):
    return {"monster_id": monster_id, "display_name": name, "rank": "normal", "category": "", "description": "",
            "folder": str(folder), "id_state": "unknown", **extra}


def create(window, drafts=None, monster_id="cave_spider"):
    window.prompts.expect("new_monster", new_values(monster_id, folder=drafts or ""))
    assert window.new_monster()
    return window.session


def type_into(spin_editor, text, finish=Qt.Key.Key_Return):
    spin_editor.focus_field()             # Tab only commits a field that really has the focus
    QTest.keyClick(spin_editor.spin, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(spin_editor.spin, text)
    QTest.keyClick(spin_editor.spin, finish)


def click(checkbox):
    """Click the box itself: the middle of a stretched check box is empty space, which Qt ignores."""
    QTest.mouseClick(checkbox, Qt.MouseButton.LeftButton, pos=QPoint(8, checkbox.height() // 2))


# ------------------------------------------------------------------------------------------- the window
def test_the_window_starts_empty_and_closes(window):
    assert window.session is None and not window.project.connected
    assert window.windowTitle() == strings.APP_NAME and window.overview.empty.isVisible()
    assert set(window.docks) == {"catalog", "inspector", "validation"} and window.workspaces.count() == 1
    actions = window.actions_by_name
    for name, shortcut in (("new", "Ctrl+N"), ("open", "Ctrl+O"), ("save", "Ctrl+S"), ("save_as", "Ctrl+Shift+S"),
                           ("undo", "Ctrl+Z"), ("refresh", "F5")):
        assert actions[name].shortcut() == QKeySequence(shortcut), name
    assert {key.toString() for key in actions["redo"].shortcuts()} == {"Ctrl+Y", "Ctrl+Shift+Z"}
    for name in ("save", "save_as", "close", "undo", "redo", "clone", "delete", "validate", "import", "registry"):
        assert not actions[name].isEnabled(), name            # nothing to act on yet
    menus = [action.text() for action in window.menuBar().actions()]
    assert menus == ["파일(&F)", "편집(&E)", "보기(&V)", "검증(&A)", "Godot(&G)"]
    later = [action for menu in window.menuBar().actions() for action in menu.menu().actions()
             if "후속 단계" in action.text()]
    assert later and not any(action.isEnabled() for action in later)      # shown, never pretending to work


def test_a_workspace_can_be_added_next_to_the_overview(window):
    from PySide6.QtWidgets import QLabel
    index = window.add_workspace(QLabel("future editor"), "Animation Editor")
    assert index == 1 and window.workspaces.tabText(1) == "Animation Editor"
    assert window.workspaces.widget(0) is window.overview


# ---------------------------------------------------------------------------------------- new and open
def test_input_the_new_monster_dialog_validates_the_id_as_it_is_typed(app, window, drafts):
    write_document(drafts / "taken.rtcmonster", new_document("taken_id", "Taken"))
    window.refresh_catalog()
    dialog = dialogs.NewMonsterDialog(window, lambda monster_id: window.id_check(monster_id, False), drafts)
    dialog.show()
    ok = dialog.buttons.button(QDialogButtonBox.StandardButton.Ok)
    assert not ok.isEnabled() and dialog.monster_id.state == "invalid"
    QTest.keyClicks(dialog.monster_id.edit, "Cave Spider")
    assert dialog.monster_id.state == "invalid" and not ok.isEnabled()
    dialog.monster_id.edit.clear()
    QTest.keyClicks(dialog.monster_id.edit, "taken_id")
    QTest.keyClicks(dialog.display_name, "Name")
    assert dialog.monster_id.state == "conflict" and not ok.isEnabled()
    assert str(drafts / "taken.rtcmonster") in dialog.monster_id.status.text()
    dialog.monster_id.edit.clear()
    QTest.keyClicks(dialog.monster_id.edit, "cave_spider")
    # No project is connected: the ID cannot be confirmed free, which is said but does not block a draft.
    assert dialog.monster_id.state == "unknown" and ok.isEnabled()
    assert strings.ID_STATUS["unknown"] in dialog.monster_id.status.text()
    assert dialog.values()["monster_id"] == "cave_spider" and dialog.values()["folder"] == str(drafts)
    dialog.close()


def test_creating_a_monster_saves_a_draft_and_lists_it(window, drafts):
    window.prompts.expect("new_monster", new_values(folder=drafts, rank="elite", category="arachnid",
                                                    description="여덟 다리"))
    assert window.new_monster()
    session = window.session
    assert session.path == drafts / "cave_spider.rtcmonster" and not session.dirty
    data = read_document(session.path)[0].data
    assert (data["metadata"]["rank"], data["metadata"]["category"], data["metadata"]["description"]) == (
        "elite", "arachnid", "여덟 다리")
    assert "Cave Spider [cave_spider]" in window.windowTitle() and not window.windowTitle().startswith("*")
    shown = window.catalog_panel.entries_shown()
    assert [(entry.source, entry.monster_id, entry.registration) for entry in shown] == [
        ("draft", "cave_spider", "draft")]
    assert "확인하지 못했습니다" in window._last_message      # uniqueness could not be confirmed, and it says so
    assert str(session.path) in window.settings.get("recent_documents")


def test_a_conflicting_id_is_refused_even_if_the_dialog_was_bypassed(window, drafts):
    create(window, drafts)
    window.prompts.expect("new_monster", new_values(folder=drafts))
    assert not window.new_monster()
    assert "이미 사용 중" in window.prompts.last_error()[1]
    assert window.session.document.monster_id == "cave_spider"


@pytest.mark.parametrize("name, payload", [
    ("broken.rtcmonster", b"{ not json"), ("future.rtcmonster", b'{"schema_version": 9, "document_type": "rtcmonster"}'),
    ("shape.rtcmonster", b'{"schema_version": 1, "document_type": "rtcmonster", "monster_id": "x", "extra": 1}'),
    ("notes.txt", b"hello"), ("missing.rtcmonster", None)])
def test_a_file_that_cannot_be_opened_leaves_the_open_document_alone(window, drafts, tmp_path, name, payload):
    session = create(window, drafts)
    window.apply_edits([set_value(("stats", "max_health"), 33)], "edit")
    window.prompts.expect("unsaved_changes", dialogs.DISCARD)
    path = tmp_path / name
    if payload is not None:
        path.write_bytes(payload)
    assert not window.open_document(path)
    assert window.prompts.last_error()[0] == "문서 열기"
    assert window.session is session and session.can_undo and session.document.data["stats"]["max_health"] == 33


def test_opening_a_hand_formatted_file_is_not_an_edit(window, drafts):
    document = new_document("moss_slug", "Moss Slug")
    data = json.loads(encode(document))
    path = drafts / "messy.rtcmonster"
    path.write_text(json.dumps({key: data[key] for key in reversed(list(data))}, indent=8), encoding="utf-8")
    before = path.read_bytes()
    assert window.open_document(path)
    assert not window.session.dirty and not window.windowTitle().startswith("*")
    assert not window.actions_by_name["save"].isEnabled()
    assert window.close_document() and path.read_bytes() == before        # no prompt, no rewrite


# ----------------------------------------------------------------------------------------------- editing
def test_input_typing_a_stat_commits_once_on_enter(window, drafts):
    session = create(window, drafts)
    window.inspector.focus_path(("stats", "max_health"))
    editor = window.inspector.editor(("stats", "max_health"))
    QTest.keyClick(editor.spin, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(editor.spin, "12")
    assert session.document.data["stats"]["max_health"] == 20 and not session.can_undo   # nothing while typing
    QTest.keyClicks(editor.spin, "5")
    QTest.keyClick(editor.spin, Qt.Key.Key_Return)
    assert session.document.data["stats"]["max_health"] == 125 and len(session.history) == 2
    assert window.windowTitle().startswith("*") and window.actions_by_name["save"].isEnabled()
    QTest.keyClick(editor.spin, Qt.Key.Key_Return)                         # same value again: not an edit
    assert len(session.history) == 2
    name = window.inspector.editor(("metadata", "display_name"))
    window.inspector.focus_path(("metadata", "display_name"))
    QTest.keyClick(name.edit, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    commit = QInputMethodEvent()                 # QTest.keyClicks is ASCII only; Korean arrives through the IME
    commit.setCommitString("동굴 거미")
    QApplication.sendEvent(name.edit, commit)
    QTest.keyClick(name.edit, Qt.Key.Key_Tab)
    assert session.document.data["metadata"]["display_name"] == "동굴 거미" and len(session.history) == 3
    assert "동굴 거미 [cave_spider]" in window.windowTitle()


def test_input_choice_checkbox_tags_and_nullable_fields(window, drafts):
    session = create(window, drafts)
    rank = window.inspector.editor(("metadata", "rank"))
    rank.combo.setCurrentIndex(rank.combo.findData("boss"))
    rank.combo.activated.emit(rank.combo.currentIndex())
    assert session.document.data["metadata"]["rank"] == "boss"
    tags = window.inspector.editor(("metadata", "tags"))
    QTest.keyClicks(tags.edit, "cave, web poison")
    QTest.keyClick(tags.edit, Qt.Key.Key_Return)
    assert session.document.data["metadata"]["tags"] == ["cave", "web", "poison"]
    leash = window.inspector.editor(("sensors", "leash_distance"))
    assert not leash.toggle.isChecked() and not leash.spin.isEnabled()
    window.inspector.focus_path(("sensors", "leash_distance"))
    click(leash.toggle)
    assert session.document.data["sensors"]["leash_distance"] is not None
    QTest.keyClick(leash.spin, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(leash.spin, "400")
    QTest.keyClick(leash.spin, Qt.Key.Key_Return)
    assert session.document.data["sensors"]["leash_distance"] == 400
    click(leash.toggle)
    assert session.document.data["sensors"]["leash_distance"] is None
    locomotion = window.inspector.editor(("movement", "locomotion"))
    locomotion.combo.setCurrentIndex(locomotion.combo.findData("hop"))
    locomotion.combo.activated.emit(locomotion.combo.currentIndex())
    assert session.document.data["movement"]["locomotion"] == "hop"


def test_input_a_structurally_wrong_value_is_refused_and_other_fields_keep_their_values(window, drafts):
    session = create(window, drafts)
    type_into(window.inspector.editor(("stats", "max_health")), "77")
    faction = window.inspector.editor(("stats", "faction"))
    history = len(session.history)
    QTest.keyClick(faction.edit, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(faction.edit, "Not A Faction")
    QTest.keyClick(faction.edit, Qt.Key.Key_Return)
    assert session.document.data["stats"]["faction"] == "hostile" and len(session.history) == history
    assert faction.edit.text() == "hostile" and "적용하지 않았습니다" in window._last_message
    assert window.inspector.editor(("stats", "max_health")).spin.value() == 77
    # Out of range is a different thing: a draft may hold it, and validation reports it.
    type_into(window.inspector.editor(("stats", "attack_range")), "-5")
    assert session.document.data["stats"]["attack_range"] == -5
    assert "out_of_range" in window.validate_now().codes()


def test_several_fields_changed_together_are_one_undo_step(window, drafts):
    session = create(window, drafts)
    assert window.apply_edits([set_value(("stats", "max_health"), 30), set_value(("stats", "move_speed"), 70),
                               set_value(("metadata", "tags"), ["cave"])], "일괄 수정")
    assert len(session.history) == 2 and window.actions_by_name["undo"].text() == "실행 취소: 일괄 수정"
    window.undo()
    assert (session.document.data["stats"]["max_health"], session.document.data["stats"]["move_speed"],
            session.document.data["metadata"]["tags"]) == (20, 55, [])
    assert window.inspector.editor(("stats", "max_health")).spin.value() == 20
    assert not session.dirty and not window.windowTitle().startswith("*")
    assert window.actions_by_name["redo"].text() == "다시 실행: 일괄 수정"
    window.redo()
    assert session.document.data["stats"]["move_speed"] == 70 and session.dirty
    window.undo()
    window.apply_edits([set_value(("stats", "attack_damage"), 9)], "다른 편집")
    assert not session.can_redo and len(session.history) == 2            # the redo branch is gone


def test_input_shortcuts_undo_redo_and_save(native, window, drafts):
    session = create(window, drafts)
    type_into(window.inspector.editor(("stats", "max_health")), "45")
    type_into(window.inspector.editor(("stats", "move_speed")), "80", Qt.Key.Key_Tab)
    QTest.keySequence(window, QKeySequence("Ctrl+Z"))
    assert session.document.data["stats"]["move_speed"] == 55 and session.document.data["stats"]["max_health"] == 45
    QTest.keySequence(window, QKeySequence("Ctrl+Z"))
    assert session.document.data["stats"]["max_health"] == 20 and not session.dirty
    QTest.keySequence(window, QKeySequence("Ctrl+Y"))
    QTest.keySequence(window, QKeySequence("Ctrl+Shift+Z"))
    assert session.document.data["stats"]["move_speed"] == 80 and session.dirty
    QTest.keySequence(window, QKeySequence("Ctrl+S"))
    assert not session.dirty and read_document(session.path)[0].data["stats"]["move_speed"] == 80
    assert session.can_undo                                               # saving keeps the history


def test_input_undo_inside_a_text_field_is_the_fields_own_until_it_is_committed(native, window, drafts):
    session = create(window, drafts)
    type_into(window.inspector.editor(("stats", "max_health")), "45")
    name = window.inspector.editor(("metadata", "display_name"))
    window.inspector.focus_path(("metadata", "display_name"))
    QTest.keyClick(name.edit, Qt.Key.Key_End)
    QTest.keyClicks(name.edit, "XYZ")
    QTest.keySequence(name.edit, QKeySequence("Ctrl+Z"))                  # undoes typing, not the document
    assert session.document.data["stats"]["max_health"] == 45 and "XYZ" not in name.edit.text()
    QTest.keyClick(name.edit, Qt.Key.Key_Tab)
    window.inspector.focus_path(("metadata", "display_name"))
    QTest.keySequence(name.edit, QKeySequence("Ctrl+Z"))                  # nothing pending: reaches the document
    assert session.document.data["stats"]["max_health"] == 20


# ------------------------------------------------------------------------------------------------ saving
def test_save_as_asks_before_replacing_and_checks_the_file_again(window, drafts):
    session = create(window, drafts)
    other = drafts / "other.rtcmonster"
    write_document(other, new_document("other_one", "Other"))
    original = other.read_bytes()
    window.prompts.expect("save_path", other).expect("confirm", False)
    assert not window.save_as() and other.read_bytes() == original and session.path != other

    def edit_behind_the_back(_title, _text):
        other.write_bytes(encode(new_document("other_one", "Changed while the question was open")))
        return True
    window.prompts.expect("save_path", other).expect("confirm", edit_behind_the_back)
    assert not window.save_as()
    assert "바뀌어 저장하지 않았습니다" in window.prompts.last_error()[1]
    assert read_document(other)[0].data["metadata"]["display_name"] == "Changed while the question was open"
    window.prompts.expect("save_path", other).expect("confirm", True)
    assert window.save_as() and session.path == other and read_document(other)[0].monster_id == "cave_spider"
    assert (drafts / "cave_spider.rtcmonster").is_file()


@pytest.mark.parametrize("answer", [dialogs.RELOAD, dialogs.OVERWRITE, dialogs.SAVE_AS, dialogs.CANCEL])
def test_an_external_change_offers_four_ways_out_and_none_of_them_is_a_blind_write(window, drafts, answer):
    session = create(window, drafts)
    path = session.path
    window.apply_edits([set_value(("stats", "max_health"), 33)], "mine")
    theirs = encode(new_document("cave_spider", "Edited elsewhere"))
    path.write_bytes(theirs)
    window.prompts.expect("conflict", answer)
    if answer == dialogs.OVERWRITE:
        window.prompts.expect("confirm", True)
    if answer == dialogs.SAVE_AS:
        window.prompts.expect("save_path", drafts / "mine.rtcmonster")
    result = window.save()
    if answer == dialogs.RELOAD:
        assert not result and window.session.document.data["metadata"]["display_name"] == "Edited elsewhere"
        assert not window.session.dirty and path.read_bytes() == theirs
        assert window.inspector.editor(("stats", "max_health")).spin.value() == 20
    elif answer == dialogs.OVERWRITE:
        assert result and read_document(path)[0].data["stats"]["max_health"] == 33
        assert window.prompts.asked("confirm")                   # the overwrite was confirmed explicitly
    elif answer == dialogs.SAVE_AS:
        assert result and path.read_bytes() == theirs and session.path == drafts / "mine.rtcmonster"
    else:
        assert not result and path.read_bytes() == theirs and session.dirty


def test_a_save_that_fails_is_reported_and_changes_no_state(window, drafts, monkeypatch):
    from rtcmonster import storage
    session = create(window, drafts)
    window.apply_edits([set_value(("stats", "max_health"), 33)], "mine")
    monkeypatch.setattr(storage.os, "replace", lambda *_a: (_ for _ in ()).throw(OSError("disk full")))
    assert not window.save()
    assert "저장하지 못했습니다" in window.prompts.last_error()[1] and session.dirty
    assert read_document(session.path)[0].data["stats"]["max_health"] == 20
    # Closing with "Save" must not close when the save fails.
    window.prompts.expect("unsaved_changes", dialogs.SAVE)
    assert not window.close() and window.isVisible() and window.session is session
    monkeypatch.undo()


@pytest.mark.parametrize("answer, closes, saved", [(dialogs.CANCEL, False, False), (dialogs.DISCARD, True, False),
                                                   (dialogs.SAVE, True, True)])
def test_unsaved_changes_are_protected(window, drafts, answer, closes, saved):
    session = create(window, drafts)
    path = session.path
    window.apply_edits([set_value(("stats", "max_health"), 33)], "mine")
    for action in (window.close_document, lambda: window.open_document(path),
                   lambda: window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "",
                                                          "drafts_folder": str(drafts)})):
        if window.session is session and session.dirty:
            window.prompts.expect("unsaved_changes", dialogs.CANCEL)
            assert not action() and window.session is session and session.dirty
    window.prompts.expect("unsaved_changes", answer)
    assert window.close_document() == closes
    assert (window.session is None) == closes
    assert (read_document(path)[0].data["stats"]["max_health"] == 33) == saved
    assert len(window.prompts.asked("unsaved_changes")) == 4


# ------------------------------------------------------------------------------------- clone and delete
def test_cloning_needs_a_new_id_and_never_touches_the_original(window, drafts):
    source = create(window, drafts)
    window.apply_edits([set_value(("loot", "entries"), [{"item_id": "moss_fiber", "weight": 1}]),
                        set_value(("loot", "loot_table_id"), "cave_spider_loot")], "loot")
    window.save()
    original = source.path.read_bytes()
    dialog = dialogs.CloneDialog(window, source.document, window.id_check)
    ok = dialog.buttons.button(QDialogButtonBox.StandardButton.Ok)
    assert dialog.monster_id.text() == "cave_spider_copy" and ok.isEnabled()
    dialog.monster_id.edit.setText("cave_spider")
    assert dialog.monster_id.state == "conflict" and not ok.isEnabled()
    dialog.close()
    window.prompts.expect("clone", {"monster_id": "cave_spider", "display_name": "Same"})
    assert not window.clone_monster() and window.session is source
    window.prompts.expect("clone", {"monster_id": "cave_spider_elder", "display_name": "Cave Spider Elder"})
    assert window.clone_monster()
    clone = window.session
    assert clone is not source and clone.path is None and clone.dirty and clone.binding is None
    data = clone.document.data
    assert (data["monster_id"], data["metadata"]["display_name"]) == ("cave_spider_elder", "Cave Spider Elder")
    assert data["loot"]["loot_table_id"] == "cave_spider_elder_loot" and len(data["loot"]["entries"]) == 1
    window.apply_edits([set_value(("stats", "max_health"), 500)], "edit the clone")
    assert source.path.read_bytes() == original


def test_a_clone_of_an_imported_monster_is_fully_editable_and_gets_a_free_loot_table(window, drafts, beetle):
    write_document(drafts / "sewer_beetle_elder.rtcmonster", new_document("sewer_beetle_elder", "taken name"))
    from application.session import DocumentSession
    window.set_session(DocumentSession(beetle))
    assert not window.session.is_editable(("movement", "gravity"))
    window.prompts.expect("clone", {"monster_id": "cave_beetle", "display_name": ""})
    window.prompts.expect("unsaved_changes", dialogs.DISCARD)
    assert window.clone_monster()
    assert window.session.is_editable(("movement", "gravity")) and window.session.binding is None
    assert window.session.document.data["loot"]["loot_table_id"] == "cave_beetle_loot"
    assert window.session.document.data["stats"]["max_health"] == 24


def test_only_draft_files_can_be_deleted_and_only_after_confirmation(window, drafts):
    create(window, drafts)
    path = window.session.path
    window.catalog_panel.select("draft", "cave_spider")
    assert window.actions_by_name["delete"].isEnabled()
    window.prompts.expect("confirm", False)
    assert not window.delete_selected_draft() and path.is_file()
    title, text = window.prompts.asked("confirm")[-1]
    assert str(path) in text and "cave_spider" in text and "게임 콘텐츠는 삭제되지 않습니다" in text
    path.write_bytes(encode(new_document("cave_spider", "Edited elsewhere")))      # changed since it was listed
    window.prompts.expect("confirm", True)
    assert not window.delete_selected_draft() and path.is_file()
    assert "changed on disk" in window.prompts.last_error()[1]
    window.refresh_catalog()
    window.catalog_panel.select("draft", "cave_spider")
    window.prompts.expect("confirm", True)
    assert window.delete_selected_draft() and not path.exists()
    assert window.session is None and window.catalog_panel.entries_shown() == []
    assert str(path) not in window.settings.get("recent_documents")


# ------------------------------------------------------------------------------------------- inspector
def test_the_inspector_is_generated_from_the_schema(window, drafts):
    session = create(window, drafts)
    document = session.document
    expected = {path for path, node, _ in document.schema.fields(document.data)
                if path and path[0] in ("metadata", "stats", "movement", "sensors") and len(path) == 2
                and type(node).__name__ != "Obj"}
    built = {path for path in window.inspector._editors if len(path) == 2}
    assert built == expected and len(built) >= 20
    assert ("stats", "planned", "defense") in window.inspector._editors
    assert [window.inspector.tabs.tabText(index) for index in range(window.inspector.tabs.count())] == [
        "기본 정보", "능력치", "이동", "감지", "전리품", "요약"]
    editor = window.inspector.editor(("stats", "max_health"))
    tip = editor.toolTip()
    assert "stats.max_health" in tip and "[1, 99999]" in tip and "HP" in tip and editor.spin.suffix() == " HP"
    assert strings.SUPPORT["applied"] in tip and "데이터 런타임: 미지원" in tip
    assert strings.SUPPORT["planned"] in window.inspector.editor(("stats", "planned", "defense")).toolTip()
    assert isinstance(window.inspector.editor(("stats", "planned", "damage_resistances")), ReadOnlyValue)


def test_values_are_refreshed_in_place_not_rebuilt(window, drafts):
    session = create(window, drafts)
    editor = window.inspector.editor(("stats", "max_health"))
    window.apply_edits([set_value(("stats", "max_health"), 64)], "edit")
    window.undo()
    window.redo()
    assert window.inspector.editor(("stats", "max_health")) is editor and editor.spin.value() == 64
    assert session.document.data["stats"]["max_health"] == 64


def test_a_new_widget_kind_is_one_registration(app):
    class Marker(ReadOnlyValue):
        pass
    node = Num(1, 0, 10, "px", hint="slider")
    assert not isinstance(editor_for(node), Marker)
    register_editor(lambda candidate: getattr(candidate, "hint", "") == "slider", lambda node, info: Marker(info))
    try:
        assert isinstance(editor_for(node), Marker)
        assert not isinstance(editor_for(Num(1, 0, 10)), Marker)
    finally:
        _EDITORS.pop(0)


def test_sections_bound_to_legacy_scripts_are_read_only(window, beetle):
    from application.session import DocumentSession
    window.set_session(DocumentSession(beetle))
    assert window.inspector.editor(("stats", "max_health")).isEnabled()
    assert not window.inspector.editor(("movement", "gravity")).isEnabled()
    assert not window.inspector.editor(("sensors", "target_keep_scale")).isEnabled()
    assert not window.apply_edits([set_value(("movement", "gravity"), 900)], "forbidden")
    assert "read_only" in window._last_message and window.session.document.data["movement"]["gravity"] == 1100
    html = window.summary.toHtml()
    for text in ("idle", "bite", "RangeStrike" if False else "ExecuteAttackPattern", "sewer_beetle.tres"):
        assert text in html
    assert window.workspaces.currentWidget() is window.overview
    assert window.overview.values["clips"].text() == "5개" and window.overview.values["states"].text() == "6개"


# ------------------------------------------------------------------------------------------------- loot
def test_input_loot_rows_are_added_edited_reordered_and_removed(window, drafts):
    session = create(window, drafts)
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "", "drafts_folder": str(drafts)})
    loot = window.loot_editor
    assert not loot.add_button.isEnabled() and "전리품이 없습니다" in loot.notice.text()
    window.inspector.tabs.setCurrentIndex(4)
    click(loot.managed)
    assert session.document.data["loot"]["entries"] == [] and loot.add_button.isEnabled()
    QTest.mouseClick(loot.add_button, Qt.MouseButton.LeftButton)
    QTest.mouseClick(loot.add_button, Qt.MouseButton.LeftButton)
    history = len(session.history)
    assert loot.table.rowCount() == 2 and history == 4                    # one undo step per button press
    items = [loot.table.cellWidget(0, 0).itemText(index) for index in range(loot.table.cellWidget(0, 0).count())]
    assert "moss_fiber" in items and "rusty_scrap" in items                # read from the project's items
    combo = loot.table.cellWidget(1, 0)
    combo.setCurrentText("rusty_scrap")
    combo.activated.emit(combo.currentIndex())
    weight = loot.table.cellWidget(1, 1)
    QTest.keyClick(weight, Qt.Key.Key_A, Qt.KeyboardModifier.ControlModifier)
    QTest.keyClicks(weight, "3")
    QTest.keyClick(weight, Qt.Key.Key_Return)
    entries = session.document.data["loot"]["entries"]
    assert entries[1]["item_id"] == "rusty_scrap" and entries[1]["weight"] == 3
    loot.table.setCurrentCell(1, 0)
    QTest.mouseClick(loot.up_button, Qt.MouseButton.LeftButton)
    assert [row["item_id"] for row in session.document.data["loot"]["entries"]][0] == "rusty_scrap"
    loot.table.setCurrentCell(1, 0)
    QTest.mouseClick(loot.remove_button, Qt.MouseButton.LeftButton)
    assert len(session.document.data["loot"]["entries"]) == 1
    window.undo()
    assert len(session.document.data["loot"]["entries"]) == 2 and loot.table.rowCount() == 2


def test_loot_reference_errors_and_shared_tables_are_shown(window, drafts):
    session = create(window, drafts)
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "", "drafts_folder": str(drafts)})
    window.apply_edits([set_value(("loot", "entries"), [{"item_id": "gold_bar", "weight": 1}]),
                        set_value(("loot", "loot_table_id"), "cave_spider_loot")], "loot")
    assert "프로젝트에 없는" in window.loot_editor.table.cellWidget(0, 0).toolTip()
    finding, = window.validate_now().select(FAIL, "references", "unknown_item")
    assert window.navigate_to(finding)
    assert window.inspector.tabs.tabText(window.inspector.tabs.currentIndex()) == "전리품"
    window.apply_edits([set_value(("loot", "entries"), None), set_value(("loot", "loot_table_id"), "frog_loot")],
                       "share")
    assert "공유" in window.loot_editor.notice.text() and "수정하지 않습니다" in window.loot_editor.notice.text()
    assert not window.validate_now().select(FAIL, "references")
    assert session.document.data["loot"]["entries"] is None


# ------------------------------------------------------------------------------------------ validation
def test_eleven_domains_are_shown_and_unverified_is_not_passed(window, drafts):
    create(window, drafts)
    panel = window.validation_panel
    assert list(panel.chips) == list(DOMAINS) and len(panel.chips) == 11
    states = {domain: chip.property("status") for domain, chip in panel.chips.items()}
    assert states["runtime"] == states["network"] == states["publish"] == "NOT_EVALUATED"
    assert states["schema"] == "PASS" and states["references"] == "NOT_EVALUATED"     # no project connected
    assert strings.STATUS["NOT_EVALUATED"] in panel.chips["runtime"].text()
    assert strings.STATUS_COLORS["NOT_EVALUATED"] != strings.STATUS_COLORS["PASS"]
    assert "미검사는 통과가 아닙니다" in panel.banner.text()
    codes = {finding.code for finding in panel.findings_shown()}
    assert {"godot_runtime_not_run", "monster_id_uniqueness_unchecked", "no_animation"} <= codes
    assert panel.tree.headerItem().text(2) == "Finding Code"


def test_a_result_goes_stale_on_edit_and_is_refreshed_after_a_pause(window, drafts):
    create(window, drafts)
    assert window._validation_state() == "current"
    window.apply_edits([set_value(("stats", "max_health"), -5)], "break")
    assert window._validation_state() == "stale" and "오래되었습니다" in window.validation_panel.banner.text()
    assert window._validation_timer.isActive()
    for value in (30, 31, 32):                                   # a burst of edits is one pending run
        window.apply_edits([set_value(("stats", "move_speed"), value)], "burst")
    assert window._validation_timer.isActive() and window._validation_state() == "stale"
    QTest.qWait(window._validation_timer.interval() + 250)
    assert window._validation_state() == "current" and not window._validation_timer.isActive()
    assert "out_of_range" in window.validation.report.codes()
    assert window.validation_panel.chips["schema"].property("status") == "FAIL"
    assert "실패" in window.overview.values["validation"].text()


def test_a_project_change_invalidates_the_result(window, drafts):
    create(window, drafts)
    report = window.validation.report
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "", "drafts_folder": str(drafts)})
    assert window._validation_state() == "stale"
    QTest.qWait(window._validation_timer.interval() + 250)
    assert window.validation.report is not report and window._validation_state() == "current"
    assert window.validation_panel.chips["references"].property("status") == "PASS"


def test_input_activating_a_finding_moves_to_its_field(window, drafts):
    create(window, drafts)
    window.apply_edits([set_value(("stats", "attack_range"), -5), set_value(("metadata", "display_name"), "")],
                       "break two things")
    window.validate_now()
    panel = window.validation_panel
    item = next(panel.tree.topLevelItem(index) for index in range(panel.tree.topLevelItemCount())
                if panel.tree.topLevelItem(index).text(3) == "stats.attack_range")
    window.docks["inspector"].hide()
    panel.tree.setCurrentItem(item)
    QTest.keyClick(panel.tree, Qt.Key.Key_Return)
    assert window.docks["inspector"].isVisible()
    assert window.inspector.tabs.tabText(window.inspector.tabs.currentIndex()) == "능력치"
    editor = window.inspector.editor(("stats", "attack_range"))
    assert editor.spin.hasFocus() or QApplication.platformName() == "offscreen"


def test_findings_outside_the_editable_fields_go_to_the_summary_and_never_crash(window, frog):
    from application.session import DocumentSession
    from rtcmonster import Finding
    window.set_session(DocumentSession(frog))
    window.validate_now()
    blocked = next(item for item in window.validation_panel.findings_shown()
                   if item.code == "export_blocked_unsupported")
    assert window.navigate_to(blocked)
    assert window.inspector.tabs.tabText(window.inspector.tabs.currentIndex()) == "요약"
    planned = next(item for item in window.validation_panel.findings_shown() if item.code == "planned_event")
    assert window.navigate_to(planned)                                   # attack patterns: summary for now
    for odd in (Finding("FAIL", "ai", "unknown_module", "behavior.states[99].module"),
                Finding("FAIL", "schema", "out_of_range", "no_such_section.field"),
                Finding("FAIL", "schema", "out_of_range", "stats[[["),
                Finding("NOT_EVALUATED", "runtime", "godot_runtime_not_run", ""), None):
        window.navigate_to(odd)                                          # must not raise
    assert window.isVisible()


# ------------------------------------------------------------------------------------- project, catalog
def test_project_settings_are_applied_or_refused_as_a_whole(window, drafts, tmp_path):
    assert not window.apply_project_settings({"project_root": str(tmp_path), "godot_path": "",
                                              "drafts_folder": str(drafts)})
    assert "not_a_returntocage_project" in window.prompts.last_error()[1] and not window.project.connected
    assert window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "",
                                          "drafts_folder": str(drafts)})
    assert window.project.connected and str(PROJECT) in window._project_label.text()
    assert "Registry: 미확인" in window._project_label.text()
    game = [entry for entry in window.catalog_panel.entries_shown() if entry.source == "game"]
    assert {entry.monster_id for entry in game} == {"frog", "sewer_beetle"}
    assert {entry.registration for entry in game} == {"discovered"}      # found on disk, not "registered"
    assert "등록 여부는 Godot Registry 검증" in window.catalog_panel.state.text()
    assert not window.actions_by_name["import"].isEnabled()              # no Godot executable configured
    window.prompts.expect("project_settings", None)
    assert not window.edit_project_settings() and window.project.connected
    reopened = MainWindow(Settings(window.settings.path), ScriptedPrompts())
    assert reopened.project.root == PROJECT.resolve() and reopened.project.drafts_folder == drafts
    reopened.close()


def test_remembered_paths_that_stopped_working_do_not_block_startup(app, tmp_path):
    settings = Settings(tmp_path / "settings.json")
    settings.set("project_root", str(tmp_path / "moved_away"))
    settings.set("window_geometry", "not base64 at all !!")
    settings.set("catalog_filter", "no_such_filter")
    settings.save()
    view = MainWindow(Settings(tmp_path / "settings.json"), ScriptedPrompts())
    assert not view.project.connected and "사용할 수 없습니다" in view._last_message
    view.close()
    (tmp_path / "broken.json").write_bytes(b"{ damaged")
    view = MainWindow(Settings(tmp_path / "broken.json"), ScriptedPrompts())
    assert "기본값으로 복구" in view._last_message
    view.close()


def test_input_the_catalog_groups_filters_searches_and_keeps_the_selection(window, drafts, beetle):
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "", "drafts_folder": str(drafts)})
    write_document(drafts / "a.rtcmonster", new_document("cave_spider", "Cave Spider").apply(
        set_value(("metadata", "tags"), ["web"]), set_value(("metadata", "rank"), "elite")))
    write_document(drafts / "b.rtcmonster", new_document("bog_wasp", "Bog Wasp").replace(
        ("metadata", "category"), "insect"))
    write_document(drafts / "c.rtcmonster", new_document("bog_wasp", "Second wasp"))      # new-content ID clash
    write_document(drafts / "d.rtcmonster", beetle)                                       # edit of a game monster
    (drafts / "e.rtcmonster").write_bytes(b"{")
    window.refresh_catalog()
    panel = window.catalog_panel
    groups = [panel.tree.topLevelItem(index).text(0) for index in range(panel.tree.topLevelItemCount())]
    assert groups == ["게임 콘텐츠 (2)", "작업 중인 초안 (4)", "문제가 발견된 콘텐츠 (3)"]
    problems = panel.tree.topLevelItem(2)
    assert sorted(problems.child(index).text(0).split("  ")[0] for index in range(3)) == sorted([
        strings.PROBLEMS["draft_duplicate_id"], strings.PROBLEMS["draft_duplicate_id"],
        strings.PROBLEMS["draft_unreadable"]])
    assert panel.select("draft", "cave_spider")
    QTest.keyClicks(panel.search, "wasp")
    assert {entry.monster_id for entry in panel.entries_shown()} == {"bog_wasp"}
    panel.search.clear()
    for text, expected in (("web", {"cave_spider"}), ("elite", {"cave_spider"}), ("insect", {"bog_wasp"}),
                           ("Sewer", {"sewer_beetle"}), ("zzz", set())):
        panel.search.setText(text)
        assert {entry.monster_id for entry in panel.entries_shown()} == expected, text
    panel.search.clear()
    assert panel.selected_entry().monster_id == "cave_spider"            # survived every rebuild
    for key, expected in (("game", {"frog", "sewer_beetle"}), ("draft", {"cave_spider", "bog_wasp", "sewer_beetle"}),
                          ("problem", {"bog_wasp"}), ("all", {"frog", "sewer_beetle", "cave_spider", "bog_wasp"})):
        panel.filter.setCurrentIndex(panel.filter.findData(key))
        assert {entry.monster_id for entry in panel.entries_shown()} == expected, key
    bound = [entry for entry in panel.entries_shown() if entry.source == "draft" and entry.bound_to]
    assert len(bound) == 1 and bound[0].monster_id == "sewer_beetle"
    window.refresh_catalog()                                             # F5 keeps the open document alone
    assert window.session is None and panel.selected_entry().monster_id == "cave_spider"


def test_refreshing_the_catalog_never_replaces_the_open_document(window, drafts):
    session = create(window, drafts)
    window.apply_edits([set_value(("stats", "max_health"), 33)], "unsaved")
    write_document(drafts / "other.rtcmonster", new_document("other_one", "Other"))
    window.refresh_catalog()
    assert window.session is session and session.dirty and session.document.data["stats"]["max_health"] == 33
    assert {entry.monster_id for entry in window.catalog_panel.entries_shown()} == {"cave_spider", "other_one"}


def test_input_activating_a_draft_opens_it(window, drafts):
    write_document(drafts / "moss.rtcmonster", new_document("moss_slug", "Moss Slug"))
    window.refresh_catalog()
    assert window.catalog_panel.select("draft", "moss_slug")
    QTest.keyClick(window.catalog_panel.tree, Qt.Key.Key_Return)
    assert window.session is not None and window.session.document.monster_id == "moss_slug"
    assert not window.session.dirty


def test_docks_can_be_hidden_and_the_layout_restored(window):
    for dock in window.docks.values():
        dock.toggleViewAction().trigger()
        assert not dock.isVisible()
    window.reset_layout()
    assert all(dock.isVisible() for dock in window.docks.values())


def test_the_layout_and_filters_come_back_in_the_next_session(app, tmp_path, drafts):
    path = tmp_path / "settings.json"
    first = MainWindow(Settings(path), ScriptedPrompts())
    first.show()
    first.resize(940, 610)                    # small enough for a 1024x768 CI desktop
    app.processEvents()
    size = (first.width(), first.height())      # what the window system actually gave
    first.docks["validation"].hide()
    first.catalog_panel.search.setText("frog")
    first.catalog_panel.filter.setCurrentIndex(first.catalog_panel.filter.findData("draft"))
    first.close()
    second = MainWindow(Settings(path), ScriptedPrompts())
    second.show()
    app.processEvents()
    assert (second.width(), second.height()) == size or app.platformName() == "offscreen"
    assert not second.docks["validation"].isVisible()
    assert second.catalog_panel.search.text() == "frog" and second.catalog_panel.filter.currentData() == "draft"
    second.close()


# ---------------------------------------------------------------------------------------------- images
def test_thumbnails_separate_structure_decode_and_godot(window, tmp_path, beetle):
    from application.session import DocumentSession
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": "", "drafts_folder": ""})
    window.set_session(DocumentSession(beetle))
    assert not window.overview.thumbnail.pixmap().isNull()
    text = window.overview.values["image"].text()
    assert "sewer_beetle/idle.png" in text and strings.IMAGE_STATE["ok"] in text
    assert "Godot import: " + strings.IMAGE_STATE["unchecked"] in text          # never claimed
    pixmap, state = panels.load_thumbnail(PROJECT, "assets/characters/enemies/frog/idle.png", [0, 0, 64, 64])
    assert state == "ok" and (pixmap.width(), pixmap.height()) == (64, 64)
    again, _ = panels.load_thumbnail(PROJECT, "assets/characters/enemies/frog/idle.png", [0, 0, 64, 64])
    assert again is pixmap                                                       # cached by file content
    assert panels.load_thumbnail(PROJECT, "", None) == (None, "none")
    assert panels.load_thumbnail(None, "a.png", None) == (None, "unchecked")
    assert panels.load_thumbnail(PROJECT, "assets/no_such.png", None) == (None, "missing")
    project = tmp_path / "p"
    (project / "art").mkdir(parents=True)
    (project / "art/broken.png").write_bytes((PROJECT / "assets/characters/enemies/frog/idle.png").read_bytes()[:200])
    assert panels.load_thumbnail(project, "art/broken.png", None) == (None, "structure_failed")
    window.set_session(None)
    assert window.overview.empty.isVisible()


def test_an_image_qt_refuses_to_decode_does_not_bring_the_editor_down(app, tmp_path, monkeypatch):
    import struct
    import zlib

    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    width = height = 2048
    rows = (b"\x00" + bytes(4 * width)) * height
    project = tmp_path / "p"
    (project / "art").mkdir(parents=True)
    (project / "art/big.png").write_bytes(
        b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 1)) + chunk(b"IEND", b""))
    monkeypatch.setattr(panels, "DECODE_LIMIT_MB", 1)            # the structure is fine; decoding is refused
    panels._thumbnails.clear()
    assert panels.load_thumbnail(project, "art/big.png", None) == (None, "decode_failed")
    panels._thumbnails.clear()


# ------------------------------------------------------------------------------- Godot jobs (stand-in)
def probe_data(monster_id):
    probe = json.loads(FIXTURE.read_text(encoding="utf-8"))
    return {"monster_id": monster_id, "monster": probe["enemies"][monster_id], "items": probe["items"]}


@pytest.fixture
def game(fake, tmp_path):
    """The real project's files behind the stand-in executable, so imports can read real images and hashes."""
    godot, project, set_mode = fake
    return godot, set_mode


def connect(window, godot, drafts):
    assert window.apply_project_settings({"project_root": str(PROJECT), "godot_path": str(godot),
                                          "drafts_folder": str(drafts)}), window.prompts.last_error()


@pytest.mark.skipif(os.environ.get("RTC_SKIP_PROCESS_TESTS") == "1", reason="process tests disabled")
def test_an_import_becomes_a_new_unsaved_draft_and_the_game_files_are_untouched(window, game, drafts, monkeypatch):
    godot, set_mode = game
    connect(window, godot, drafts)
    from bridge import importer
    before = importer.project_fingerprint(PROJECT, load("frog"))
    set_mode("ok", data=json.dumps(probe_data("frog")))
    window.catalog_panel.select("game", "frog")
    assert window.actions_by_name["import"].isEnabled()
    window.import_selected()
    assert window.jobs.active and not window.actions_by_name["import"].isEnabled()      # busy, not frozen
    assert window.wait_for_jobs(60000), window.prompts.last_error()
    session = window.session
    assert session is not None and session.document.monster_id == "frog" and session.path is None
    assert session.dirty and session.binding["runtime"] == "legacy"
    assert strings.IMPORT_STATUS["partial"] in window._last_message and "2건" in window._last_message
    assert not session.is_editable(("behavior",)) and session.is_editable(("stats", "max_health"))
    window.apply_edits([set_value(("stats", "max_health"), 99)], "edit the draft")
    assert importer.project_fingerprint(PROJECT, load("frog")) == before
    assert window.overview.values["binding"].text() in (strings.BINDING["unchanged"], strings.BINDING["unknown"])


def test_a_failed_import_keeps_the_open_document(window, game, drafts, tmp_path):
    godot, set_mode = game
    connect(window, godot, drafts)
    logs = tmp_path / "로그"
    window.settings.set("logs_folder", str(logs))
    session = create(window, drafts)
    for mode, code in (("fail", "UNKNOWN_MONSTER"), ("bad_json", "INVALID_RESPONSE"), ("crash", "PROCESS_CRASH"),
                       ("wrong_request", "RESPONSE_MISMATCH")):
        set_mode(mode)
        window.import_monster("frog")
        assert window.wait_for_jobs(60000)
        assert code in window.prompts.last_error()[1], mode
        assert window.session is session and session.document.monster_id == "cave_spider"
    kept = sorted(path.name for path in logs.iterdir())             # failures that produced engine output keep it
    assert kept and all(name.startswith("godot-") and name.endswith(".log") for name in kept)
    set_mode("ok", version="4.8.0.stable.official.abc")
    window.import_monster("frog")
    window.wait_for_jobs(60000)
    assert "GODOT_VERSION_MISMATCH" in window.prompts.last_error()[1] and window.session is session


def test_a_result_that_arrives_after_the_project_changed_is_thrown_away(window, game, drafts, tmp_path):
    godot, set_mode = game
    connect(window, godot, drafts)
    set_mode("hang", seconds=2, data=json.dumps(probe_data("frog")))
    window.import_monster("frog")
    assert window.jobs.active
    other = tmp_path / "other_drafts"
    other.mkdir()
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": str(godot),
                                   "drafts_folder": str(other)})           # the project state moved on
    assert window.wait_for_jobs(60000)
    assert window.session is None                                          # nothing was imported
    assert "취소" in window._last_message or "버렸습니다" in window._last_message
    assert window.prompts.last_error() is None


def test_a_result_that_arrives_after_another_document_was_opened_is_thrown_away(window, game, drafts):
    godot, set_mode = game
    connect(window, godot, drafts)
    write_document(drafts / "moss.rtcmonster", new_document("moss_slug", "Moss Slug"))
    set_mode("hang", seconds=2, data=json.dumps(probe_data("frog")))
    window.import_monster("frog")
    assert window.open_document(drafts / "moss.rtcmonster")                # the user did something else meanwhile
    assert window.wait_for_jobs(60000)
    assert window.session.document.monster_id == "moss_slug"
    assert "버렸습니다" in window._last_message


def test_cancelling_and_closing_stop_only_what_the_editor_started(window, game, drafts):
    godot, set_mode = game
    connect(window, godot, drafts)
    set_mode("hang", seconds=30)
    window.verify_registry()
    assert window.jobs.active and window.actions_by_name["cancel_job"].isEnabled()
    window.actions_by_name["cancel_job"].trigger()
    assert window.wait_for_jobs(30000)
    assert "취소" in window._last_message and not window.jobs.active
    assert window.project.registry() is None and window.prompts.last_error() is None
    window.verify_registry()
    assert window.close()                                                  # closing cancels and waits
    assert not window._threads


def test_a_registry_answer_marks_monsters_verified_until_the_files_change(window, game, drafts):
    godot, set_mode = game
    connect(window, godot, drafts)
    rows = [{"monster_id": "frog", "agent_script": "res://gameplay/actors/enemies/frog/frog_agent.gd"},
            {"monster_id": "sewer_beetle", "agent_script": "res://gameplay/actors/enemies/enemy_agent.gd"}]
    set_mode("ok", data=json.dumps({"monsters": rows}))
    window.verify_registry()
    assert window.wait_for_jobs(60000), window.prompts.last_error()
    game_entries = [entry for entry in window.catalog_panel.entries_shown() if entry.source == "game"]
    assert {entry.registration for entry in game_entries} == {"registry_verified"}
    assert "Registry: 확인됨" in window._project_label.text()
    frog = window.catalog_panel.tree.topLevelItem(0).child(0)
    assert strings.IMPORT_STATUS["partial"] in frog.text(1)                # import support, per monster
    window.apply_project_settings({"project_root": str(PROJECT), "godot_path": str(godot), "drafts_folder": ""})
    assert "Registry: 미확인" in window._project_label.text()             # another project state: forgotten
