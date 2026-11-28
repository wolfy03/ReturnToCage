"""MONSTER-STEP 3 closure patch: three boundary conditions left after the final patch (``98fd8b3``).

FIX-29  ``changed_dependencies`` and ``dependency_stats`` looked only at the last path component. A
        folder on the way that had become a link to a place outside the project, holding a file with the
        same bytes, passed for the unchanged dependency. They now use the manifest's own path rules.
FIX-30  An optional dependency (an image's ``.png.import``) was judged from the staging copy after Godot
        had run in it, and a file that did not exist when the stage was made was never looked at again.
        Its presence is now recorded from the source as copied, and a later appearance is a change.
FIX-31  A cleanup that failed was retried without asking again whose folder it was. Another folder that
        took the name between two attempts was deleted.

Written against ``98fd8b3`` first (they failed there) and then fixed.
"""

import json
import os
import subprocess
from types import SimpleNamespace

import pytest

from bridge import staging
from bridge.client import BridgeError
from bridge.staging import StagingSession


def copies(folder):
    return [path for path in folder.iterdir() if path.name.startswith(staging.STAGING_PREFIX)]


def make_link(link, target):
    """A junction (Windows) or a symbolic link to a folder. False where neither can be made."""
    if os.name == "nt" and subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)],
                                          capture_output=True).returncode == 0:
        return True
    try:
        os.symlink(target, link, target_is_directory=True)
        return True
    except (OSError, NotImplementedError):
        return False


def drop_link(link):
    if not os.path.lexists(link):
        return
    try:
        os.rmdir(link)
    except OSError:
        os.unlink(link)


def result_of(root, paths, absent=()):
    """What a stage would have recorded for these files (the two checks read nothing else of a result)."""
    optional = {path: "present" for path in paths if path.endswith(".import")}
    optional.update({path: "absent" for path in absent})
    return SimpleNamespace(dependencies=staging.dependency_manifest(root, paths), optional_dependencies=optional)


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


# ============================================================================ FIX-29: the re-check's paths
def test_a_folder_swapped_for_a_link_to_identical_bytes_is_a_changed_dependency(tmp_path):
    """Before: the file at the end of the path was a plain file with the right hash, size and time."""
    root, outside = tmp_path / "project", tmp_path / "outside"
    (root / "art").mkdir(parents=True)
    outside.mkdir()
    (root / "art/sheet.png").write_bytes(b"the same bytes")
    result = result_of(root, ["art/sheet.png"])
    baseline = staging.dependency_stats(root, result)
    assert staging.changed_dependencies(root, result) == [] and staging.changed_dependencies(root, result, deep=True) == []
    # The folder moves out of the project and a link takes its name: same file, same hash, same times.
    (root / "art").rename(outside / "art")
    if not make_link(root / "art", outside / "art"):
        pytest.skip("this platform cannot create a folder link here")
    try:
        assert (root / "art/sheet.png").read_bytes() == b"the same bytes"
        assert staging.changed_dependencies(root, result, deep=True) == ["art/sheet.png"]
        assert staging.changed_dependencies(root, result) == ["art/sheet.png"]
        assert staging.changed_dependencies(root, result, baseline=baseline) == ["art/sheet.png"]
        assert staging.dependency_stats(root, result) == {}        # nothing to take a baseline of
    finally:
        drop_link(root / "art")


@pytest.mark.parametrize("relative", ["../outside.png", "/outside.png", "C:/outside.png", "art\\sheet.png",
                                      "art//sheet.png", "./art/sheet.png", ""])
def test_a_recorded_path_that_is_not_a_plain_project_path_is_never_an_unchanged_dependency(tmp_path, relative):
    root = tmp_path / "project"
    (root / "art").mkdir(parents=True)
    (root / "art/sheet.png").write_bytes(b"x")
    (tmp_path / "outside.png").write_bytes(b"x")
    row = dict(staging.dependency_manifest(root, ["art/sheet.png"])["art/sheet.png"])
    forged = SimpleNamespace(dependencies={relative: row}, optional_dependencies={})
    assert staging.changed_dependencies(root, forged) == [relative]
    assert staging.changed_dependencies(root, forged, deep=True) == [relative]
    assert staging.dependency_stats(root, forged) == {}


def test_a_dependency_that_became_a_folder_or_vanished_is_changed_in_both_forms(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    (root / "a.gd").write_text("a", encoding="utf-8")
    (root / "b.gd").write_text("b", encoding="utf-8")
    result = result_of(root, ["a.gd", "b.gd"])
    (root / "a.gd").unlink()
    (root / "a.gd").mkdir()
    (root / "b.gd").unlink()
    for deep in (False, True):
        assert staging.changed_dependencies(root, result, deep=deep) == ["a.gd", "b.gd"]
    assert staging.dependency_stats(root, result) == {}


def test_the_recheck_and_the_manifest_refuse_the_same_paths(tmp_path):
    """One policy: whatever ``dependency_manifest`` would refuse, the re-check calls changed."""
    root, outside = tmp_path / "project", tmp_path / "outside"
    root.mkdir()
    outside.mkdir()
    (outside / "script.gd").write_text("x", encoding="utf-8")
    if not make_link(root / "linked", outside):
        pytest.skip("this platform cannot create a folder link here")
    try:
        with pytest.raises(BridgeError):
            staging.dependency_manifest(root, ["linked/script.gd"])
        row = {"sha256": staging.file_sha256(outside / "script.gd"), "size": 1,
               "mtime_ns": os.lstat(outside / "script.gd").st_mtime_ns}
        forged = SimpleNamespace(dependencies={"linked/script.gd": row}, optional_dependencies={})
        for deep in (False, True):
            assert staging.changed_dependencies(root, forged, deep=deep) == ["linked/script.gd"]
    finally:
        drop_link(root / "linked")


# ================================================================ FIX-30: optional dependencies' presence
def settings_of(beetle):
    return beetle.data["assets"]["images"][0]["path"] + ".import"


def test_import_settings_absent_from_the_start_are_recorded_as_absent(staged, beetle):
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert settings not in result.dependencies and result.optional_dependencies[settings] == "absent"
    assert result.confirmed and result.changed_since_copy == ()
    assert staging.changed_dependencies(project, result) == []
    assert staging.changed_dependencies(project, result, deep=True) == []


def test_import_settings_present_from_the_start_are_in_the_manifest(staged, beetle):
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    (project / settings).write_text("[remap]\n", encoding="utf-8")
    result = staging.stage_presentation(godot, project, beetle, work)
    assert settings in result.dependencies and result.optional_dependencies[settings] == "present"
    assert result.confirmed and staging.changed_dependencies(project, result, deep=True) == []


def test_settings_godot_wrote_into_the_copy_only_are_not_a_change_of_the_project(staged, beetle, monkeypatch):
    """Before: the manifest was read from the copy after Godot ran, so a file Godot generated there was
    recorded as a project file - and then found "missing" from the project."""
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    real = staging.import_assets

    def import_and_generate(godot, root, *args, **kwargs):
        (root / settings).write_text("[remap]\ngenerated by the import\n", encoding="utf-8")
        return real(godot, root, *args, **kwargs)
    monkeypatch.setattr(staging, "import_assets", import_and_generate)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert not (project / settings).exists()
    assert settings not in result.dependencies and result.optional_dependencies[settings] == "absent"
    assert result.changed_since_copy == () and result.verdicts["current"] == "PASS" and result.confirmed
    assert staging.changed_dependencies(project, result, deep=True) == []


def test_settings_godot_rewrote_in_the_copy_do_not_change_what_the_source_had(staged, beetle, monkeypatch):
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    (project / settings).write_text("[remap]\noriginal\n", encoding="utf-8")
    real = staging.import_assets

    def import_and_rewrite(godot, root, *args, **kwargs):
        (root / settings).write_text("[remap]\nrewritten in the copy\n", encoding="utf-8")
        return real(godot, root, *args, **kwargs)
    monkeypatch.setattr(staging, "import_assets", import_and_rewrite)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.dependencies[settings]["sha256"] == staging.file_sha256(project / settings)
    assert result.confirmed and result.changed_since_copy == ()


def test_settings_created_in_the_project_while_the_stage_ran_take_the_confirmation_back(staged, beetle, monkeypatch):
    """Before: a path that was not in the manifest was never looked at again."""
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    real = staging.import_assets

    def import_then_create(*args, **kwargs):
        (project / settings).write_text("[remap]\nnew\n", encoding="utf-8")
        return real(*args, **kwargs)
    monkeypatch.setattr(staging, "import_assets", import_then_create)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed                                             # the structure still matches
    assert result.changed_since_copy == (settings,) and result.verdicts["current"] == "FAIL"
    assert not result.confirmed and any(settings in note for note in result.notes)


def test_settings_created_after_the_stage_make_the_result_stale(staged, beetle):
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.confirmed
    (project / settings).write_text("[remap]\nnew\n", encoding="utf-8")
    assert staging.changed_dependencies(project, result) == [settings]
    assert staging.changed_dependencies(project, result, deep=True) == [settings]
    assert staging.changed_dependencies(project, result, baseline=staging.dependency_stats(project, result)) == [settings]
    (project / settings).unlink()
    assert staging.changed_dependencies(project, result, deep=True) == []


@pytest.mark.parametrize("edit", ["delete", "rewrite"])
def test_settings_deleted_or_rewritten_while_the_stage_ran_take_the_confirmation_back(staged, beetle, monkeypatch, edit):
    godot, project, _set_mode, work = staged
    settings = settings_of(beetle)
    (project / settings).write_text("[remap]\noriginal\n", encoding="utf-8")
    real = staging.import_assets

    def import_then_edit(*args, **kwargs):
        if edit == "delete":
            (project / settings).unlink()
        else:
            (project / settings).write_text("[remap]\nORIGINAL\n", encoding="utf-8")      # same size
        return real(*args, **kwargs)
    monkeypatch.setattr(staging, "import_assets", import_then_edit)
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.optional_dependencies[settings] == "present" and settings in result.dependencies
    assert result.changed_since_copy == (settings,) and not result.confirmed and result.passed


def test_an_optional_path_reached_through_a_link_is_a_change_not_an_absence(tmp_path):
    root, outside = tmp_path / "project", tmp_path / "outside"
    (root / "art").mkdir(parents=True)
    outside.mkdir()
    (root / "art/sheet.png").write_bytes(b"x")
    result = result_of(root, ["art/sheet.png"], absent=["art/sheet.png.import"])
    assert staging.changed_dependencies(root, result, deep=True) == []
    (root / "art").rename(outside / "art")
    (outside / "art/sheet.png.import").write_text("x", encoding="utf-8")
    if not make_link(root / "art", outside / "art"):
        pytest.skip("this platform cannot create a folder link here")
    try:
        for deep in (False, True):
            assert staging.changed_dependencies(root, result, deep=deep) == ["art/sheet.png", "art/sheet.png.import"]
    finally:
        drop_link(root / "art")


def test_the_result_keeps_its_old_shape(staged, beetle):
    godot, project, _set_mode, work = staged
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and result.differences == () and result.is_current(beetle, result.project_fingerprint)
    assert result.project_fingerprint == staging.manifest_fingerprint(result.dependencies)
    assert result.project_fingerprint == staging.source_fingerprint(
        project, beetle, [path for path in result.dependencies if path not in staging.dependency_paths(beetle)])
    assert set(result.verdicts) == {"structure", "copy", "dependencies", "current", "process", "cleanup"}
    # A result built the old way (no record of optional files) is still a valid argument.
    old = SimpleNamespace(dependencies=result.dependencies)
    assert staging.changed_dependencies(project, old, deep=True) == [] and staging.dependency_stats(project, old)


# ============================================================== FIX-31: ownership between cleanup attempts
def project_with_files(fake):
    _godot, project, _set_mode = fake
    (project / "assets").mkdir(exist_ok=True)
    (project / "assets/a.png").write_bytes(b"x")
    return project


def swap_after_first_failure(monkeypatch, tmp_path, session_parent=None):
    """``_delete_tree`` fails once; before the retry another folder has the staging folder's name."""
    real = staging._delete_tree
    seen = {"calls": 0}

    def delete(parent):
        seen["calls"] += 1
        if seen["calls"] > 1:
            return real(parent)
        parent.rename(tmp_path / "moved-away")
        (parent / "project").mkdir(parents=True)
        (parent / "keep.txt").write_text("someone else's", encoding="utf-8")
        seen["parent"] = parent
        return [(str(parent / "project" / "assets" / "a.png"), PermissionError("a.png is held by a scanner"))]
    monkeypatch.setattr(staging, "_delete_tree", delete)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    return seen, real


def test_remove_does_not_delete_a_folder_that_took_the_name_between_two_attempts(fake, tmp_path, monkeypatch):
    """Before: ownership was checked once, and attempts 2..4 deleted whatever was at the path."""
    project = project_with_files(fake)
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)
    seen, real = swap_after_first_failure(monkeypatch, tmp_path)
    with pytest.raises(BridgeError) as caught:
        session.remove()
    newcomer = seen["parent"]
    assert (newcomer / "keep.txt").read_text(encoding="utf-8") == "someone else's" and (newcomer / "project").is_dir()
    assert seen["calls"] == 1                                          # nothing was deleted after the refusal
    error = caught.value
    assert error.code == staging.STAGING_NOT_OWNED and "not the folder this session created" in error.detail
    assert "a.png is held by a scanner" in error.detail               # the failure that led to the retry
    assert session.state == "leftover" and session in staging.leftovers()
    assert "a.png is held by a scanner" in session.cleanup_error and "not the folder" in session.cleanup_error
    # It stays refused for as long as the other folder is there.
    monkeypatch.setattr(staging, "_delete_tree", real)
    with pytest.raises(BridgeError) as again:
        session.remove()
    assert again.value.code == staging.STAGING_NOT_OWNED and (newcomer / "keep.txt").is_file()
    # Once the session's own folder is back under its name, the old recovery still works.
    import shutil
    shutil.rmtree(newcomer)
    (tmp_path / "moved-away").rename(newcomer)
    assert session.remove() is True and copies(work) == [] and staging.leftovers() == []


def test_a_failed_creation_does_not_delete_a_folder_that_took_the_name_between_two_attempts(fake, tmp_path, monkeypatch):
    project = project_with_files(fake)
    work = tmp_path / "work"
    work.mkdir()
    real_copy = staging._copy_bytes

    def failing(source, descriptor, target):
        real_copy(source, descriptor, target)
        raise PermissionError("the disk went away")
    monkeypatch.setattr(staging, "_copy_bytes", failing)
    seen, _real = swap_after_first_failure(monkeypatch, tmp_path)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work)
    newcomer = seen["parent"]
    assert (newcomer / "keep.txt").read_text(encoding="utf-8") == "someone else's" and seen["calls"] == 1
    error = caught.value
    assert error.code == staging.STAGE_FAILED and "the disk went away" in error.detail      # what went wrong first
    assert "a.png is held by a scanner" in error.detail                                     # the first cleanup failure
    assert "not the folder this session created" in error.detail                            # why the retry stopped
    session, = staging.leftovers()
    assert error.session_id == session.id and "the disk went away" in session.creation_error
    assert "a.png is held by a scanner" in session.cleanup_error
    staging._sessions.pop(session.id, None)


def test_a_folder_replaced_by_a_link_between_two_attempts_is_not_followed(fake, tmp_path, monkeypatch):
    project = project_with_files(fake)
    work, victim = tmp_path / "work", tmp_path / "victim"
    work.mkdir()
    (victim / "project").mkdir(parents=True)
    (victim / "keep.txt").write_text("someone else's", encoding="utf-8")
    session = StagingSession.create(project, work)
    probe = tmp_path / "probe"
    if not make_link(probe, victim):
        pytest.skip("this platform cannot create a folder link here")
    drop_link(probe)
    real = staging._delete_tree
    calls = []

    def delete(parent):
        calls.append(parent)
        if len(calls) > 1:
            return real(parent)
        parent.rename(tmp_path / "moved-away")
        make_link(parent, victim)
        return [(str(parent), PermissionError("held"))]
    monkeypatch.setattr(staging, "_delete_tree", delete)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    try:
        with pytest.raises(BridgeError) as caught:
            session.remove()
        assert caught.value.code == staging.STAGING_NOT_OWNED and len(calls) == 1
        assert (victim / "keep.txt").is_file() and (victim / "project").is_dir()
    finally:
        drop_link(session.parent)
        staging._sessions.pop(session.id, None)


def test_a_retry_after_an_honest_partial_deletion_still_finishes(fake, tmp_path, monkeypatch):
    """The re-check must not get in the way of what retries are for: the marker is already gone, the
    owner token and the folder's identity still say whose folder it is."""
    project = project_with_files(fake)
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)
    real = staging._delete_tree
    calls = []

    def delete(parent):
        calls.append(parent)
        if len(calls) > 1:
            return real(parent)
        (parent / "project" / staging.MARKER).unlink()                # deleted this far, then a lock
        return [(str(parent / "project"), PermissionError("held by a scanner"))]
    monkeypatch.setattr(staging, "_delete_tree", delete)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    assert session.remove() is True and len(calls) == 2
    assert copies(work) == [] and session.state == "removed" and staging.leftovers() == []


def test_every_attempt_fails_the_old_way_when_the_folder_stays_the_same(fake, tmp_path, monkeypatch):
    project = project_with_files(fake)
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)
    real = staging._delete_tree
    calls = []
    monkeypatch.setattr(staging, "_delete_tree", lambda parent: calls.append(parent) or [
        (str(parent / "project" / "assets" / "a.png"), PermissionError("a.png is held by a scanner"))])
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_CLEANUP_FAILED and len(calls) == staging.CLEANUP_ATTEMPTS
    assert session.state == "leftover" and "a.png is held by a scanner" in session.cleanup_error
    monkeypatch.setattr(staging, "_delete_tree", real)
    assert session.remove() is True and staging.leftovers() == []


def test_a_first_refusal_changes_nothing_about_the_session(fake, tmp_path, monkeypatch):
    project = project_with_files(fake)
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)
    (session.root / staging.MARKER).write_text(json.dumps({"session": "someone-else"}), encoding="utf-8")
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_NOT_OWNED and session.state == "ready" and session.cleanup_error == ""
    (session.root / staging.MARKER).write_text(json.dumps({"session": session.id}), encoding="utf-8")
    assert session.remove() is True
