"""Staging: the project copy and who may delete it, the request, the response checks, and the comparison of
Godot's readback with the document.

The engine is the stand-in from ``conftest.fake`` - a real child process. What the real engine builds is
checked by ``check_godot_stage.py``; these tests cover everything around it: that the real project is
never the target, that a copy is cleaned up on every path, that nothing outside the project is copied
or deleted, and that every kind of difference is reported.
"""

import copy
import json
import os
import shutil
import subprocess
import threading

import pytest

from conftest import PROJECT, load
from bridge import client, staging
from bridge.client import BridgeError
from bridge.staging import StagingSession
from rtcmonster import new_document, set_value

FRAMES = "res://monster_stage/sewer_beetle/sprite_frames.tres"
PROFILE = "res://monster_stage/sewer_beetle/animation_profile.tres"
OUTPUTS = json.dumps([FRAMES.removeprefix("res://"), PROFILE.removeprefix("res://")])


def readback(document, frames=FRAMES):
    """What Godot reports for a correctly staged document."""
    data = document.data
    images = {row["id"]: row for row in data["assets"]["images"]}
    animations = {}
    for clip in data["animations"]["clips"]:
        rows = []
        for frame in clip["frames"]:
            image = images[frame["image"]]
            rect = list(frame["rect"]) if frame["rect"] is not None else [0, 0, image["width"], image["height"]]
            rows.append({"texture_path": "res://" + image["path"], "region": [float(value) for value in rect],
                         "duration": float(frame["duration"])})
        animations[clip["id"]] = {"fps": float(clip["fps"]), "loop": clip["loop"], "frames": rows}
    presentation = data["presentation"]
    return {"errors": [], "sprite_frames_path": frames, "animations": animations, "roles": dict(presentation["roles"]),
            "visual_scale": [float(value) for value in presentation["visual_scale"]],
            "visual_offset": [float(value) for value in presentation["visual_offset"]],
            "faces_right_by_default": presentation["faces_right_by_default"],
            "attack_hit_frame": presentation["attack_hit_frame"], "airborne_speed": float(presentation["airborne_speed"]),
            "move_speed_threshold": float(presentation["move_speed_threshold"]),
            "texture_filter": staging.texture_filter_of(document)[0]}


def attached(document, frames=FRAMES):
    presentation = document.data["presentation"]
    return {"evaluated": True, "carrier": "ant",
            "presentation": {"has_presenter": True, "sprite_frames_path": frames, "frame_has_texture": True,
                             "animation": presentation["roles"]["idle"],
                             "sprite_position": list(presentation["visual_offset"]),
                             "presenter_scale": list(presentation["visual_scale"]),
                             "texture_filter": staging.texture_filter_of(document)[0]},
            "server": {"has_presenter": False}}


def stage_data(document):
    return {"monster_id": document.data["monster_id"], "sprite_frames_path": FRAMES, "profile_path": PROFILE,
            "profile": readback(document), "attach": attached(document)}


def with_art(project, document):
    """Put the document's real images into the stand-in project, where a stage expects to find them."""
    for row in document.data["assets"]["images"]:
        target = project / row["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PROJECT / row["path"], target)
    return project


def copies(folder):
    return [path for path in folder.iterdir() if path.name.startswith(staging.STAGING_PREFIX)]


@pytest.fixture
def staged(fake, tmp_path, beetle):
    """``(godot, project, set_mode, work)`` with the beetle's art in the project and a work folder."""
    godot, project, set_mode = fake
    with_art(project, beetle)
    work = tmp_path / "work"
    work.mkdir()
    set_mode("ok", data=json.dumps(stage_data(beetle)), touch=OUTPUTS)
    yield godot, project, set_mode, work
    for session in list(staging._sessions.values()):             # nothing a test kept may outlive it
        try:
            session.remove()
        except BridgeError:
            staging._sessions.pop(session.id, None)


def junction(link, target):
    """Make a directory junction (Windows needs no privilege for one). False when it cannot be made."""
    if os.name != "nt":
        return False
    done = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True)
    return done.returncode == 0 and link.exists()


def symlink(link, target, directory=False):
    try:
        os.symlink(target, link, target_is_directory=directory)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symbolic links are not available: {error}")


# ------------------------------------------------------------------------------------------------- request
def test_the_request_carries_only_what_the_engine_needs(beetle, frog):
    request = staging.stage_request(beetle, carrier="ant", session_id="abc")
    data = beetle.data
    assert request["carrier"] == "ant" and set(request) >= {"images", "clips", "presentation", "carrier"}
    assert request["staging_session"] == "abc" and "staging_session" not in staging.stage_request(beetle)
    assert request["images"] == {row["id"]: row["path"] for row in data["assets"]["images"]}
    assert [clip["id"] for clip in request["clips"]] == [clip["id"] for clip in data["animations"]["clips"]]
    first = data["animations"]["clips"][0]["frames"][0]
    assert request["clips"][0]["frames"][0] == {"image": first["image"], "rect": list(first["rect"]), "duration": 1}
    assert request["presentation"]["roles"] == dict(data["presentation"]["roles"])
    json.dumps(request)                                        # plain data, nothing frozen
    for document in (beetle, frog):                            # an imported profile's filter is passed on
        kept = (document.data["source_binding"]["passthrough"] or {}).get("profile_texture_filter")
        assert staging.stage_request(document).get("texture_filter") == kept
    assert "texture_filter" not in staging.stage_request(load("sewer_rat_prototype"))


# ---------------------------------------------------------------------------------------------- comparison
def test_an_exact_readback_has_no_differences(beetle, frog):
    for document in (beetle, frog):
        assert staging.compare(document, readback(document), attached(document)) == []


def change(path, value):
    def apply(profile, _attach):
        target = profile
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
    return apply


@pytest.mark.parametrize("mutate, expected", [
    (change(("errors",), ["idle animation is missing"]), "validation_errors"),
    (change(("animations", "idle", "fps"), 99.0), "clip idle: fps"),
    (change(("animations", "idle", "loop"), False), "clip idle: loop"),
    (change(("animations", "attack", "frames", 2, "duration"), 3.0), "clip attack frame 2: duration"),
    (change(("animations", "attack", "frames", 2, "region"), [0.0, 0.0, 1.0, 1.0]), "clip attack frame 2: region"),
    (change(("animations", "move", "frames", 0, "texture_path"), "res://other.png"), "clip move frame 0: texture"),
    (lambda profile, _attach: profile["animations"]["hurt"]["frames"].pop(), "clip hurt: 2 frames"),
    (lambda profile, _attach: profile["animations"].pop("death"), "clip death: missing"),
    (lambda profile, _attach: profile["animations"].update(extra={"fps": 1.0, "loop": False, "frames": []}),
     "clip extra: unexpected"),
    (change(("roles", "move"), "idle"), "role move"),
    (change(("visual_offset",), [0.0, 0.0]), "visual_offset"),
    (change(("visual_scale",), [2.0, 2.0]), "visual_scale"),
    (change(("attack_hit_frame",), 5), "attack_hit_frame"),
    (change(("faces_right_by_default",), False), "faces_right_by_default"),
    (change(("texture_filter",), 2), "texture_filter: 2 != 1"),
    (change(("texture_filter",), 0), "texture_filter: 0 != 1"),          # "inherit" is not "nearest"
    (lambda _profile, attach: attach["presentation"].update(has_presenter=False), "no animation presenter"),
    (lambda _profile, attach: attach["presentation"].update(frame_has_texture=False), "no texture"),
    (lambda _profile, attach: attach["presentation"].update(sprite_frames_path="res://shipped.tres"), "not the staged"),
    (lambda _profile, attach: attach["presentation"].update(sprite_position=[9, 9]), "sprite position"),
    (lambda _profile, attach: attach["presentation"].update(presenter_scale=[3, 3]), "presenter scale"),
    (lambda _profile, attach: attach["presentation"].update(texture_filter=2), "carrier sprite texture_filter"),
    (lambda _profile, attach: attach["server"].update(has_presenter=True), "server-runtime actor"),
    (lambda _profile, attach: attach.update(evaluated=False, reason="no carrier"), "attach check not run"),
])
def test_every_kind_of_difference_is_reported(beetle, mutate, expected):
    profile, attach = copy.deepcopy(readback(beetle)), copy.deepcopy(attached(beetle))
    mutate(profile, attach)
    lines = staging.compare(beetle, profile, attach)
    assert lines and any(expected in line for line in lines), lines


def test_a_missing_readback_is_a_difference_not_a_crash(beetle):
    assert "no profile readback" in staging.compare(beetle, {"error": "cannot load"})[0]
    assert staging.compare(beetle, None)


def test_a_left_facing_carrier_still_matches_the_scale(beetle):
    attach = attached(beetle)
    scale = beetle.data["presentation"]["visual_scale"]
    attach["presentation"]["presenter_scale"] = [-scale[0], scale[1]]
    assert staging.compare(beetle, readback(beetle), attach) == []


def test_the_texture_filter_comes_from_the_import_or_from_the_profile_default(beetle, frog):
    rat = load("sewer_rat_prototype")
    assert staging.texture_filter_of(rat) == (staging.DEFAULT_TEXTURE_FILTER, "default")
    from rtcmonster import encode
    binding = json.loads(encode(beetle))["source_binding"]
    binding["passthrough"] = dict(binding.get("passthrough") or {})
    for value, expected in ((2, (2, "passthrough")), (0, (0, "passthrough")), (99, (1, "default")), (True, (1, "default")),
                            ("nearest", (1, "default"))):
        binding["passthrough"]["profile_texture_filter"] = value
        assert staging.texture_filter_of(beetle.replace(("source_binding",), binding)) == expected
    # A clone drops the binding, and the filter with it: the new draft gets the profile default.
    from rtcmonster import clone_document
    assert staging.texture_filter_of(clone_document(beetle, "beetle_copy")) == (1, "default")
    linear = beetle.replace(("source_binding",), {**binding, "passthrough": {**binding["passthrough"],
                                                                             "profile_texture_filter": 2}})
    assert staging.compare_texture_filter(linear, readback(linear)) == []
    assert staging.compare_texture_filter(linear, readback(beetle))        # a profile built as nearest


# -------------------------------------------------------------------------------------------- staging copy
def test_the_copy_is_marked_complete_enough_and_outside_the_project(fake, tmp_path):
    _godot, project, _set_mode = fake
    for relative in ("assets/a.png", ".godot/imported/a.ctex", ".git/config", "build/out.exe", "docs/guide.md",
                     "tools/x/__pycache__/x.pyc", "tools/x/build/kept.txt", "tools/x/cache.tmp", "artifacts/big.bin"):
        (project / relative).parent.mkdir(parents=True, exist_ok=True)
        (project / relative).write_text("x", encoding="utf-8")
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)
    root = session.root
    marker = json.loads((root / staging.MARKER).read_text(encoding="utf-8"))
    assert marker["session"] == session.id and marker["source"] == str(project.resolve()) and marker["pid"] == os.getpid()
    assert root.name == "project" and project not in root.parents and session.state == "ready" and session.consistent
    assert (root / "assets/a.png").is_file() and (root / ".godot/imported/a.ctex").is_file()
    assert (root / "tools/x/build/kept.txt").is_file()               # only top-level names are left out
    for missing in (".git", "build", "docs", "artifacts", "tools/x/__pycache__", "tools/x/cache.tmp"):
        assert not (root / missing).exists()
    assert session.files == len([path for path in root.rglob("*") if path.is_file()]) - 1      # all but the marker
    assert not (project / staging.MARKER).exists()
    assert session.remove() is True and session.remove() is False        # deleting twice is harmless
    assert not root.exists() and copies(work) == [] and (project / "assets/a.png").is_file()
    assert session.id not in staging._sessions


def test_staging_refuses_unsafe_places(fake, tmp_path):
    _godot, project, _set_mode = fake
    inside = project / "work"
    inside.mkdir()
    with pytest.raises(BridgeError) as caught:
        staging.make_staging_copy(project, inside)
    assert caught.value.code == staging.STAGING_INSIDE_PROJECT and list(inside.iterdir()) == []
    with pytest.raises(BridgeError) as caught:
        staging.make_staging_copy(project, project)
    assert caught.value.code == staging.STAGING_INSIDE_PROJECT
    with pytest.raises(BridgeError):
        staging.make_staging_copy(tmp_path / "not-a-project")
    for target in (project, project.parent, tmp_path):
        with pytest.raises(BridgeError) as caught:
            staging.remove_staging_copy(target)                  # the real project and its parents are never deleted
        assert caught.value.code == staging.STAGING_NOT_OWNED and (project / "project.godot").is_file()


@pytest.mark.parametrize("kind", ["file_symlink", "folder_symlink", "junction", "loop"])
def test_a_link_in_the_project_stops_the_copy_before_it_starts(fake, tmp_path, kind):
    _godot, project, _set_mode = fake
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("not part of the project", encoding="utf-8")
    (project / "assets").mkdir()
    link = project / "assets" / "linked"
    if kind == "file_symlink":
        symlink(link, outside / "secret.txt")
    elif kind == "folder_symlink":
        symlink(link, outside, directory=True)
    elif kind == "junction":
        if not junction(link, outside):
            pytest.skip("junctions are a Windows feature")
    else:
        symlink(link, project, directory=True)                   # a link back to the project: an endless tree
    work = tmp_path / "work"
    work.mkdir()
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work)
    assert caught.value.code == staging.STAGING_UNSAFE_SOURCE and "assets/linked" in caught.value.detail
    assert copies(work) == []                                    # nothing was created, nothing was copied
    assert (outside / "secret.txt").read_text(encoding="utf-8") == "not part of the project"


def test_a_link_inside_a_folder_that_is_not_copied_does_not_matter(fake, tmp_path):
    _godot, project, _set_mode = fake
    outside = tmp_path / "outside"
    outside.mkdir()
    (project / "docs").mkdir()
    if not junction(project / "docs" / "elsewhere", outside):
        symlink(project / "docs" / "elsewhere", outside, directory=True)
    session = StagingSession.create(project, tmp_path)
    assert not (session.root / "docs").exists()
    session.remove()


def test_the_copy_has_limits_and_can_be_cancelled(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    for index in range(30):
        (project / f"file_{index}.bin").write_bytes(b"x" * 1000)
    work = tmp_path / "work"
    work.mkdir()
    monkeypatch.setattr(staging, "MAX_FILES", 10)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work)
    assert caught.value.code == staging.STAGING_TOO_LARGE and copies(work) == []
    monkeypatch.setattr(staging, "MAX_FILES", 1000)
    monkeypatch.setattr(staging, "MAX_BYTES", 5000)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work)
    assert caught.value.code == staging.STAGING_TOO_LARGE and copies(work) == []
    monkeypatch.setattr(staging, "MAX_BYTES", 10 ** 9)
    monkeypatch.setattr(staging.shutil, "disk_usage", lambda _path: shutil._ntuple_diskusage(10 ** 9, 10 ** 9, 1000))
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work)
    assert caught.value.code == staging.STAGING_TOO_LARGE and "free space" in caught.value.detail and copies(work) == []
    monkeypatch.undo()

    cancel = threading.Event()
    copied = []
    real = shutil.copyfile

    def slow(source, target, **options):
        copied.append(source)
        if len(copied) == 5:
            cancel.set()                                         # the user cancels while files are being copied
        return real(source, target, **options)
    monkeypatch.setattr(staging.shutil, "copyfile", slow)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, work, cancel)
    assert caught.value.code == client.CANCELLED and len(copied) == 5 and copies(work) == []


def test_a_file_that_cannot_be_copied_fails_the_stage_and_leaves_nothing(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    (project / "assets").mkdir()
    (project / "assets/a.png").write_bytes(b"x")
    real = shutil.copyfile

    def failing(source, target, **options):
        if str(source).endswith("a.png"):
            raise PermissionError("locked by another program")
        return real(source, target, **options)
    monkeypatch.setattr(staging.shutil, "copyfile", failing)
    with pytest.raises(BridgeError) as caught:
        StagingSession.create(project, tmp_path)
    assert caught.value.code == staging.STAGE_FAILED and "assets/a.png" in caught.value.detail
    assert copies(tmp_path) == []


def test_a_source_file_that_changes_during_the_copy_is_noticed(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    (project / "data.tres").write_text("before", encoding="utf-8")
    real = shutil.copyfile

    def racing(source, target, **options):
        done = real(source, target, **options)
        if str(source).endswith("data.tres"):
            (project / "data.tres").write_text("after, and longer", encoding="utf-8")     # another program saves it
        return done
    monkeypatch.setattr(staging.shutil, "copyfile", racing)
    session = StagingSession.create(project, tmp_path)
    assert not session.consistent and session.changed_during_copy == ("data.tres",)
    assert session.describe()["changed_during_copy"] == ["data.tres"]
    session.remove()


# ------------------------------------------------------------------------------------- ownership and removal
def test_only_the_session_that_made_a_copy_can_delete_it(fake, tmp_path):
    _godot, project, _set_mode = fake
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)

    # A folder that merely looks like a staging copy, with a copied marker, is nobody's to delete.
    forged = work / (staging.STAGING_PREFIX + "forged") / "project"
    forged.mkdir(parents=True)
    shutil.copyfile(session.root / staging.MARKER, forged / staging.MARKER)
    (forged / "precious.txt").write_text("keep me", encoding="utf-8")
    with pytest.raises(BridgeError) as caught:
        staging.remove_staging_copy(forged)
    assert caught.value.code == staging.STAGING_NOT_OWNED and (forged / "precious.txt").is_file()

    # Another session's marker in our folder: refuse.
    other = StagingSession.create(project, work)
    shutil.copyfile(other.root / staging.MARKER, session.root / staging.MARKER)
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_NOT_OWNED and "another staging session" in caught.value.detail
    assert session.root.is_dir() and session.state == "ready"

    # No marker at all: refuse.
    (session.root / staging.MARKER).unlink()
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_NOT_OWNED and session.root.is_dir()

    # A damaged marker: refuse.
    (session.root / staging.MARKER).write_text("{ not json", encoding="utf-8")
    with pytest.raises(BridgeError):
        session.remove()
    session._write_marker()
    assert session.remove() and other.remove()
    shutil.rmtree(forged.parent)


def test_a_session_pointed_at_the_wrong_place_deletes_nothing(fake, tmp_path):
    _godot, project, _set_mode = fake
    work = tmp_path / "work"
    work.mkdir()
    session = StagingSession.create(project, work)
    real_parent, real_root = session.parent, session.root
    victim = tmp_path / "victim"
    (victim / "project").mkdir(parents=True)
    shutil.copyfile(real_root / staging.MARKER, victim / "project" / staging.MARKER)
    (victim / "keep.txt").write_text("keep", encoding="utf-8")
    for parent, reason in ((victim, "shape of a staging folder"), (project.parent, "shape of a staging folder")):
        session.parent, session.root = parent, parent / "project"
        with pytest.raises(BridgeError) as caught:
            session.remove()
        assert caught.value.code == staging.STAGING_NOT_OWNED and reason in caught.value.detail
    assert (victim / "keep.txt").is_file() and (project / "project.godot").is_file()

    # The folder is swapped for a link to somewhere else after it was created.
    session.parent, session.root = real_parent, real_root
    moved = work / "moved-away"
    real_parent.rename(moved)
    if junction(real_parent, victim) or _symlinked(real_parent, victim):
        with pytest.raises(BridgeError) as caught:
            session.remove()
        assert caught.value.code == staging.STAGING_NOT_OWNED and "link" in caught.value.detail
        assert (victim / "keep.txt").is_file()
        os.rmdir(real_parent) if os.name == "nt" else os.unlink(real_parent)
    moved.rename(real_parent)
    assert session.remove()


def _symlinked(link, target):
    try:
        os.symlink(target, link, target_is_directory=True)
        return True
    except (OSError, NotImplementedError):
        return False


def test_a_copy_that_cannot_be_deleted_is_reported_and_can_be_retried(fake, tmp_path, monkeypatch):
    _godot, project, _set_mode = fake
    session = StagingSession.create(project, tmp_path)
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    attempts = []
    real = staging._delete_tree

    def locked(path):
        attempts.append(path)
        return [(str(session.root / "project.godot"), PermissionError("in use by another process"))]
    monkeypatch.setattr(staging, "_delete_tree", locked)
    with pytest.raises(BridgeError) as caught:
        session.remove()
    assert caught.value.code == staging.STAGING_CLEANUP_FAILED and len(attempts) == staging.CLEANUP_ATTEMPTS
    assert str(session.parent) in caught.value.detail and "in use by another process" in caught.value.detail
    assert "real project is not affected" in caught.value.detail
    assert session.state == "leftover" and session in staging.leftovers() and session.root.is_dir()
    monkeypatch.setattr(staging, "_delete_tree", real)          # the lock is gone
    assert session.remove() and session not in staging.leftovers() and not session.parent.exists()


def test_copies_left_by_another_run_are_listed_not_deleted(fake, tmp_path):
    _godot, project, _set_mode = fake
    work = tmp_path / "work"
    work.mkdir()
    mine = StagingSession.create(project, work)
    theirs = work / (staging.STAGING_PREFIX + "crashed") / "project"
    theirs.mkdir(parents=True)
    (theirs / staging.MARKER).write_text(json.dumps({"session": "feedface", "created": "2026-01-01T00:00:00+00:00",
                                                     "source": "D:/somewhere", "pid": 4242}), encoding="utf-8")
    broken = work / (staging.STAGING_PREFIX + "nomarker")
    broken.mkdir()
    found = {row["path"]: row for row in staging.find_stale_copies(work)}
    assert set(found) == {str(theirs.parent), str(broken)}                 # this process's own copy is not "stale"
    assert found[str(theirs.parent)]["session"] == "feedface" and found[str(theirs.parent)]["pid"] == 4242
    assert found[str(broken)]["session"] == "(no readable marker)"
    assert theirs.is_dir() and broken.is_dir()                             # listing deletes nothing
    mine.remove()
    assert staging.find_stale_copies(tmp_path / "absent") == []


def test_a_session_used_as_a_context_cleans_up_even_when_the_body_fails(fake, tmp_path):
    _godot, project, _set_mode = fake
    with pytest.raises(KeyError):
        with StagingSession.create(project, tmp_path) as session:
            root = session.root
            assert root.is_dir()
            raise KeyError("an unexpected bug in the caller")
    assert not root.exists() and copies(tmp_path) == []
    with StagingSession.create(project, tmp_path) as session:
        kept = session.keep()
    assert kept.is_dir() and session.state == "kept" and session in staging.leftovers()
    session.remove()


# ------------------------------------------------------------------------------------------------ the run
def test_a_stage_runs_in_the_copy_and_never_in_the_project(staged, tmp_path, beetle):
    godot, project, set_mode, work = staged
    echo = tmp_path / "echo.json"
    set_mode("ok", echo=echo)
    result = staging.stage_presentation(godot, project, beetle, work, carrier="ant")
    sent = json.loads(echo.read_text(encoding="utf-8"))                    # the last call: read_stage
    assert result.passed and result.differences == () and result.attempts == 1 and result.cleanup_error == ""
    assert sent["request"]["operation"] == "read_stage" and sent["request"]["monster_id"] == "sewer_beetle"
    assert sent["request"]["stage"] == {"staging_session": result.session.id}
    assert sent["project"] == str(result.staging_root) != str(project)
    assert copies(work) == [] and result.session.state == "removed" and not result.kept       # removed before returning
    assert not (project / "monster_stage").exists() and not (project / staging.MARKER).exists()
    assert result.document_fingerprint == beetle.fingerprint and result.is_current(beetle)
    assert not result.is_current(beetle.apply(set_value(("presentation", "visual_offset"), [1, 2])))
    assert result.project_fingerprint == staging.source_fingerprint(project, beetle)
    assert set(result.resources) == {FRAMES, PROFILE} and all(len(value) == 64 for value in result.resources.values())
    assert result.godot_version.startswith("4.7.2")
    assert result.areas == {"staging": "PASS", "resources": "PASS", "readback": "PASS", "images": "PASS",
                            "attach": "PASS", "rendering": "NOT_EVALUATED", "combat_runtime": "NOT_EVALUATED",
                            "network": "NOT_EVALUATED", "publish": "NOT_EVALUATED"}
    assert result.process == {"attempts": {"import": 1, "stage_monster": 1, "read_stage": 1}, "crash_exit_codes": []}


def test_the_caller_can_keep_the_copy_and_then_owns_it(staged, beetle):
    godot, project, _set_mode, work = staged
    result = staging.stage_presentation(godot, project, beetle, work, keep=True)
    assert result.kept and result.staging_root.is_dir() and result.session.state == "kept"
    assert (result.staging_root / FRAMES.removeprefix("res://")).is_file()
    assert result.session.remove() and copies(work) == []


def test_a_stage_that_differs_is_a_result_with_differences(staged, beetle):
    godot, project, set_mode, work = staged
    data = stage_data(beetle)
    data["profile"]["animations"]["idle"]["fps"] = 1.0
    set_mode("ok", data=json.dumps(data))
    result = staging.stage_presentation(godot, project, beetle, work)
    assert not result.passed and "clip idle: fps" in result.differences[0] and result.areas["resources"] == "FAIL"
    assert copies(work) == []


def test_the_readback_must_come_from_disk_and_match(staged, beetle):
    godot, project, set_mode, work = staged
    other = readback(beetle)
    other["visual_offset"] = [5.0, 5.0]                                  # the file on disk says something else
    set_mode("ok", read_profile=json.dumps(other))
    result = staging.stage_presentation(godot, project, beetle, work)
    assert not result.passed and result.areas["readback"] == "FAIL"
    assert any("readback from disk differs" in line and "visual_offset" in line for line in result.differences)
    set_mode("ok", read_profile="", read_resources=json.dumps({FRAMES: "0" * 64, PROFILE: "1" * 64}))
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work)
    assert caught.value.code == client.INVALID_RESPONSE and "hashes" in caught.value.detail and copies(work) == []


def test_an_image_that_is_not_the_one_the_document_recorded_is_a_difference(staged, beetle):
    godot, project, _set_mode, work = staged
    row = beetle.data["assets"]["images"][0]
    payload = bytearray((project / row["path"]).read_bytes())
    payload[-20] ^= 0xFF                                                 # same size, other pixels
    (project / row["path"]).write_bytes(bytes(payload))
    result = staging.stage_presentation(godot, project, beetle, work)
    assert not result.passed and result.areas["images"] == "FAIL" and result.areas["resources"] == "PASS"
    assert any(f"image {row['id']}" in line and "refresh the image" in line for line in result.differences)
    assert result.project_fingerprint != staging.source_fingerprint(PROJECT, beetle)
    unrecorded = beetle.apply(set_value(("assets", "images", 0, "sha256"), ""))
    result = staging.stage_presentation(godot, project, unrecorded, work)
    assert result.passed and result.areas["images"] == "WARNING" and "no content hash" in result.notes[0]


@pytest.mark.parametrize("mode, extra, code, copied", [
    ("fail", {}, "UNKNOWN_MONSTER", True),
    ("crash", {}, client.PROCESS_CRASH, True),
    ("ok", {"import_exit": 1}, staging.STAGE_FAILED, True),
    # An access-violation exit code only survives on Windows; elsewhere exit() truncates it to a plain failure.
    ("ok", {"import_exit": -1073741819}, client.PROCESS_CRASH if os.name == "nt" else staging.STAGE_FAILED, True),
    ("ok", {"version": "4.6.1.stable"}, client.GODOT_VERSION_MISMATCH, False),
    ("ok", {"mode_read_stage": "fail"}, "UNKNOWN_MONSTER", True),
    ("ok", {"mode_read_stage": "bad_json"}, client.INVALID_RESPONSE, True),
])
def test_a_failed_run_raises_and_says_where_the_copy_is(staged, beetle, mode, extra, code, copied):
    godot, project, set_mode, work = staged
    set_mode(mode, **extra)
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work)
    assert caught.value.code == code and copies(work) == []     # a failed stage leaves nothing behind
    assert not (project / staging.MARKER).exists()
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work, keep_on_failure=True)
    kept = copies(work)
    assert caught.value.code == code
    if copied:                                                   # kept on request, and the error says where
        assert len(kept) == 1 and str(kept[0]) in caught.value.detail and str(kept[0]) in str(caught.value)
        assert [session.parent for session in staging.leftovers()] == [kept[0]]
        staging.remove_staging_copy(kept[0] / "project")
    else:
        assert kept == []                                        # the version is checked before any copy


def broken_response(change_data):
    def build(beetle):
        data = stage_data(beetle)
        change_data(data)
        return data
    return build


@pytest.mark.parametrize("build, code", [
    (broken_response(lambda data: data.pop("profile")), client.INVALID_RESPONSE),
    (broken_response(lambda data: data.update(attach="yes")), client.INVALID_RESPONSE),
    (broken_response(lambda data: data.update(profile_path=7)), client.INVALID_RESPONSE),
    (broken_response(lambda data: data.update(monster_id="frog")), client.RESPONSE_MISMATCH),
    (broken_response(lambda data: data["profile"].pop("roles")), client.INVALID_RESPONSE),
    (broken_response(lambda data: data["profile"].update(visual_scale=[1.0])), client.INVALID_RESPONSE),
    (broken_response(lambda data: data["profile"].update(texture_filter="nearest")), client.INVALID_RESPONSE),
    (broken_response(lambda data: data["profile"]["animations"]["idle"].update(fps="fast")), client.INVALID_RESPONSE),
    (broken_response(lambda data: data["profile"]["animations"]["idle"]["frames"][0].update(region=[0, 0, 1])),
     client.INVALID_RESPONSE),
    (broken_response(lambda data: data["profile"]["animations"]["idle"]["frames"].append("frame")),
     client.INVALID_RESPONSE),
    (broken_response(lambda data: data["profile"].update(sprite_frames_path="res://shipped/frames.tres")),
     client.INVALID_RESPONSE),
    (broken_response(lambda data: data["attach"].pop("evaluated")), client.INVALID_RESPONSE),
    (broken_response(lambda data: data.update(sprite_frames_path="C:/Windows/system.tres")), staging.RESOURCE_PATH_INVALID),
    (broken_response(lambda data: data.update(profile_path="res://monster_stage/sewer_beetle/../../project.godot")),
     staging.RESOURCE_PATH_INVALID),
    (broken_response(lambda data: data.update(profile_path="res://data/content/enemies/sewer_beetle.tres")),
     staging.RESOURCE_PATH_INVALID),
    (broken_response(lambda data: data.update(profile_path="res://monster_stage/sewer_beetle/profile.gd")),
     staging.RESOURCE_PATH_INVALID),
    (broken_response(lambda data: data.update(profile_path="res://monster_stage/sewer_beetle/absent.tres")),
     staging.RESOURCE_PATH_INVALID),
    (broken_response(lambda data: data["profile"]["animations"]["idle"]["frames"][0].update(
        texture_path="res://../outside.png")), staging.RESOURCE_PATH_INVALID),
    (broken_response(lambda data: data["profile"]["animations"]["idle"]["frames"][0].update(
        texture_path="/etc/passwd")), staging.RESOURCE_PATH_INVALID),
])
def test_a_malformed_response_is_refused_with_a_code_and_the_copy_is_removed(staged, beetle, build, code):
    godot, project, set_mode, work = staged
    set_mode("ok", data=json.dumps(build(beetle)))
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work)
    assert caught.value.code == code, caught.value
    assert copies(work) == [] and staging.leftovers() == []


def test_an_answer_from_another_staging_session_is_refused(staged, beetle):
    godot, project, set_mode, work = staged
    for value in ("someone-elses-session", "omit"):
        set_mode("ok", session=value)
        with pytest.raises(BridgeError) as caught:
            staging.stage_presentation(godot, project, beetle, work)
        assert caught.value.code == client.RESPONSE_MISMATCH and copies(work) == []


def test_a_staged_path_may_not_leave_the_copy_through_a_link(fake, tmp_path):
    _godot, project, _set_mode = fake
    session = StagingSession.create(project, tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "frames.tres").write_text("[gd_resource]", encoding="utf-8")
    (session.root / "monster_stage").mkdir()
    link = session.root / "monster_stage" / "beetle"
    if junction(link, outside) or _symlinked(link, outside):
        with pytest.raises(BridgeError) as caught:
            staging.staged_file(session.root, "res://monster_stage/beetle/frames.tres", (".tres",), "monster_stage/beetle")
        assert caught.value.code == staging.RESOURCE_PATH_INVALID and "link" in caught.value.detail
        os.rmdir(link) if os.name == "nt" else os.unlink(link)
    for path in ("monster_stage/x.tres", "res:/monster_stage/x.tres", "res://", "res://a\\b.tres", "res://./a.tres",
                 "res://a//b.tres", None, 5):
        with pytest.raises(BridgeError) as caught:
            staging.staged_file(session.root, path, (".tres",))
        assert caught.value.code == staging.RESOURCE_PATH_INVALID
    session.remove()


def test_an_unexpected_exception_still_removes_the_copy(staged, beetle, monkeypatch):
    godot, project, _set_mode, work = staged
    for failure in (KeyError("missing key in compare"), TypeError("wrong type"), ValueError("bad value"),
                    OSError("disk went away")):
        monkeypatch.setattr(staging, "compare", lambda *_args, failure=failure: (_ for _ in ()).throw(failure))
        with pytest.raises(type(failure)):
            staging.stage_presentation(godot, project, beetle, work)
        assert copies(work) == [] and staging.leftovers() == []
    with pytest.raises(OSError):
        staging.stage_presentation(godot, project, beetle, work, keep_on_failure=True)
    assert len(copies(work)) == 1 and len(staging.leftovers()) == 1          # kept only because it was asked for
    staging.leftovers()[0].remove()


def test_a_cancelled_stage_never_keeps_its_copy(staged, beetle):
    godot, project, set_mode, work = staged
    set_mode("hang", seconds=30)
    cancel = threading.Event()
    threading.Timer(0.6, cancel.set).start()
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, work, cancel=cancel, keep_on_failure=True)
    assert caught.value.code == client.CANCELLED and copies(work) == []


def test_a_crashed_attempt_is_retried_recorded_and_never_passed_off_as_clean(staged, tmp_path, beetle):
    godot, project, set_mode, work = staged
    set_mode("ok", crash_once=tmp_path / "crashed-once")
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and result.attempts == 2
    assert result.process["attempts"] == {"import": 1, "stage_monster": 2, "read_stage": 1}
    assert len(result.process["crash_exit_codes"]) == 1                    # the functional PASS keeps its crash record
    if os.name == "nt":
        assert result.process["crash_exit_codes"][0] & 0xFFFFFFFF == 0xC0000005
    assert copies(work) == []
    response = client.call(godot, project, "inspect_monsters")
    assert response.process_result == "CLEAN" and response.crashes == ()


def test_a_cleanup_failure_after_a_good_stage_is_reported_not_hidden(staged, beetle, monkeypatch):
    godot, project, _set_mode, work = staged
    monkeypatch.setattr(staging, "CLEANUP_PAUSE", 0)
    real = staging._delete_tree
    monkeypatch.setattr(staging, "_delete_tree", lambda path: [(str(path), PermissionError("locked"))])
    result = staging.stage_presentation(godot, project, beetle, work)
    assert result.passed and "was not fully deleted" in result.cleanup_error and "locked" in result.cleanup_error
    assert len(copies(work)) == 1 and result.session in staging.leftovers()
    monkeypatch.setattr(staging, "_delete_tree", real)
    assert result.session.remove() and copies(work) == []


def test_a_document_without_clips_is_refused_before_anything_runs(fake, tmp_path):
    godot, project, set_mode = fake
    set_mode("not_godot")                                          # would fail if the engine were started
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, new_document("empty_one", "Empty"), tmp_path)
    assert caught.value.code == staging.NOTHING_TO_STAGE and copies(tmp_path) == []


def test_only_stage_operations_send_a_stage_payload(fake, tmp_path):
    godot, project, set_mode = fake
    echo = tmp_path / "echo.json"
    set_mode("ok", echo=echo)
    client.call(godot, project, "inspect_monsters", stage={"ignored": True})
    assert "stage" not in json.loads(echo.read_text(encoding="utf-8"))["request"]
    assert set(client.STAGE_OPERATIONS) == {"stage_monster", "read_stage"} <= set(client.OPERATIONS)
