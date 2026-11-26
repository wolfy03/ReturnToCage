"""Staging: the project copy, the request, and the comparison of Godot's readback with the document.

The engine is the stand-in from ``conftest.fake`` - a real child process. What the real engine builds is
checked by ``check_godot_stage.py``; these tests cover everything around it: that the real project is
never the target, that a copy is cleaned up, and that every kind of difference is reported.
"""

import copy
import json

import pytest

from conftest import load
from bridge import client, staging
from bridge.client import BridgeError
from rtcmonster import new_document

FRAMES = "res://monster_stage/sewer_beetle/sprite_frames.tres"
PROFILE = "res://monster_stage/sewer_beetle/animation_profile.tres"
OUTPUTS = json.dumps([FRAMES.removeprefix("res://"), PROFILE.removeprefix("res://")])


def readback(document):
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
    return {"errors": [], "sprite_frames_path": FRAMES, "animations": animations, "roles": dict(presentation["roles"]),
            "visual_scale": [float(value) for value in presentation["visual_scale"]],
            "visual_offset": [float(value) for value in presentation["visual_offset"]],
            "faces_right_by_default": presentation["faces_right_by_default"],
            "attack_hit_frame": presentation["attack_hit_frame"], "airborne_speed": float(presentation["airborne_speed"]),
            "move_speed_threshold": float(presentation["move_speed_threshold"])}


def attached(document):
    presentation = document.data["presentation"]
    return {"evaluated": True, "carrier": "ant",
            "presentation": {"has_presenter": True, "sprite_frames_path": FRAMES, "frame_has_texture": True,
                             "animation": presentation["roles"]["idle"],
                             "sprite_position": list(presentation["visual_offset"]),
                             "presenter_scale": list(presentation["visual_scale"]), "texture_filter": 0},
            "server": {"has_presenter": False}}


def stage_data(document):
    return {"monster_id": document.data["monster_id"], "sprite_frames_path": FRAMES, "profile_path": PROFILE,
            "profile": readback(document), "attach": attached(document)}


def copies(folder):
    return [path for path in folder.iterdir() if path.name.startswith("rtc-monster-stage-")]


# ------------------------------------------------------------------------------------------------- request
def test_the_request_carries_only_what_the_engine_needs(beetle, frog):
    request = staging.stage_request(beetle, carrier="ant")
    data = beetle.data
    assert request["carrier"] == "ant" and set(request) >= {"images", "clips", "presentation", "carrier"}
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
    (lambda _profile, attach: attach["presentation"].update(has_presenter=False), "no animation presenter"),
    (lambda _profile, attach: attach["presentation"].update(frame_has_texture=False), "no texture"),
    (lambda _profile, attach: attach["presentation"].update(sprite_frames_path="res://shipped.tres"), "not the staged"),
    (lambda _profile, attach: attach["presentation"].update(sprite_position=[9, 9]), "sprite position"),
    (lambda _profile, attach: attach["presentation"].update(presenter_scale=[3, 3]), "presenter scale"),
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


# -------------------------------------------------------------------------------------------- staging copy
def test_the_copy_is_marked_complete_enough_and_outside_the_project(fake, tmp_path):
    _godot, project, _set_mode = fake
    for relative in ("assets/a.png", ".godot/imported/a.ctex", ".git/config", "build/out.exe", "docs/guide.md",
                     "tools/x/__pycache__/x.pyc", "tools/x/build/kept.txt"):
        (project / relative).parent.mkdir(parents=True, exist_ok=True)
        (project / relative).write_text("x", encoding="utf-8")
    work = tmp_path / "work"
    work.mkdir()
    root = staging.make_staging_copy(project, work)
    assert (root / staging.MARKER).is_file() and root.name == "project" and project not in root.parents
    assert (root / "assets/a.png").is_file() and (root / ".godot/imported/a.ctex").is_file()
    assert (root / "tools/x/build/kept.txt").is_file()               # only top-level names are left out
    for missing in (".git", "build", "docs", "tools/x/__pycache__"):
        assert not (root / missing).exists()
    assert not (project / staging.MARKER).exists()
    staging.remove_staging_copy(root)
    assert not root.exists() and copies(work) == [] and (project / "assets/a.png").is_file()


def test_staging_refuses_unsafe_places(fake, tmp_path):
    _godot, project, _set_mode = fake
    inside = project / "work"
    inside.mkdir()
    with pytest.raises(BridgeError) as caught:
        staging.make_staging_copy(project, inside)
    assert caught.value.code == staging.STAGING_INSIDE_PROJECT and list(inside.iterdir()) == []
    with pytest.raises(BridgeError):
        staging.make_staging_copy(tmp_path / "not-a-project")
    with pytest.raises(BridgeError) as caught:
        staging.remove_staging_copy(project)                     # the real project is never deleted
    assert caught.value.code == staging.STAGE_FAILED and (project / "project.godot").is_file()


# ------------------------------------------------------------------------------------------------ the run
def test_a_stage_runs_in_the_copy_and_never_in_the_project(fake, tmp_path, beetle):
    godot, project, set_mode = fake
    echo = tmp_path / "echo.json"
    set_mode("ok", data=json.dumps(stage_data(beetle)), echo=echo, touch=OUTPUTS)
    result = staging.stage_presentation(godot, project, beetle, tmp_path, carrier="ant")
    sent = json.loads(echo.read_text(encoding="utf-8"))
    assert result.passed and result.differences == () and result.attempts == 1
    assert sent["request"]["operation"] == "stage_monster" and sent["request"]["monster_id"] == "sewer_beetle"
    assert sent["request"]["stage"]["carrier"] == "ant" and len(sent["request"]["stage"]["clips"]) == 5
    assert sent["project"] == str(result.staging_root) != str(project)
    assert (result.staging_root / staging.MARKER).is_file()
    assert not (project / "monster_stage").exists() and not (project / staging.MARKER).exists()
    staging.remove_staging_copy(result.staging_root)


def test_a_stage_that_differs_is_a_result_with_differences(fake, tmp_path, beetle):
    godot, project, set_mode = fake
    data = stage_data(beetle)
    data["profile"]["animations"]["idle"]["fps"] = 1.0
    set_mode("ok", data=json.dumps(data), touch=OUTPUTS)
    result = staging.stage_presentation(godot, project, beetle, tmp_path)
    assert not result.passed and "clip idle: fps" in result.differences[0]
    staging.remove_staging_copy(result.staging_root)


@pytest.mark.parametrize("mode, extra, code, copied", [
    ("fail", {}, "UNKNOWN_MONSTER", True),
    ("crash", {}, client.PROCESS_CRASH, True),
    ("ok", {"import_exit": 1}, staging.STAGE_FAILED, True),
    ("ok", {"import_exit": -1073741819}, client.PROCESS_CRASH, True),
    ("ok", {"version": "4.6.1.stable"}, client.GODOT_VERSION_MISMATCH, False),
])
def test_a_failed_run_raises_and_says_where_the_copy_is(fake, tmp_path, beetle, mode, extra, code, copied):
    godot, project, set_mode = fake
    work = tmp_path / "work"
    work.mkdir()
    set_mode(mode, data=json.dumps(stage_data(beetle)), **extra)
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
        staging.remove_staging_copy(kept[0] / "project")
    else:
        assert kept == []                                        # the version is checked before any copy


def test_a_response_naming_files_that_do_not_exist_is_refused(fake, tmp_path, beetle):
    godot, project, set_mode = fake
    set_mode("ok", data=json.dumps(stage_data(beetle)))            # nothing is written
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, beetle, tmp_path)
    assert caught.value.code == staging.STAGE_FAILED and copies(tmp_path) == []


def test_a_document_without_clips_is_refused_before_anything_runs(fake, tmp_path):
    godot, project, set_mode = fake
    set_mode("not_godot")                                          # would fail if the engine were started
    with pytest.raises(BridgeError) as caught:
        staging.stage_presentation(godot, project, new_document("empty_one", "Empty"), tmp_path)
    assert caught.value.code == staging.NOTHING_TO_STAGE and copies(tmp_path) == []


def test_the_read_operations_send_no_stage_payload(fake, tmp_path):
    godot, project, set_mode = fake
    echo = tmp_path / "echo.json"
    set_mode("ok", echo=echo)
    client.call(godot, project, "inspect_monsters", stage={"ignored": True})
    assert "stage" not in json.loads(echo.read_text(encoding="utf-8"))["request"]
    assert "stage_monster" in client.OPERATIONS
