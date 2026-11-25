"""Application layer: sessions, history, project state, settings, validation freshness and job tickets.

No Qt is imported here; this layer must work without it.
"""

import json
import os
import sys

import pytest

from conftest import EXAMPLES, PROJECT, load
from application.project import ProjectError, ProjectSession, check_godot_path, check_project_root, delete_draft
from application.session import DocumentSession, History
from application.settings import RECENT_LIMIT, Settings
from application.work import CURRENT, NONE, STALE, JobBoard, ValidationController
from rtcmonster import (DocumentConflict, DocumentError, encode, find_drafts, insert_item, monster_catalog,
                        new_document, read_document, set_value, write_document)
from rtcmonster.catalog import (AVAILABLE, CONFLICT, DRAFT_DUPLICATE_ID, DRAFT_SHADOWS_PUBLISHED, UNKNOWN,
                                FOLDER_UNAVAILABLE, scan_content)


def tres(path, content_id):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(f'[resource]\nid = &"{content_id}"\n'.encode())


@pytest.fixture
def project(tmp_path):
    root = tmp_path / "project"
    for name in ("project.godot", "autoload/content_registry.gd", "data/definitions/enemy_definition.gd"):
        (root / name).parent.mkdir(parents=True, exist_ok=True)
        (root / name).write_text("", encoding="utf-8")
    tres(root / "data/content/enemies/ant.tres", "ant")
    tres(root / "data/content/items/crumb.tres", "crumb")
    tres(root / "data/content/loot/ant_loot.tres", "ant_loot")
    return root


@pytest.fixture
def drafts(tmp_path):
    folder = tmp_path / "초안"
    folder.mkdir()
    return folder


# --------------------------------------------------------------------------------- no Qt in the lower layers
def test_core_application_and_bridge_do_not_import_qt():
    import subprocess
    code = ("import sys; sys.path.insert(0, r'%s'); import rtcmonster, application.session, application.project, "
            "application.settings, application.work, bridge.client, bridge.importer; "
            "print(sorted(name for name in sys.modules if name.split('.')[0] in ('PySide6', 'shiboken6')))"
            % str(EXAMPLES.parent))
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, timeout=60)
    assert result.returncode == 0 and result.stdout.strip() == "[]", result.stdout + result.stderr


# ------------------------------------------------------------------------------------------------ history
def test_history_is_a_cursor_over_immutable_snapshots():
    a = new_document("moss_slug", "A")
    b, c = a.replace(("stats", "max_health"), 30), a.replace(("stats", "max_health"), 40)
    history = History(a)
    assert not history.can_undo and not history.can_redo and history.current is a
    history.push(b, "첫 편집")
    history.push(c, "둘째 편집")
    assert (history.undo_label, history.redo_label, len(history)) == ("둘째 편집", "", 3)
    assert history.undo() and history.current is b and history.redo_label == "둘째 편집"
    assert history.undo() and history.current is a and not history.undo()
    assert history.redo() and history.current is b
    d = b.replace(("stats", "move_speed"), 70)
    history.push(d, "분기")                      # a new edit after undo drops the redo branch
    assert len(history) == 3 and not history.can_redo and history.current is d
    assert history.undo() and history.current is b and history.current.data["stats"]["max_health"] == 30


def test_history_is_bounded():
    history = History(new_document("moss_slug", "A"), limit=10)
    for value in range(1, 40):
        history.push(history.current.replace(("stats", "max_health"), value))
    assert len(history) == 10 and history.current.data["stats"]["max_health"] == 39
    steps = 0
    while history.undo():
        steps += 1
    assert steps == 9 and history.current.data["stats"]["max_health"] == 30


# ------------------------------------------------------------------------------------------------ session
def test_a_new_session_is_unsaved_and_gets_its_own_id():
    first, second = DocumentSession.create("moss_slug", "Moss Slug"), DocumentSession.create("ant_two", "Ant")
    assert first.session_id != second.session_id and first.path is None and first.dirty
    with_fields = DocumentSession.create("bee", "Bee", **{"metadata.rank": "elite", "metadata.category": "insect"})
    assert with_fields.document.data["metadata"]["rank"] == "elite"
    with pytest.raises(DocumentError):
        DocumentSession.create("Bad ID", "x")
    with pytest.raises(DocumentError):
        first.save()                                  # no path yet


def test_dirty_follows_content_not_bytes(tmp_path):
    document = new_document("moss_slug", "Moss Slug")
    canonical = tmp_path / "canonical.rtcmonster"
    write_document(canonical, document)
    # The same content, written differently: reordered, re-indented, defaults left out.
    data = json.loads(encode(document))
    loose = {key: data[key] for key in reversed(list(data))}
    del loose["movement"], loose["sensors"]
    messy = tmp_path / "messy.rtcmonster"
    messy.write_text(json.dumps(loose, indent=5), encoding="utf-8")
    spaced = tmp_path / "spaced.rtcmonster"
    spaced.write_bytes(encode(document).replace(b"\n", b"\n\n"))
    for path in (canonical, messy, spaced):
        session = DocumentSession.open(path)
        assert not session.dirty, path.name                       # opening never counts as an edit
        assert session.saved_fingerprint == document.fingerprint
    session = DocumentSession.open(messy)
    assert session.disk_revision != session.document.fingerprint   # the bytes differ, the content does not
    before = messy.read_bytes()
    assert not session.apply(set_value(("stats", "max_health"), 20))   # same value: no edit, no history
    assert not session.dirty and not session.can_undo and messy.read_bytes() == before
    session.save()                                                 # an explicit save normalizes the file
    assert messy.read_bytes() == encode(document) and not session.dirty
    assert session.disk_revision == session.document.fingerprint


def test_edit_undo_redo_and_the_clean_state(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    write_document(path, new_document("moss_slug", "Moss Slug"))
    session = DocumentSession.open(path)
    events = []
    session.subscribe(lambda _session, reason: events.append(reason))
    generation = session.generation
    assert session.apply(set_value(("stats", "max_health"), 30), label="체력")
    assert session.apply(set_value(("stats", "move_speed"), 70), set_value(("metadata", "tags"), ["cave"]),
                         label="일괄")
    assert session.dirty and session.can_undo and session.generation == generation + 2
    assert session.history.undo_label == "일괄"
    assert session.undo() and session.document.data["stats"]["move_speed"] == 55
    assert session.document.data["metadata"]["tags"] == [] and session.dirty      # one step undid both fields
    assert session.undo() and not session.dirty and not session.can_undo          # back at the saved content
    assert not session.undo()
    assert session.redo() and session.redo() and not session.redo() and session.dirty
    session.save()
    assert not session.dirty and session.can_undo                                 # saving keeps the history
    assert session.undo() and session.dirty                                       # ... and undo leaves "clean"
    assert session.redo() and not session.dirty
    assert events == ["edit", "edit", "undo", "undo", "redo", "redo", "saved", "undo", "redo"]


def test_a_rejected_edit_changes_nothing(tmp_path):
    session = DocumentSession.create("moss_slug", "Moss Slug")
    before, generation = session.document.fingerprint, session.generation
    events = []
    session.subscribe(lambda _session, reason: events.append(reason))
    for edit in (set_value(("stats", "max_health"), "many"), set_value(("stats", "mana"), 1),
                 set_value(("behavior", "initial_state"), "ghost"),      # behaviour is not editable in STEP 2
                 insert_item(("attack_patterns",), {"id": "x"})):
        with pytest.raises(DocumentError):
            session.apply(edit)
    assert session.document.fingerprint == before and session.generation == generation
    assert not session.can_undo and events == []
    # A semantically wrong but well-formed value is a draft the user may keep working on.
    assert session.apply(set_value(("stats", "max_health"), -5)) and session.can_undo


def test_editability_follows_the_source_binding(beetle):
    session = DocumentSession(beetle)
    assert session.editability("stats") == "editable" and session.editability("loot") == "editable"
    assert session.editability("movement") == "read_only" and session.editability("behavior") == "read_only"
    assert session.editability("collision") == "read_only" and not session.is_draft_of_new_content
    with pytest.raises(DocumentError, match="read_only"):
        session.apply(set_value(("movement", "gravity"), 900))
    assert session.apply(set_value(("stats", "max_health"), 30))
    draft = DocumentSession.create("moss_slug", "Moss Slug")
    assert draft.editability("movement") == "editable" and draft.editability("behavior") == "read_only"
    assert draft.is_draft_of_new_content


def test_a_failed_save_does_not_pretend_to_have_saved(tmp_path, monkeypatch):
    from rtcmonster import storage
    path = tmp_path / "slug.rtcmonster"
    write_document(path, new_document("moss_slug", "Moss Slug"))
    session = DocumentSession.open(path)
    session.apply(set_value(("stats", "max_health"), 30))
    state = (session.path, session.disk_revision, session.saved_fingerprint, session.generation)
    monkeypatch.setattr(storage.os, "replace", lambda *_a: (_ for _ in ()).throw(OSError("disk full")))
    with pytest.raises(OSError):
        session.save()
    assert (session.path, session.disk_revision, session.saved_fingerprint, session.generation) == state
    assert session.dirty and read_document(path)[0].data["stats"]["max_health"] == 20
    monkeypatch.undo()
    session.save()
    assert not session.dirty and read_document(path)[0].data["stats"]["max_health"] == 30


def test_an_external_change_is_a_conflict_and_can_be_reloaded(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    write_document(path, new_document("moss_slug", "Mine"))
    session = DocumentSession.open(path)
    session.apply(set_value(("stats", "max_health"), 30))
    assert not session.disk_changed()
    path.write_bytes(encode(new_document("moss_slug", "Theirs")))
    assert session.disk_changed()
    with pytest.raises(DocumentConflict):
        session.save()
    assert session.dirty and read_document(path)[0].data["metadata"]["display_name"] == "Theirs"
    session.reload()
    assert not session.dirty and not session.can_undo and not session.disk_changed()
    assert session.document.data["metadata"]["display_name"] == "Theirs"
    path.unlink()
    assert session.disk_changed()


def test_save_as_needs_the_revision_the_user_confirmed(tmp_path):
    session = DocumentSession.create("moss_slug", "Mine")
    first = tmp_path / "a.rtcmonster"
    session.save_as(first)
    assert session.path == first and not session.dirty
    other = tmp_path / "b.rtcmonster"
    write_document(other, new_document("other_one", "Other"))
    with pytest.raises(DocumentConflict):
        session.save_as(other)                           # exists and nobody confirmed anything
    assert session.path == first
    from rtcmonster import document_revision
    approved = document_revision(other)
    other.write_bytes(encode(new_document("other_one", "Changed after the confirmation")))
    with pytest.raises(DocumentConflict):
        session.save_as(other, approved)
    assert session.path == first and read_document(other)[0].monster_id == "other_one"
    session.save_as(other, document_revision(other))
    assert session.path == other and read_document(other)[0].monster_id == "moss_slug"
    assert read_document(first)[0].monster_id == "moss_slug"      # the earlier file is left as it was


def test_a_clone_session_is_independent_and_unbound(beetle):
    session = DocumentSession.clone_of(beetle, "cave_beetle", "Cave Beetle", "cave_beetle_loot_2")
    data = session.document.data
    assert data["monster_id"] == "cave_beetle" and data["source_binding"] is None and session.path is None
    assert data["loot"]["loot_table_id"] == "cave_beetle_loot_2" and session.dirty
    assert session.editability("movement") == "editable"         # no binding, so nothing is locked by it
    session.apply(set_value(("stats", "max_health"), 99))
    assert beetle.data["stats"]["max_health"] == 24


# ------------------------------------------------------------------------------------- catalog ID safety
def test_an_unreadable_catalog_never_says_an_id_is_free(project, tmp_path):
    assert monster_catalog(project).id_status("bee").status == AVAILABLE
    assert monster_catalog(project).id_status("ant").status == CONFLICT
    for unavailable in (monster_catalog(None), monster_catalog(tmp_path / "nowhere")):
        check = unavailable.id_status("bee")
        assert check.status == UNKNOWN and not unavailable.is_id_free("bee")
        with pytest.raises(TypeError):
            bool(check)                                   # UNKNOWN must not be usable as a yes/no by accident


def test_a_found_conflict_is_reported_even_without_a_project(drafts):
    write_document(drafts / "bee.rtcmonster", new_document("bee", "Bee"))
    catalog = monster_catalog(None, find_drafts(drafts))
    assert catalog.id_status("bee").status == CONFLICT
    assert catalog.id_status("bee", ignore_path=drafts / "bee.rtcmonster").status == UNKNOWN
    assert catalog.id_status("wasp").status == UNKNOWN


def test_new_drafts_with_one_id_conflict_but_working_copies_of_a_game_monster_do_not(project, drafts, beetle):
    write_document(drafts / "bee_a.rtcmonster", new_document("bee", "Bee A"))
    write_document(drafts / "bee_b.rtcmonster", new_document("bee", "Bee B"))
    write_document(drafts / "ant_new.rtcmonster", new_document("ant", "A new monster called ant"))
    # Two edited copies of the same imported game monster: branches of one piece of content.
    write_document(drafts / "beetle_1.rtcmonster", beetle)
    write_document(drafts / "beetle_2.rtcmonster", beetle.replace(("stats", "max_health"), 30))
    catalog = monster_catalog(project, find_drafts(drafts))
    codes = {(problem.code, problem.id) for problem in catalog.problems}
    assert codes == {(DRAFT_DUPLICATE_ID, "bee"), (DRAFT_SHADOWS_PUBLISHED, "ant")}
    assert len([problem for problem in catalog.problems if problem.code == DRAFT_DUPLICATE_ID]) == 2
    copies = [entry for entry in catalog.entries if entry.monster_id == "sewer_beetle"]
    assert len(copies) == 2 and {entry.bound_to for entry in copies} == {"data/content/enemies/sewer_beetle.tres"}
    assert catalog.id_status("bee").status == CONFLICT and catalog.id_status("wasp").status == AVAILABLE
    # The draft asking about its own ID is not its own conflict, but the other new draft still is.
    assert catalog.id_status("bee", ignore_path=drafts / "bee_a.rtcmonster").conflicts == (
        str(drafts / "bee_b.rtcmonster"),)


def test_draft_entries_carry_what_the_catalog_filters_on(drafts):
    document = new_document("bee", "Bee").apply(set_value(("metadata", "tags"), ["flying", "swarm"]),
                                               set_value(("metadata", "category"), "insect"),
                                               set_value(("metadata", "rank"), "elite"))
    write_document(drafts / "bee.rtcmonster", document)
    entry, = monster_catalog(None, find_drafts(drafts)).entries
    assert (entry.category, entry.rank, entry.tags, entry.bound_to) == ("insect", "elite", ("flying", "swarm"), "")


def test_the_unsaved_open_document_takes_part_in_id_checks(project, drafts):
    session_project = ProjectSession()
    session_project.configure(project, None, drafts)
    open_document = new_document("wasp", "Unsaved wasp")
    assert session_project.id_status("wasp").status == AVAILABLE
    assert session_project.id_status("wasp", open_document=open_document).status == CONFLICT
    assert session_project.id_status("bee", open_document=open_document).status == AVAILABLE
    write_document(drafts / "wasp.rtcmonster", open_document)
    # The saved document asking about itself is not a conflict.
    assert session_project.id_status("wasp", ignore_path=drafts / "wasp.rtcmonster").status == AVAILABLE
    assert session_project.id_status("wasp").status == CONFLICT


def test_content_folders_reached_through_a_link_are_not_scanned(project, tmp_path):
    outside = tmp_path / "outside"
    tres(outside / "smuggled.tres", "smuggled")
    import shutil
    shutil.rmtree(project / "data/content/enemies")
    try:
        os.symlink(outside, project / "data/content/enemies", target_is_directory=True)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symbolic links are not available: {error}")
    scan = scan_content(project, "enemies")
    assert not scan.available and scan.entries == {}
    assert [problem.code for problem in scan.problems] == [FOLDER_UNAVAILABLE]
    assert monster_catalog(project).id_status("smuggled").status == UNKNOWN


def test_stale_inputs_do_not_follow_a_path_out_of_the_project(tmp_path, beetle):
    import shutil
    from rtcmonster import validate
    project = tmp_path / "copy"
    for folder in ("data/content", "assets/characters/enemies", "gameplay/actors/enemies", "gameplay/components",
                   "presentation", "core/models/network", "data/definitions"):
        shutil.copytree(PROJECT / folder, project / folder)
    report = validate(beetle, project)
    assert report.stale_inputs() == []
    image = project / "assets/characters/enemies/sewer_beetle/idle.png"
    kept = image.read_bytes()
    image.unlink()
    assert "assets/characters/enemies/sewer_beetle/idle.png" in report.stale_inputs()
    outside = tmp_path / "idle_outside.png"
    outside.write_bytes(kept)
    try:
        os.symlink(outside, image)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symbolic links are not available: {error}")
    # Identical bytes, but reached through a link: not the file that was validated.
    assert "assets/characters/enemies/sewer_beetle/idle.png" in report.stale_inputs()


# ---------------------------------------------------------------------------------------- project session
def test_project_configuration_is_all_or_nothing(project, drafts, tmp_path):
    session = ProjectSession()
    assert not session.connected and session.generation == 0 and session.content_ids("items") is None
    session.configure(project, None, drafts)
    assert session.connected and session.generation == 1 and session.content_ids("items") == ["crumb"]
    session.configure(project, None, drafts)
    assert session.generation == 1                                # nothing changed, nothing invalidated
    for values, code in (((tmp_path / "nowhere", None, drafts), "project_missing"),
                         ((tmp_path, None, drafts), "not_a_returntocage_project"),
                         ((project, tmp_path / "godot.exe", drafts), "godot_missing"),
                         ((project, None, tmp_path / "no_drafts"), "drafts_folder_missing")):
        with pytest.raises(ProjectError) as caught:
            session.configure(*values)
        assert caught.value.code == code
        assert (session.root, session.drafts_folder, session.generation) == (project.resolve(), drafts, 1)
    session.configure(None, None, drafts)
    assert not session.connected and session.generation == 2 and session.catalog().available is False
    assert check_project_root(PROJECT) == PROJECT.resolve()


@pytest.mark.skipif(os.name != "nt", reason="the console launcher exists only on Windows")
def test_the_windows_console_launcher_is_replaced_by_the_engine_binary(tmp_path):
    engine, launcher = tmp_path / "Godot_v4.exe", tmp_path / "Godot_v4_console.exe"
    engine.write_bytes(b"x")
    launcher.write_bytes(b"x")
    assert check_godot_path(launcher) == engine.resolve() and check_godot_path(engine) == engine.resolve()


def test_a_registry_answer_belongs_to_one_project_state(project, drafts, tmp_path):
    session = ProjectSession()
    session.configure(project, None, drafts)
    generation = session.generation
    assert session.registry() is None and session.catalog().registry_checked is False
    assert session.accept_registry(["ant"], generation, "4.7.2")
    assert session.registry().ids == {"ant"} and session.catalog().registry_checked
    tres(project / "data/content/enemies/bee.tres", "bee")        # the files changed after the answer
    assert session.registry() is None and not session.catalog().registry_checked
    assert session.accept_registry(["ant", "bee"], generation)
    other = tmp_path / "other"
    for name in ("project.godot", "autoload/content_registry.gd", "data/definitions/enemy_definition.gd"):
        (other / name).parent.mkdir(parents=True, exist_ok=True)
        (other / name).write_text("", encoding="utf-8")
    tres(other / "data/content/enemies/ant.tres", "ant")
    session.configure(other, None, drafts)
    assert session.registry() is None                              # another project: the old answer is gone
    assert not session.accept_registry(["ant"], generation)        # a late answer for the old project is refused
    assert session.registry() is None


def test_loot_table_ids_are_checked_like_monster_ids(project, drafts):
    session = ProjectSession()
    assert session.loot_table_status("ant_loot") == "unknown"
    session.configure(project, None, drafts)
    assert session.loot_table_status("ant_loot") == CONFLICT and session.loot_table_status("bee_loot") == AVAILABLE


def test_only_drafts_of_the_listed_revision_can_be_deleted(project, drafts):
    path = drafts / "bee.rtcmonster"
    revision = write_document(path, new_document("bee", "Bee"))
    for target in (project / "data/content/enemies/ant.tres", project / "project.godot", drafts):
        with pytest.raises((DocumentError, OSError)):
            delete_draft(target, revision)
        assert target.exists()
    with pytest.raises(DocumentError, match="changed on disk"):
        delete_draft(path, "0" * 64)
    path.write_bytes(encode(new_document("bee", "Edited elsewhere")))
    with pytest.raises(DocumentError, match="changed on disk"):
        delete_draft(path, revision)                               # somebody edited it since it was listed
    assert path.exists()
    from rtcmonster import document_revision
    delete_draft(path, document_revision(path))
    assert not path.exists() and not (drafts / ".bee.rtcmonster.lock").exists()
    assert (project / "data/content/enemies/ant.tres").is_file()


# ----------------------------------------------------------------------------------------------- settings
def test_settings_round_trip_and_recent_lists(tmp_path):
    path = tmp_path / "config" / "settings.json"
    settings = Settings(path)
    assert settings.get("project_root") == "" and not settings.recovered
    settings.set("project_root", "C:/한글 경로/project")
    for index in range(RECENT_LIMIT + 4):
        settings.remember("recent_documents", f"doc_{index}.rtcmonster")
    settings.remember("recent_documents", "doc_5.rtcmonster")       # moves to the front, no duplicate
    settings.save()
    again = Settings(path)
    assert again.get("project_root") == "C:/한글 경로/project"
    recent = again.get("recent_documents")
    assert len(recent) == RECENT_LIMIT and recent[0] == "doc_5.rtcmonster" and len(set(recent)) == RECENT_LIMIT
    again.forget("recent_documents", "doc_5.rtcmonster")
    assert "doc_5.rtcmonster" not in again.get("recent_documents")
    with pytest.raises(KeyError):
        again.set("no_such_setting", "x")
    with pytest.raises(KeyError):
        again.set("project_root", 5)


@pytest.mark.parametrize("payload", [b"{", b"[1, 2]", b"\xff\xfe", b'"text"', b""])
def test_a_damaged_settings_file_falls_back_to_defaults(tmp_path, payload):
    path = tmp_path / "settings.json"
    path.write_bytes(payload)
    settings = Settings(path)
    assert settings.recovered and settings.get("recent_documents") == [] and settings.get("project_root") == ""
    assert (tmp_path / "settings.damaged.json").read_bytes() == payload   # kept for inspection
    settings.set("godot_path", "godot.exe")
    settings.save()
    assert Settings(path).get("godot_path") == "godot.exe" and not Settings(path).recovered


def test_wrongly_typed_settings_are_ignored_value_by_value(tmp_path):
    path = tmp_path / "settings.json"
    path.write_text(json.dumps({"project_root": 5, "godot_path": "ok.exe", "recent_documents": ["a", 3],
                                "recent_projects": ["p"], "unknown": True}), encoding="utf-8")
    settings = Settings(path)
    assert not settings.recovered
    assert (settings.get("project_root"), settings.get("godot_path")) == ("", "ok.exe")
    assert settings.get("recent_documents") == [] and settings.get("recent_projects") == ["p"]


# ------------------------------------------------------------------------------- validation freshness, jobs
def test_a_report_is_current_only_for_what_it_was_made_for(project):
    session = DocumentSession.create("bee", "Bee")
    controller = ValidationController()
    assert controller.state(session) == NONE
    controller.run(session)
    assert controller.state(session) == CURRENT
    assert controller.state(session, project) == STALE              # another project
    assert controller.state(session, tick_rate=30) == STALE         # another tick rate
    session.apply(set_value(("stats", "max_health"), 30))
    assert controller.state(session) == STALE
    session.undo()
    assert controller.state(session) == CURRENT                     # the same content again
    other = DocumentSession.create("bee", "Bee")
    assert controller.state(other) == STALE                         # same content, another session
    controller.run(session, project)
    assert controller.state(session, project) == CURRENT
    tres(project / "data/content/enemies/wasp.tres", "wasp")
    assert controller.state(session, project) == CURRENT            # cheap check: files are not re-read
    assert controller.state(session, project, check_files=True) == STALE
    controller.clear()
    assert controller.state(session, project) == NONE and controller.state(None) == NONE


def test_late_results_are_discarded(project, drafts):
    board = JobBoard()
    project_session = ProjectSession()
    project_session.configure(project, None, drafts)
    session = DocumentSession.create("bee", "Bee")

    ticket = board.issue("import_monster", project_session.generation, session)
    assert board.active == [ticket]
    assert board.finish(ticket, project_session.generation, session, same_document=True) and board.active == []
    assert not board.finish(ticket, project_session.generation, session)          # a result is used once

    ticket = board.issue("inspect_monsters", project_session.generation)
    project_session.configure(project, None, None)                                # the project settings changed
    assert not board.finish(ticket, project_session.generation)

    ticket = board.issue("import_monster", project_session.generation, session)
    session.apply(set_value(("stats", "max_health"), 30))                         # edited while Godot was running
    assert not board.finish(ticket, project_session.generation, session, same_document=True)

    ticket = board.issue("import_monster", project_session.generation, session)
    assert not board.finish(ticket, project_session.generation, DocumentSession.create("bee", "Bee"),
                            same_document=True)                                   # another document was opened

    ticket = board.issue("import_monster", project_session.generation, None)      # started with nothing open
    assert board.finish(ticket, project_session.generation, None, same_document=True)
    ticket = board.issue("import_monster", project_session.generation, None)
    assert not board.finish(ticket, project_session.generation, session, same_document=True)

    ticket = board.issue("check_godot", project_session.generation)
    board.cancel(ticket)
    assert ticket.cancel.is_set() and not board.finish(ticket, project_session.generation)
    first, second = board.issue("a", 1), board.issue("b", 1)
    board.cancel_all()
    assert first.cancel.is_set() and second.cancel.is_set() and first.job_id != second.job_id
    assert load("frog").monster_id == "frog"
