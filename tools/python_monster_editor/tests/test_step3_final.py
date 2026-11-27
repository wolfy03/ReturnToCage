"""MONSTER-STEP 3 final patch: the three items left after S2.

1. A required dependency that is missing, unreadable or badly named used to be left out of the manifest
   in silence, and the incomplete manifest was then used as if it were the whole truth.
2. ``StageResult.passed`` means "the structure matches" and keeps meaning that; what else is known about a
   result (was the copy one snapshot, is the manifest complete, are the files still the same, how did the
   processes and the cleanup go) is now told apart, and a copy that changed underneath is not shown as a
   confirmed success for the project.
3. A staging copy whose creation failed was removed with ``ignore_errors=True``: when that removal failed
   too, nothing said so and nothing remembered the folder.

Written against commit ``0513b42`` first (they failed there) and then fixed.
"""

import json
import os
import subprocess

import pytest

from conftest import PROJECT
from application.session import DocumentSession
from bridge import staging
from bridge.client import BridgeError
from bridge.staging import StagingSession


def copies(folder):
    return [path for path in folder.iterdir() if path.name.startswith(staging.STAGING_PREFIX)]


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


# ====================================================================================== 1. the manifest
def test_a_missing_required_dependency_is_an_error_not_a_shorter_manifest(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    (root / "present.gd").write_text("x", encoding="utf-8")
    assert set(staging.dependency_manifest(root, ["present.gd"])) == {"present.gd"}
    with pytest.raises(BridgeError) as caught:
        staging.dependency_manifest(root, ["present.gd", "tools/absent.gd"])
    assert caught.value.code == staging.STAGING_DEPENDENCY_INVALID and "tools/absent.gd" in caught.value.detail
    assert "missing" in caught.value.detail
    # An optional file may be absent; when it is there it is in the manifest like any other.
    manifest = staging.dependency_manifest(root, ["present.gd"], optional=["present.gd.import", "art.png.import"])
    assert set(manifest) == {"present.gd"}
    (root / "present.gd.import").write_text("y", encoding="utf-8")
    manifest = staging.dependency_manifest(root, ["present.gd"], optional=["present.gd.import"])
    assert set(manifest) == {"present.gd", "present.gd.import"} and len(manifest["present.gd.import"]["sha256"]) == 64


@pytest.mark.parametrize("relative, reason", [
    ("../outside.gd", "not a plain project-relative path"), ("/etc/passwd", "not a plain project-relative path"),
    ("C:/Windows/win.ini", "not a plain project-relative path"), ("a\\b.gd", "not a plain project-relative path"),
    ("a//b.gd", "not a plain project-relative path"), ("./a.gd", "not a plain project-relative path"),
    ("", "not a plain project-relative path"), ("folder", "not a plain file"),
])
def test_a_dependency_path_that_is_not_a_plain_file_inside_the_project_is_refused(tmp_path, relative, reason):
    root = tmp_path / "project"
    (root / "folder").mkdir(parents=True)
    (tmp_path / "outside.gd").write_text("outside", encoding="utf-8")
    for optional in (False, True):                 # a bad name is refused whether or not the file was required
        with pytest.raises(BridgeError) as caught:
            staging.dependency_manifest(root, [] if optional else [relative], optional=[relative] if optional else [])
        assert caught.value.code == staging.STAGING_DEPENDENCY_INVALID and reason in caught.value.detail


def test_a_dependency_reached_through_a_link_or_unreadable_is_refused(tmp_path, monkeypatch):
    root = tmp_path / "project"
    root.mkdir()
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "script.gd").write_text("outside", encoding="utf-8")
    linked = root / "linked"
    made = os.name == "nt" and subprocess.run(["cmd", "/c", "mklink", "/J", str(linked), str(outside)],
                                              capture_output=True).returncode == 0
    if not made:
        try:
            os.symlink(outside, linked, target_is_directory=True)
            made = True
        except (OSError, NotImplementedError):
            pass
    if made:
        with pytest.raises(BridgeError) as caught:
            staging.dependency_manifest(root, ["linked/script.gd"])
        assert caught.value.code == staging.STAGING_DEPENDENCY_INVALID and "link" in caught.value.detail
    (root / "locked.gd").write_text("x", encoding="utf-8")
    real = staging.file_sha256

    def denied(path):
        if str(path).endswith("locked.gd"):
            raise PermissionError("access denied")
        return real(path)
    monkeypatch.setattr(staging, "file_sha256", denied)
    with pytest.raises(BridgeError) as caught:
        staging.dependency_manifest(root, ["locked.gd"])
    assert caught.value.code == staging.STAGING_DEPENDENCY_INVALID and "access denied" in caught.value.detail


@pytest.mark.parametrize("relative", ["tools/monster_bridge/monster_stager.gd",
                                      "presentation/enemy/enemy_animation_presenter.gd", "project.godot"])
def test_a_stage_without_a_file_it_depends_on_produces_no_result(staged, beetle, relative):
    """Before: the stage "passed" with a manifest that simply did not mention the file, and its fingerprint
    then matched any later state in which the file was still missing."""
    godot, project, _set_mode, work = staged
    if relative == "project.godot":
        # The copy needs project.godot to be a project at all; lose it between the copy and the manifest.
        real = staging.dependency_manifest

        def manifest_without(root, *args, **kwargs):
            (root / "project.godot").unlink()
            return real(root, *args, **kwargs)
        import pytest as _pytest
        patch = _pytest.MonkeyPatch()
        patch.setattr(staging, "dependency_manifest", manifest_without)
    else:
        patch = None
        (project / relative).unlink()
    try:
        with pytest.raises(BridgeError) as caught:
            staging.stage_presentation(godot, project, beetle, work)
    finally:
        if patch is not None:
            patch.undo()
    assert caught.value.code == staging.STAGING_DEPENDENCY_INVALID and relative in caught.value.detail
    assert copies(work) == [] and staging.leftovers() == []


def test_the_import_settings_of_an_image_are_an_optional_dependency(staged, beetle):
    godot, project, _set_mode, work = staged
    image = beetle.data["assets"]["images"][0]["path"]
    plain = staging.stage_presentation(godot, project, beetle, work)
    assert image + ".import" not in plain.dependencies and plain.verdicts["dependencies"] == "PASS"
    (project / (image + ".import")).write_text("[remap]\nimporter=\"texture\"\n", encoding="utf-8")
    with_settings = staging.stage_presentation(godot, project, beetle, work)
    assert image + ".import" in with_settings.dependencies
    assert with_settings.project_fingerprint != plain.project_fingerprint
    (project / (image + ".import")).write_text("[remap]\nimporter=\"texture\"\nfilter=true\n", encoding="utf-8")
    assert staging.changed_dependencies(project, with_settings) == [image + ".import"]


def test_a_carrier_file_the_engine_names_must_exist_in_the_copy(staged, beetle):
    from test_staging import stage_data
    godot, project, set_mode, work = staged
    data = stage_data(beetle)
    (project / "data/content/enemies").mkdir(parents=True)
    (project / "data/content/enemies/ant.tres").write_text("[gd_resource]", encoding="utf-8")
    data["attach"]["dependencies"] = ["res://data/content/enemies/ant.tres"]
    set_mode("ok", data=json.dumps(data))
    result = staging.stage_presentation(godot, project, beetle, work)
    assert "data/content/enemies/ant.tres" in result.dependencies
    data["attach"]["dependencies"] = ["res://data/content/enemies/absent.tres"]
    set_mode("ok", data=json.dumps(data))
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work)
    assert caught.value.code in (staging.RESOURCE_PATH_INVALID, staging.STAGING_DEPENDENCY_INVALID)
    assert copies(work) == []


# ======================================================================================== 2. the verdicts
def test_a_clean_stage_is_confirmed_and_says_so_part_by_part(staged, beetle):
    godot, project, _set_mode, work = staged
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and result.confirmed
    assert result.verdicts == {"structure": "PASS", "copy": "PASS", "dependencies": "PASS", "current": "PASS",
                               "process": "CLEAN", "cleanup": "PASS"}
    assert result.changed_since_copy == ()
    # The public surface that existed before is still there and still means what it meant.
    assert result.areas["staging"] == "PASS" and result.differences == () and result.is_current(beetle)


def test_a_copy_that_changed_underneath_matches_the_structure_but_is_not_confirmed(staged, beetle, monkeypatch):
    """Before: areas["staging"] was WARNING, and everything a caller looked at (``passed``, the editor's
    "Staging: passed") still said yes."""
    godot, project, _set_mode, work = staged
    (project / "notes.txt").write_text("before", encoding="utf-8")
    real_survey = staging.survey

    def survey_then_edit(root, *args, **kwargs):
        rows = real_survey(root, *args, **kwargs)
        (project / "notes.txt").write_text("after, and longer", encoding="utf-8")     # saved by another program
        return rows
    monkeypatch.setattr(staging, "survey", survey_then_edit)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and result.differences == ()                # the structure does match
    assert result.areas["staging"] == "WARNING"
    assert result.verdicts["structure"] == "PASS" and result.verdicts["copy"] == "WARNING"
    assert not result.confirmed
    assert any("not one consistent snapshot" in note for note in result.notes)


def test_a_dependency_that_changed_while_the_stage_ran_is_not_confirmed_either(staged, beetle, monkeypatch):
    godot, project, _set_mode, work = staged
    stager = project / "tools/monster_bridge/monster_stager.gd"
    real_import = staging.import_assets

    def import_then_edit(*args, **kwargs):
        log = real_import(*args, **kwargs)
        stager.write_text("# rewritten while Godot was running\n", encoding="utf-8")
        return log
    monkeypatch.setattr(staging, "import_assets", import_then_edit)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and result.verdicts["copy"] == "PASS"       # the copy itself was one snapshot
    assert result.verdicts["current"] == "FAIL" and not result.confirmed
    assert result.changed_since_copy == ("tools/monster_bridge/monster_stager.gd",)


def test_a_structural_difference_a_crash_and_a_cleanup_problem_each_show_where_they_belong(staged, tmp_path, beetle,
                                                                                          monkeypatch):
    from test_staging import stage_data
    godot, project, set_mode, work = staged
    data = stage_data(beetle)
    data["profile"]["animations"]["idle"]["fps"] = 1.0
    set_mode("ok", data=json.dumps(data))
    differs = staging.stage_presentation(godot, project, beetle, work)
    assert not differs.passed and not differs.confirmed and differs.verdicts["structure"] == "FAIL"
    assert differs.verdicts["copy"] == "PASS" and differs.verdicts["current"] == "PASS"

    set_mode("ok", data=json.dumps(stage_data(beetle)), crash_once=tmp_path / "once")
    crashed = staging.stage_presentation(godot, project, beetle, work)
    assert crashed.verdicts["process"] == "CRASHED_THEN_RETRIED" and crashed.verdicts["structure"] == "PASS"
    assert crashed.confirmed                                          # a retried crash is reported, not held against it

    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    real = staging._delete_tree
    monkeypatch.setattr(staging, "_delete_tree", lambda path: [(str(path), PermissionError("locked"))])
    leftover = staging.stage_presentation(godot, project, beetle, work)
    assert leftover.verdicts["cleanup"] == "FAIL" and leftover.cleanup_error and leftover.verdicts["structure"] == "PASS"
    assert leftover.confirmed                                         # the check was sound; a folder is left behind
    monkeypatch.setattr(staging, "_delete_tree", real)
    assert leftover.session.remove()
    kept = staging.stage_presentation(godot, project, beetle, work, keep=True)
    assert kept.verdicts["cleanup"] == "KEPT"
    kept.session.remove()


def test_the_editor_does_not_call_an_unconfirmed_stage_passed(app, tmp_path, staged, beetle, monkeypatch):
    pytest.importorskip("PySide6")
    from PySide6.QtTest import QTest
    from application.settings import Settings
    from gui import strings
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
        assert view.stage_state() == "passed" and view.last_stage.confirmed, prompts.last_error()

        (project / "notes.txt").write_text("before", encoding="utf-8")
        real_survey = staging.survey

        def survey_then_edit(root, *args, **kwargs):
            rows = real_survey(root, *args, **kwargs)
            (project / "notes.txt").write_text("after, and longer", encoding="utf-8")
            return rows
        monkeypatch.setattr(staging, "survey", survey_then_edit)
        view.stage_presentation(carrier="ant")
        view.wait_for_jobs()
        monkeypatch.setattr(staging, "survey", real_survey)
        assert view.last_stage.passed and not view.last_stage.confirmed
        assert view.stage_state() == "unconfirmed"
        shown = view.overview.values["validation"].text()
        assert strings.STAGE["state"]["unconfirmed"] in shown and strings.STAGE["state"]["passed"] not in shown
        assert "확정" in view._last_message and prompts.last_error() is None       # said, but not as a failure
    finally:
        view.session = None
        view.close()
        view.deleteLater()


# ============================================================================== 3. a failed creation's cleanup
def test_a_creation_that_failed_and_could_not_be_cleaned_up_says_both_and_keeps_the_folder_known(fake, tmp_path,
                                                                                                monkeypatch):
    """Before: ``shutil.rmtree(..., ignore_errors=True)``. The first error was raised alone, the folder
    stayed on disk, and no session remembered it."""
    _godot, project, _set_mode = fake
    (project / "assets").mkdir()
    (project / "assets/a.png").write_bytes(b"x")
    (project / "assets/b.png").write_bytes(b"y")
    work = tmp_path / "work"
    work.mkdir()
    real_copy, real_delete = staging._copy_bytes, staging._delete_tree

    def failing(source, descriptor, target):
        if str(source).endswith("b.png"):
            raise PermissionError("b.png is locked by another program")
        return real_copy(source, descriptor, target)
    monkeypatch.setattr(staging, "_copy_bytes", failing)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    monkeypatch.setattr(staging, "_delete_tree", lambda path: [(str(path / "project" / "assets" / "a.png"),
                                                               PermissionError("a.png is held by a scanner"))])
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work)
    error = caught.value
    left, = copies(work)
    assert error.code == staging.STAGE_FAILED                         # the first failure keeps its code
    assert "b.png is locked by another program" in error.detail       # 1. what went wrong first
    assert "a.png is held by a scanner" in error.detail               # 2. why the cleanup failed
    assert str(left) in error.detail                                  # 3. where the folder is
    session, = staging.leftovers()
    assert session.id in error.detail and session.parent == left      # 4. which session
    assert "leftovers()" in error.detail and "by hand" in error.detail and "real project" in error.detail   # 5. what to do
    assert session.state == "leftover" and "a.png is held by a scanner" in session.cleanup_error
    assert "b.png is locked" in session.creation_error
    assert error.leftover == left and error.session_id == session.id
    # The remembered session can finish the job once the lock is gone - with its ownership checks intact.
    monkeypatch.setattr(staging, "_delete_tree", real_delete)
    assert session.remove() is True and copies(work) == [] and staging.leftovers() == []
    assert (project / "assets/a.png").is_file()


def test_a_failed_creation_whose_cleanup_works_leaves_nothing_and_raises_the_first_error_only(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    (project / "a.bin").write_bytes(b"x")
    monkeypatch.setattr(staging, "_copy_bytes", lambda *_args: (_ for _ in ()).throw(PermissionError("locked")))
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, tmp_path)
    assert caught.value.code == staging.STAGE_FAILED and "could not be removed" not in caught.value.detail
    assert copies(tmp_path) == [] and staging.leftovers() == []


def test_the_marker_failing_is_cleaned_up_the_same_way(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    monkeypatch.setattr(StagingSession, "_write_marker",
                        lambda self: (_ for _ in ()).throw(BridgeError(staging.STAGE_FAILED, "cannot mark the staging copy")))
    with pytest.raises(BridgeError):
        StagingSession.create(project, tmp_path)
    assert copies(tmp_path) == [] and staging.leftovers() == []
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    real = staging._delete_tree
    monkeypatch.setattr(staging, "_delete_tree", lambda path: [(str(path), OSError("device busy"))])
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, tmp_path)
    assert "cannot mark the staging copy" in caught.value.detail and "device busy" in caught.value.detail
    session, = staging.leftovers()
    monkeypatch.setattr(staging, "_delete_tree", real)
    assert session.remove() and copies(tmp_path) == []            # no marker was ever written: identity is the proof


def test_an_interrupt_during_the_copy_is_not_turned_into_another_error(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    (project / "a.bin").write_bytes(b"x")
    monkeypatch.setattr(staging, "_copy_bytes", lambda *_args: (_ for _ in ()).throw(KeyboardInterrupt()))
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    real = staging._delete_tree
    monkeypatch.setattr(staging, "_delete_tree", lambda path: [(str(path), OSError("device busy"))])
    with pytest.raises(KeyboardInterrupt) as caught:
        StagingSession.create(project, tmp_path)
    session, = staging.leftovers()
    assert any(str(session.parent) in note and "device busy" in note for note in caught.value.__notes__)
    monkeypatch.setattr(staging, "_delete_tree", real)
    assert session.remove()


def test_a_failed_creation_never_deletes_a_folder_it_cannot_prove_is_its_own(fake, tmp_path, monkeypatch):
    """The cleanup of a failed creation goes through the same ownership checks as any other removal."""
    _godot, project, _set_mode = fake
    (project / "a.bin").write_bytes(b"x")
    victim = tmp_path / "victim"
    (victim / "project").mkdir(parents=True)
    (victim / "keep.txt").write_text("someone else's", encoding="utf-8")
    real_copy = staging._copy_bytes
    swapped = {}

    def swap_then_fail(source, descriptor, target):
        # Between the copy and the cleanup the staging folder is replaced by another folder of the same name.
        parent = target.parent
        while not parent.name.startswith(staging.STAGING_PREFIX):
            parent = parent.parent
        real_copy(source, descriptor, target)
        moved = tmp_path / "moved-away"
        parent.rename(moved)
        victim.rename(parent)
        swapped.update(parent=parent, moved=moved)
        raise PermissionError("locked")
    monkeypatch.setattr(staging, "_copy_bytes", swap_then_fail)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, tmp_path)
    assert (swapped["parent"] / "keep.txt").read_text(encoding="utf-8") == "someone else's"     # untouched
    assert "could not be removed" in caught.value.detail and "not the folder this session created" in caught.value.detail
    session, = staging.leftovers()
    with pytest.raises(BridgeError) as again:
        session.remove()
    assert again.value.code == staging.STAGING_NOT_OWNED and (swapped["parent"] / "keep.txt").is_file()
    staging._sessions.pop(session.id, None)
    assert PROJECT.is_dir()
