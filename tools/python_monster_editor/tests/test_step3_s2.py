"""MONSTER-STEP 3-S2: the defects left after the first stabilization pass (FIX-20 .. FIX-27).

Each test names the defect it pins. They were written against the code of commit ``cbf68ce`` first and
failed there (see docs/monster_editor_step3_stabilization.md, "S2"); they pass with the fixes.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess

import pytest

from conftest import PROJECT
from application import animation, references
from application.session import DocumentSession
from bridge import client, staging
from bridge.client import BridgeError
from bridge.staging import StagingSession
from rtcmonster import DocumentError, encode, remove_item, set_value

BEETLE = "assets/characters/enemies/sewer_beetle"


# ----------------------------------------------------------------------------------------------- helpers
def rebound(document, **editability):
    """The document as an import whose binding declares the given sections (others keep their value)."""
    binding = json.loads(encode(document))["source_binding"]
    binding["editability"] = {**binding["editability"], **editability}
    return document.replace(("source_binding",), binding)


def without_declaration(document, *sections):
    binding = json.loads(encode(document))["source_binding"]
    for section in sections:
        binding["editability"].pop(section, None)
    return document.replace(("source_binding",), binding)


def gameplay_clip(document):
    for index, pattern in enumerate(document.data["attack_patterns"]):
        if pattern["clip"]:
            return pattern["clip"], index
    raise AssertionError("no pattern with a clip")


def junction(link, target):
    if os.name != "nt":
        return False
    done = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True)
    return done.returncode == 0 and link.exists()


def linked(link, target):
    """Make ``link`` a directory link to ``target`` by whatever this platform allows, or skip."""
    if junction(link, target):
        return
    try:
        os.symlink(target, link, target_is_directory=True)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"no directory links here: {error}")


def unlink_dir(link):
    os.rmdir(link) if os.name == "nt" else os.unlink(link)


# ============================================================================================== FIX-20
def test_fix20_a_rename_does_not_rewrite_references_in_a_read_only_section(frog):
    """An imported monster whose clips were unlocked but whose attack patterns are still the game's:
    renaming a clip used to rewrite ``attack_patterns[].clip`` behind the read-only declaration."""
    document = rebound(frog, animations="editable", presentation="editable", collision="editable")
    clip_id, index = gameplay_clip(document)
    session = DocumentSession(document)
    assert session.editability("attack_patterns") == "read_only"
    with pytest.raises(DocumentError, match="attack_patterns"):
        session.apply(*animation.rename_clip(document, clip_id, "renamed_clip"), label="rename")
    assert session.document is document and len(session.history) == 1
    assert session.document.data["attack_patterns"][index]["clip"] == clip_id
    # A clip nothing read-only names can still be renamed.
    free = next(clip["id"] for clip in document.data["animations"]["clips"]
                if all(usage.section in ("presentation", "collision", "animations")
                       for usage in references.incoming(document, "animation", clip["id"])))
    assert session.apply(*animation.rename_clip(document, free, "free_clip_renamed"), label="rename")


def test_fix20_a_hitbox_rename_is_held_to_the_same_rule(frog):
    document = rebound(frog, collision="editable")
    name = next(box["id"] for box in document.data["collision"]["hitboxes"]
                if animation.hitbox_usages(document, box["id"]))
    slot = next(slot for slot in animation.shape_slots(document.data) if slot.kind == "hitbox" and slot.label == name)
    session = DocumentSession(document)
    before = session.document.data["attack_patterns"]
    with pytest.raises(DocumentError, match="attack_patterns"):
        session.apply(*animation.rename_box(document, slot, "jaw"), label="rename")
    assert session.document.data["attack_patterns"] is before


def test_fix20_an_imported_section_that_is_not_declared_is_not_editable(frog):
    """A binding that says nothing about a section used to mean "editable"."""
    document = without_declaration(frog, "attack_patterns", "collision")
    clip_id, index = gameplay_clip(document)
    other = next(clip["id"] for clip in document.data["animations"]["clips"] if clip["id"] != clip_id)
    session = DocumentSession(document)
    assert session.editability("collision") == "read_only" and session.editability("attack_patterns") == "read_only"
    with pytest.raises(DocumentError, match="read_only"):
        session.apply(set_value(("attack_patterns", index, "clip"), other), label="reference")
    with pytest.raises(DocumentError, match="read_only"):
        session.apply(set_value(("collision", "body", "layer"), 3), label="collision")
    assert session.document is document


def test_fix20_a_reference_may_follow_its_target_but_not_be_cleared_or_pointed_at_nothing(frog):
    free = frog.replace(("source_binding",), None)
    clip_id, index = gameplay_clip(free)
    other = next(clip["id"] for clip in free.data["animations"]["clips"] if clip["id"] != clip_id)
    session = DocumentSession(free)
    for value in ("", "no_such_clip"):
        with pytest.raises(DocumentError, match="attack_patterns"):
            session.apply(set_value(("attack_patterns", index, "clip"), value), label="clear")
    assert session.document is free
    assert session.apply(set_value(("attack_patterns", index, "clip"), other), label="follow")


def test_fix20_a_batch_is_judged_by_what_it_changes_not_edit_by_edit(frog):
    """Several edits applied together: nothing in a protected section may differ afterwards except
    reference fields that now name an existing object. The whole batch is refused otherwise."""
    free = frog.replace(("source_binding",), None)
    clip_id, index = gameplay_clip(free)
    other = next(clip["id"] for clip in free.data["animations"]["clips"] if clip["id"] != clip_id)
    session = DocumentSession(free)
    good = animation.remove_clip(free, clip_id, replace_with=other)
    for extra in (set_value(("attack_patterns", index, "duration"), 9.0),
                  remove_item(("attack_patterns", index)),
                  set_value(("behavior", "initial_state"), "attack")):
        with pytest.raises(DocumentError):
            session.apply(*good, extra, label="batch")
        assert session.document is free and len(session.history) == 1
    # A reference left dangling by the batch itself is refused too: the clip goes, the pattern still names it.
    dangling = [edit for edit in good if edit.path[:1] != ("attack_patterns",)]
    with pytest.raises(DocumentError, match="attack_patterns"):
        session.apply(*dangling, label="dangling")
    assert session.document is free
    assert session.apply(*good, label="replace") and session.document.data["attack_patterns"][index]["clip"] == other
    assert session.undo() and session.document == free


def test_fix20_the_unchanged_legacy_import_stays_exactly_as_locked_as_before(frog, beetle):
    for document in (frog, beetle):
        session = DocumentSession(document)
        assert session.apply(set_value(("stats", "max_health"), 99), label="stat")       # still editable
        clip = document.data["animations"]["clips"][0]["id"]
        for edits in (animation.rename_clip(document, clip, "x_renamed"),
                      [set_value(("presentation", "visual_offset"), [1, 1])],
                      [set_value(("attack_patterns", 0, "clip"), clip)] if document.data["attack_patterns"] else []):
            if edits:
                with pytest.raises(DocumentError, match="read_only"):
                    session.apply(*edits, label="locked")


# ============================================================================================== FIX-23
def test_fix23_a_project_root_that_is_a_link_is_refused_before_it_is_resolved(fake, tmp_path):
    """``Path.resolve()`` turned the link into its target before ``is_link`` looked at it."""
    _godot, project, _set_mode = fake
    link = tmp_path / "linked-project"
    linked(link, project)
    work = tmp_path / "work"
    work.mkdir()
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(link, work)
    assert caught.value.code == staging.STAGING_UNSAFE_SOURCE and "link" in caught.value.detail
    assert list(work.iterdir()) == []
    with pytest.raises(BridgeError) as caught:
        staging.make_staging_copy(link, work)
    assert caught.value.code == staging.STAGING_UNSAFE_SOURCE
    unlink_dir(link)
    session = StagingSession.create(project, work)                 # the same project by its real path is fine
    session.remove()


def test_fix23_a_work_folder_that_is_a_link_into_the_project_is_refused(fake, tmp_path):
    _godot, project, _set_mode = fake
    inside = project / "scratch"
    inside.mkdir()
    link = tmp_path / "looks-outside"
    linked(link, inside)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, link)
    assert caught.value.code in (staging.STAGING_INSIDE_PROJECT, staging.STAGING_UNSAFE_SOURCE)
    assert list(inside.iterdir()) == []
    unlink_dir(link)


# ============================================================================================== FIX-24
def test_fix24_a_folder_swapped_for_a_link_after_the_survey_is_not_followed(fake, tmp_path, monkeypatch):
    """The survey found plain folders; before the files are copied one of them is replaced by a link to
    somewhere else. Only the file itself used to be checked, so the copy read through the link."""
    _godot, project, _set_mode = fake
    (project / "assets").mkdir()
    (project / "assets/a.png").write_bytes(b"inside the project")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "a.png").write_bytes(b"OUTSIDE - must never be copied")
    work = tmp_path / "work"
    work.mkdir()
    real_survey = staging.survey
    moved = tmp_path / "assets-moved-away"

    def survey_then_swap(root, *args, **kwargs):
        rows = real_survey(root, *args, **kwargs)
        (project / "assets").rename(moved)
        linked(project / "assets", outside)
        return rows
    monkeypatch.setattr(staging, "survey", survey_then_swap)
    try:
        with pytest.raises(BridgeError) as caught:
            StagingSession.create(project, work)
        assert caught.value.code == staging.STAGING_UNSAFE_SOURCE and "assets" in caught.value.detail
        assert list(work.iterdir()) == []                          # nothing copied survives
    finally:
        if (project / "assets").exists():
            unlink_dir(project / "assets")
        moved.rename(project / "assets")
    assert (outside / "a.png").read_bytes() == b"OUTSIDE - must never be copied"


def test_fix24_a_file_swapped_or_removed_after_the_survey_stops_the_copy(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    (project / "data.tres").write_text("resource", encoding="utf-8")
    (project / "other.tres").write_text("other", encoding="utf-8")
    real_survey = staging.survey
    for change, code in ((lambda: (project / "data.tres").unlink(), staging.STAGE_FAILED),
                         (lambda: ((project / "data.tres").unlink(), (project / "data.tres").mkdir()),
                          staging.STAGING_UNSAFE_SOURCE)):
        def survey_then_change(root, *args, change=change, **kwargs):
            rows = real_survey(root, *args, **kwargs)
            change()
            return rows
        monkeypatch.setattr(staging, "survey", survey_then_change)
        with pytest.raises(BridgeError) as caught:
            StagingSession.create(project, tmp_path)
        assert caught.value.code == code and "data.tres" in caught.value.detail
        assert [path for path in tmp_path.iterdir() if path.name.startswith(staging.STAGING_PREFIX)] == []
        monkeypatch.setattr(staging, "survey", real_survey)
        if (project / "data.tres").is_dir():
            (project / "data.tres").rmdir()
        (project / "data.tres").write_text("resource", encoding="utf-8")


def test_fix24_a_file_that_grew_while_it_was_copied_is_recorded_with_what_was_copied(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    (project / "data.tres").write_text("before", encoding="utf-8")
    real_survey = staging.survey

    def survey_then_edit(root, *args, **kwargs):
        rows = real_survey(root, *args, **kwargs)
        (project / "data.tres").write_text("after, and longer", encoding="utf-8")
        return rows
    monkeypatch.setattr(staging, "survey", survey_then_edit)
    session = StagingSession.create(project, tmp_path)
    assert not session.consistent and session.changed_during_copy == ("data.tres",)
    assert (session.root / "data.tres").read_text(encoding="utf-8") == "after, and longer"     # one whole version
    session.remove()


# ============================================================================================== FIX-22
def test_fix22_a_cleanup_that_failed_after_deleting_the_marker_can_still_be_retried(fake, tmp_path, monkeypatch):
    """Deleting stopped half-way (a locked file) after the marker was already gone. The retry then found
    no marker and refused its own copy for ever."""
    _godot, project, _set_mode = fake
    (project / "assets").mkdir()
    (project / "assets/a.png").write_bytes(b"x")
    session = StagingSession.create(project, tmp_path)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    real = staging._delete_tree

    def half(path, *args, **kwargs):
        (session.root / staging.MARKER).unlink(missing_ok=True)   # what an arbitrary deletion order can do
        return [(str(session.root / "assets" / "a.png"), PermissionError("locked by another program"))]
    monkeypatch.setattr(staging, "_delete_tree", half)
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_CLEANUP_FAILED and session.state == "leftover"
    assert not (session.root / staging.MARKER).exists() and session.root.is_dir()
    monkeypatch.setattr(staging, "_delete_tree", real)             # the lock is gone
    assert session.remove() is True and not session.parent.exists() and session not in staging.leftovers()


def test_fix22_the_real_deletion_removes_the_proof_of_ownership_last(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    for name in ("a", "b", "c"):
        (project / name).mkdir()
        (project / name / "file.bin").write_bytes(b"x")
    session = StagingSession.create(project, tmp_path)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    locked_file = session.root / "b" / "file.bin"
    real_unlink = os.unlink

    def unlink(path, *args, **kwargs):
        if Path(path) == locked_file:
            raise PermissionError("locked by another program")
        return real_unlink(path, *args, **kwargs)
    monkeypatch.setattr(os, "unlink", unlink)
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_CLEANUP_FAILED and "file.bin" in caught.value.detail
    assert locked_file.is_file()
    # Whatever else went, the session can still prove the folder is its own.
    session.check_deletable()
    monkeypatch.setattr(os, "unlink", real_unlink)
    assert session.remove() and not session.parent.exists()


def test_fix22_losing_the_marker_does_not_make_someone_elses_folder_deletable(fake, tmp_path):
    """The retry path must not become a way around ownership: no marker *and* never partly deleted by
    this session, or not the folder this session created, is still refused."""
    _godot, project, _set_mode = fake
    session = StagingSession.create(project, tmp_path)
    (session.root / staging.MARKER).unlink()                       # removed by someone else, not by a cleanup
    for extra in session.parent.iterdir():
        if extra.name != "project":
            extra.unlink()
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_NOT_OWNED and session.root.is_dir()
    # The folder is replaced by another one of the same name: its identity is not the one that was created.
    moved = tmp_path / "moved-away"
    session.parent.rename(moved)
    (session.parent / "project").mkdir(parents=True)
    (session.parent / "project" / "keep.txt").write_text("someone else's", encoding="utf-8")
    session.state = "leftover"
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_NOT_OWNED
    assert (session.parent / "project" / "keep.txt").is_file()
    shutil.rmtree(session.parent)
    shutil.rmtree(moved)
    staging._sessions.pop(session.id, None)


# ======================================================================================= FIX-21, FIX-25
@pytest.fixture
def staged(fake, tmp_path, beetle):
    from test_staging import OUTPUTS, stage_data, with_art
    godot, project, set_mode = fake
    with_art(project, beetle)
    for relative in staging.TOOL_DEPENDENCIES:
        target = project / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            target.write_text(f"# {relative}\n", encoding="utf-8")
    work = tmp_path / "work"
    work.mkdir()
    set_mode("ok", data=json.dumps(stage_data(beetle)), touch=OUTPUTS)
    yield godot, project, set_mode, work
    for session in list(staging._sessions.values()):
        try:
            session.remove()
        except BridgeError:
            staging._sessions.pop(session.id, None)


def rewrite_keeping_size(path, same_time=False):
    """Change a file's bytes without changing its length; optionally put its modification time back."""
    stat = path.stat()
    payload = bytearray(path.read_bytes())
    payload[-1] ^= 0xFF
    path.write_bytes(bytes(payload))
    if same_time:
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns))
    else:
        os.utime(path, ns=(stat.st_atime_ns, stat.st_mtime_ns + 2_000_000_000))


def test_fix25_the_result_carries_a_manifest_of_everything_the_stage_depended_on(staged, beetle):
    godot, project, _set_mode, work = staged
    result = staging.stage_presentation(godot, project, beetle, work)
    images = {row["path"] for row in beetle.data["assets"]["images"]}
    assert images <= set(result.dependencies) and ".godot-version" in result.dependencies
    assert "project.godot" in result.dependencies and set(staging.TOOL_DEPENDENCIES) <= set(result.dependencies)
    for row in result.dependencies.values():
        assert len(row["sha256"]) == 64 and row["size"] >= 0 and row["mtime_ns"] > 0
    assert result.project_fingerprint == staging.manifest_fingerprint(result.dependencies)
    assert staging.changed_dependencies(project, result) == [] == staging.changed_dependencies(project, result, deep=True)
    assert result.areas["staging"] == "PASS"


@pytest.mark.parametrize("relative", [".godot-version", "project.godot", "tools/monster_bridge/monster_stager.gd",
                                      "presentation/enemy/enemy_animation_presenter.gd",
                                      "presentation/definitions/enemy_animation_profile.gd"])
def test_fix25_the_fingerprint_covers_more_than_the_images(staged, beetle, relative):
    """The old fingerprint hashed the document's images and the engine pin and nothing else: a changed
    stager, presenter or profile script left an earlier result looking current."""
    godot, project, _set_mode, work = staged
    result = staging.stage_presentation(godot, project, beetle, work)
    # The engine pin must stay a version the stand-in engine has, or the second stage would not start.
    (project / relative).write_text("4.7.2\n\n" if relative == ".godot-version" else "changed after the stage\n",
                                    encoding="utf-8")
    assert staging.changed_dependencies(project, result) == [relative]
    again = staging.stage_presentation(godot, project, beetle, work)
    assert again.project_fingerprint != result.project_fingerprint


def test_fix21_a_change_the_cheap_check_cannot_see_is_found_by_the_deep_one(staged, beetle):
    godot, project, _set_mode, work = staged
    result = staging.stage_presentation(godot, project, beetle, work)
    image = beetle.data["assets"]["images"][0]["path"]
    rewrite_keeping_size(project / image, same_time=True)          # same size, same time, other pixels
    assert staging.changed_dependencies(project, result) == []
    assert staging.changed_dependencies(project, result, deep=True) == [image]
    (project / image).unlink()
    assert staging.changed_dependencies(project, result) == [image]


def test_fix21_the_editor_stops_calling_a_stage_passed_once_a_file_it_used_changes(app, tmp_path, staged, beetle):
    """Before: only an edit of the document or another project setting made the result "old". An image
    replaced on disk, or a changed stager script, left "Staging: passed" on screen."""
    pytest.importorskip("PySide6")
    from PySide6.QtTest import QTest
    from application.settings import Settings
    from gui.main_window import MainWindow
    from gui.testing import ScriptedPrompts
    godot, project, _set_mode, _work = staged
    for name in ("autoload/content_registry.gd", "data/definitions/enemy_definition.gd"):
        (project / name).parent.mkdir(parents=True, exist_ok=True)
        (project / name).write_text("", encoding="utf-8")
    prompts = ScriptedPrompts()
    view = MainWindow(Settings(tmp_path / "settings.json"), prompts)
    view.apply_project_settings({"project_root": str(project), "godot_path": str(godot), "drafts_folder": str(tmp_path)})
    view.show()
    QTest.qWaitForWindowExposed(view)
    try:
        view.set_session(DocumentSession(beetle))
        view.stage_presentation(carrier="ant")
        view.wait_for_jobs()
        assert view.stage_state() == "passed", prompts.last_error()
        image = project / beetle.data["assets"]["images"][0]["path"]
        original = image.read_bytes()
        rewrite_keeping_size(image)
        assert view.stage_state() == "stale"
        assert "오래됨" in view.overview.values["validation"].text() or view._show_session() is None
        view._show_session()
        assert "오래됨" in view.overview.values["validation"].text()
        image.write_bytes(original)                                 # put back: same bytes, new time
        assert view.stage_state() == "stale"                        # the cheap check cannot tell...
        view.refresh_catalog()                                      # ...the explicit refresh re-reads the files
        assert view.stage_state() == "passed"
        rewrite_keeping_size(image, same_time=True)                 # invisible to size and time
        assert view.stage_state() == "passed"
        view.refresh_catalog()
        assert view.stage_state() == "stale"
        image.write_bytes(original)
        view.refresh_catalog()
        (project / "tools/monster_bridge/monster_stager.gd").write_text("extends RefCounted\n# changed\n", encoding="utf-8")
        assert view.stage_state() == "stale"
    finally:
        view.session = None
        view.close()
        view.deleteLater()


# ============================================================================================== FIX-26
def calls(path):
    return path.read_text(encoding="utf-8").split() if path.exists() else []


def test_fix26_a_crash_after_the_work_was_done_is_told_apart_from_one_in_the_middle(fake, tmp_path):
    godot, project, set_mode = fake
    log = tmp_path / "calls.txt"
    set_mode("crash_after", calls=log)                             # prints its PASS line, writes the result, then dies
    with pytest.raises(BridgeError) as caught:
        client.call(godot, project, "inspect_monsters")
    assert caught.value.code == client.PROCESS_CRASH and len(calls(log)) == client.CRASH_ATTEMPTS == 3
    assert [row["classification"] for row in caught.value.crash_records] == [client.CRASH_AFTER_SUCCESS] * 3
    log.unlink()
    set_mode("crash", calls=log)                                   # dies before it reported anything
    with pytest.raises(BridgeError) as caught:
        client.call(godot, project, "inspect_monsters")
    assert caught.value.code == client.PROCESS_CRASH
    assert len(calls(log)) == 1 + client.DURING_WORK_RETRIES == 2   # an unexplained crash gets one more try, not two
    assert [row["classification"] for row in caught.value.crash_records] == [client.CRASH_DURING_WORK] * 2
    assert all(row["exit_code"] is not None and row["seconds"] >= 0 and row["step"] == "inspect_monsters"
               for row in caught.value.crash_records)


def test_fix26_a_retried_run_keeps_the_record_of_every_attempt(fake, tmp_path):
    godot, project, set_mode = fake
    set_mode("ok", crash_once=tmp_path / "once")
    response = client.call(godot, project, "inspect_monsters")
    assert response.attempts == 2 and response.process_result == "CRASHED_THEN_RETRIED"
    record, = response.crash_records
    assert record["classification"] == client.CRASH_DURING_WORK and record["attempt"] == 1
    assert record["step"] == "inspect_monsters" and isinstance(record["log_tail"], str)
    assert response.crashes == (record["exit_code"],)
    clean = client.call(godot, project, "inspect_monsters")
    assert clean.crash_records == () and clean.process_result == "CLEAN"


def test_fix26_a_stage_records_which_step_crashed_and_how(staged, tmp_path, beetle):
    godot, project, set_mode, work = staged
    set_mode("ok", crash_once=tmp_path / "once")
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and result.process["attempts"] == {"import": 1, "stage_monster": 2, "read_stage": 1}
    crash, = result.process["crashes"]
    assert (crash["step"], crash["attempt"], crash["classification"]) == ("stage_monster", 1, client.CRASH_DURING_WORK)
    assert result.process["crash_exit_codes"] == [crash["exit_code"]]
    assert result.process["result"] == "CRASHED_THEN_RETRIED"
    clean = staging.stage_presentation(godot, project, beetle, work)
    assert clean.process["crashes"] == [] and clean.process["result"] == "CLEAN"


def test_fix26_an_import_that_crashes_is_tried_once_more_and_no_further(staged, tmp_path, beetle):
    godot, project, set_mode, work = staged
    log = tmp_path / "calls.txt"
    set_mode("ok", import_exit=-1073741819, calls=log)
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work)
    expected = client.PROCESS_CRASH if os.name == "nt" else staging.STAGE_FAILED
    assert caught.value.code == expected
    if os.name == "nt":                                            # the crash exit code only survives on Windows
        assert calls(log).count("import") == 2
        assert [row["step"] for row in caught.value.crash_records] == ["import", "import"]
    assert [path for path in work.iterdir() if path.name.startswith(staging.STAGING_PREFIX)] == []


def test_fix26_retries_stop_at_the_overall_time_limit(fake, tmp_path, monkeypatch):
    godot, project, set_mode = fake
    log = tmp_path / "calls.txt"
    set_mode("crash_after", calls=log)
    monkeypatch.setattr(client, "RETRY_BUDGET_SECONDS", 0.0)       # the first attempt already used the budget
    with pytest.raises(BridgeError) as caught:
        client.call(godot, project, "inspect_monsters")
    assert caught.value.code == client.PROCESS_CRASH and len(calls(log)) == 1
    assert "time" in caught.value.detail


def test_fix26_the_classification_needs_the_success_line_and_no_failure_mark():
    marker = "MONSTER BRIDGE inspect_monsters PASS"
    assert client.classify_crash(f"Godot Engine\n{marker}\n", marker) == client.CRASH_AFTER_SUCCESS
    assert client.classify_crash("Godot Engine\n", marker) == client.CRASH_DURING_WORK
    assert client.classify_crash(f"{marker}\nSCRIPT ERROR: boom\n", marker) == client.CRASH_DURING_WORK
    assert client.classify_crash(f"ERROR: something failed\n{marker}\n", marker) == client.CRASH_DURING_WORK
    assert client.classify_crash(marker, "") == client.CRASH_DURING_WORK       # no marker defined: never "known"


# ============================================================================================== FIX-27
def test_fix27_the_sheet_is_inside_the_cache_budget_not_on_top_of_it(app):
    pytest.importorskip("PySide6")
    from gui import frame_cache
    from gui.frame_cache import FrameCache, load_frame, pixel_bytes
    frame, sheet = pixel_bytes(64, 48), pixel_bytes(384, 48)        # six frames in one sheet
    cache = FrameCache(max_bytes=sheet + 2 * frame + 100)
    for index in range(6):
        pixmap, state = load_frame(PROJECT, f"{BEETLE}/move.png", [64 * index, 0, 64, 48], cache)
        assert state == "ok" and pixmap is not None
        assert cache.total_bytes == cache.bytes + cache.sheet_bytes <= cache.max_bytes, index
    assert len(cache) == 2 and cache.evictions == 4 and cache.sheet_bytes == sheet
    assert cache.stats()["total_bytes"] == cache.total_bytes
    # A sheet that would not leave room for one of its own frames is not kept at all.
    tight = FrameCache(max_bytes=sheet + frame - 1)
    load_frame(PROJECT, f"{BEETLE}/move.png", [0, 0, 64, 48], tight)
    assert tight.sheet is None and tight.total_bytes == frame <= tight.max_bytes
    assert frame_cache.DEFAULT_BUDGET == frame_cache.FRAME_BUDGET + frame_cache.SHEET_LIMIT
    assert frame_cache.FRAMES.max_bytes == frame_cache.DEFAULT_BUDGET
    assert frame_cache.SHEET_LIMIT < frame_cache.DEFAULT_BUDGET


def test_fix27_evidence_images_are_kept_out_of_the_godot_import():
    """Every PNG under docs/ sits in a folder Godot is told to ignore, and none carries a generated
    ``.import`` file. (The first evidence folder was committed with 13 of them.)"""
    docs = PROJECT / "docs"
    pictures = sorted(docs.rglob("*.png"))
    assert pictures
    generated = sorted(path.relative_to(PROJECT).as_posix() for path in docs.rglob("*.import"))
    assert generated == []
    for picture in pictures:
        folder = picture.parent
        while folder != docs and not (folder / ".gdignore").is_file():
            folder = folder.parent
        assert (folder / ".gdignore").is_file(), f"{picture.relative_to(PROJECT)} is not under a .gdignore"
    limit = 1024 * 1024
    assert all(path.stat().st_size <= limit for path in pictures), "an evidence image is larger than 1 MiB"
