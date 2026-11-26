"""The expected side of the render check: where a frame must be drawn, which clip a role shows, and whether
recorded playback obeys the document's timing. The real renderer is exercised by ``check_godot_render.py``;
here the engine's answer is written by hand, so every kind of disagreement can be produced on purpose.
"""

import json

import pytest

from conftest import PROJECT
from bridge import client, rendering, staging
from bridge.client import BridgeError
from rtcmonster import set_value
from rtcmonster.geometry import sprite_to_actor
from rtcmonster.timing import clip_seconds, frame_seconds

SIZE, ZOOM = (320, 240), 3


def shot_answer(document, shot):
    """What the scene reports for a correctly drawn shot."""
    clip = rendering.clip_of(document, shot["clip"])
    frame = clip["frames"][shot["frame"]]
    image = next(row for row in document.data["assets"]["images"] if row["id"] == frame["image"])
    rect = list(frame["rect"]) if frame["rect"] is not None else [0, 0, image["width"], image["height"]]
    return {**shot, "saved": True, "image": shot["name"] + ".png", "frame_size": rect[2:],
            "corners": rendering.expected_corners(document, shot["clip"], shot["frame"], shot["facing"], SIZE, ZOOM),
            "region": [float(value) for value in rect], "texture_path": "res://" + image["path"]}


def answer(document):
    shots = rendering.default_shots(document)
    return {"size": list(SIZE), "zoom": ZOOM, "shots": [shot_answer(document, shot) for shot in shots]}


def test_default_shots_cover_both_facings_of_two_frames_per_clip(beetle, frog):
    for document in (beetle, frog):
        shots = rendering.default_shots(document)
        clips = document.data["animations"]["clips"]
        assert len(shots) == sum(2 * len({0, len(clip["frames"]) // 2}) for clip in clips)
        assert {shot["facing"] for shot in shots} == {1, -1} and len({shot["name"] for shot in shots}) == len(shots)
        assert all(0 <= shot["frame"] < len(rendering.clip_of(document, shot["clip"])["frames"]) for shot in shots)
    with_shapes = rendering.default_shots(beetle, lambda clip, frame: [{"kind": "body", "id": "body", "shape": {}}])
    assert all(len(shot["shapes"]) == 1 for shot in with_shapes)
    timings = rendering.default_timings(frog)
    assert [row["clip"] for row in timings] == [clip["id"] for clip in frog.data["animations"]["clips"]]
    assert all(0 < row["seconds"] <= 3.0 for row in timings)


def test_expected_corners_are_the_geometry_modules(beetle):
    presentation = beetle.data["presentation"]
    clip = beetle.data["animations"]["clips"][0]
    width, height = clip["frames"][0]["rect"][2:]
    right = rendering.expected_corners(beetle, clip["id"], 0, 1, SIZE, ZOOM)
    left = rendering.expected_corners(beetle, clip["id"], 0, -1, SIZE, ZOOM)
    top_left = sprite_to_actor([0, 0], (width, height), presentation, 1)
    assert right[0] == [SIZE[0] / 2 + top_left[0] * ZOOM, SIZE[1] / 2 + top_left[1] * ZOOM]
    assert right[1][0] - right[0][0] == pytest.approx(width * presentation["visual_scale"][0] * ZOOM)
    assert right[3][1] - right[0][1] == pytest.approx(height * presentation["visual_scale"][1] * ZOOM)
    # Facing left mirrors the frame about the actor origin: its "left" corners are now on the right.
    assert left[0][0] == pytest.approx(SIZE[0] - right[0][0]) and left[1][0] < left[0][0]
    assert [corner[1] for corner in left] == [corner[1] for corner in right]
    shifted = beetle.apply(set_value(("presentation", "visual_offset"), [5, -2]),
                           set_value(("presentation", "visual_scale"), [2, 2]))
    moved = rendering.expected_corners(shifted, clip["id"], 0, 1, SIZE, ZOOM)
    assert moved[1][0] - moved[0][0] == pytest.approx(width * 2 * ZOOM)
    turned = beetle.apply(set_value(("presentation", "faces_right_by_default"), False))
    assert rendering.expected_corners(turned, clip["id"], 0, 1, SIZE, ZOOM) == left      # art that faces left


def test_a_correct_answer_has_no_geometry_differences(beetle, frog):
    for document in (beetle, frog):
        assert rendering.compare_geometry(document, answer(document)) == []


@pytest.mark.parametrize("change, expected", [
    (lambda shot: shot["corners"][0].__setitem__(0, shot["corners"][0][0] + 1), "off by 1.000 px"),
    (lambda shot: shot.update(corners=[shot["corners"][1], shot["corners"][0], shot["corners"][3], shot["corners"][2]]),
     "the document places it"),                                           # drawn mirrored
    (lambda shot: shot["region"].__setitem__(0, shot["region"][0] + 64), "drawn from"),
    (lambda shot: shot.update(texture_path="res://assets/other.png"), "drawn from"),
    (lambda shot: shot.update(saved=False), "not saved"),
    (lambda shot: shot.update(error="the staged SpriteFrames has no such clip or frame"), "no such clip"),
])
def test_every_kind_of_misplacement_is_reported(beetle, change, expected):
    data = answer(beetle)
    change(data["shots"][2])
    lines = rendering.compare_geometry(beetle, data)
    assert len(lines) == 1 and expected in lines[0] and data["shots"][2]["name"] in lines[0]


def test_roles_are_compared_with_what_the_presenter_falls_back_to(beetle, frog):
    beetle_roles = {"idle": "idle", "move": "move", "attack": "attack", "hurt": "hurt", "death": "death",
                    "jump": "idle", "fall": "idle"}
    assert rendering.compare_roles(beetle, beetle_roles) == ([], [])       # no airborne clips: grounded fallback
    roles = frog.data["presentation"]["roles"]
    picked = {role: roles[role] for role in rendering.FORCED_ROLES}
    lines, unforced = rendering.compare_roles(frog, picked)
    assert lines == [] and unforced == [role for role in ("jump_start", "land") if roles[role]] and unforced
    picked["attack"] = roles["idle"]
    lines, _unforced = rendering.compare_roles(frog, picked)
    assert lines == [f"role attack: the presenter shows {roles['idle']!r}, the document binds {roles['attack']!r}"]
    assert rendering.compare_roles(frog, {}) == ([], unforced)             # nothing reported, nothing to compare


def test_the_filter_is_compared_in_the_profile_and_on_the_sprite(beetle):
    assert rendering.compare_filter(beetle, {"texture_filter": 1, "profile_texture_filter": 1}) == []
    lines = rendering.compare_filter(beetle, {"texture_filter": 2, "profile_texture_filter": 1})
    assert lines == ["texture_filter: 2 != 1 (default)"]
    assert len(rendering.compare_filter(beetle, {})) == 2


def samples_for(clip, step, seconds, loop=None):
    """Samples as a real AnimatedSprite2D would produce them: advanced by ``step`` each rendered frame."""
    from rtcmonster.timing import frame_at
    rows, elapsed = [], 0.0
    while elapsed < seconds:
        elapsed += step
        ended = not clip["loop"] and elapsed >= clip_seconds(clip)
        rows.append([elapsed, frame_at(clip, elapsed), not ended])
    return {"clip": clip["id"], "samples": rows, "largest_delta": step, "loop": clip["loop"] if loop is None else loop}


def test_recorded_playback_that_follows_the_document_passes(beetle, frog):
    for document in (beetle, frog):
        for clip in document.data["animations"]["clips"]:
            for step in (1 / 60, 1 / 30, 1 / 144, 0.05):
                row = samples_for(clip, step, clip_seconds(clip) * 1.7 + 0.1)
                assert rendering.compare_timing(document, [row]) == [], (clip["id"], step)


def test_playback_that_breaks_the_timing_rule_is_reported(beetle):
    clip = next(clip for clip in beetle.data["animations"]["clips"] if not clip["loop"] and len(clip["frames"]) >= 3)
    looping = next(clip for clip in beetle.data["animations"]["clips"] if clip["loop"])
    step = 1 / 60
    good = samples_for(clip, step, clip_seconds(clip) + 0.2)

    slow = json.loads(json.dumps(good))                                  # every frame shown twice as long
    for sample in slow["samples"]:
        sample[1] = min(sample[1], int(sample[0] / (frame_seconds(clip)[0] * 2)))
    assert "samples show a frame the document's timing does not allow" in rendering.compare_timing(beetle, [slow])[0]

    restarted = json.loads(json.dumps(good))                             # a one-shot clip that wrapped around
    restarted["samples"][-1][1:] = [0, True]
    lines = rendering.compare_timing(beetle, [restarted])
    assert any("must hold its last frame and stop" in line for line in lines)

    wrong_flag = samples_for(looping, step, 0.3, loop=False)
    assert any("loop flag" in line for line in rendering.compare_timing(beetle, [wrong_flag]))
    stopped = samples_for(looping, step, clip_seconds(looping) * 1.5)
    stopped["samples"][-1][2] = False
    assert any("a looping clip stopped" in line for line in rendering.compare_timing(beetle, [stopped]))
    assert "no samples" in rendering.compare_timing(beetle, [{**good, "samples": []}])[0]
    assert "not a clip" in rendering.compare_timing(beetle, [{"clip": "absent", "samples": []}])[0]
    assert "no such clip" in rendering.compare_timing(beetle, [{"clip": clip["id"], "error": "no such clip"}])[0]


# ------------------------------------------------------------------------------------- the run (stand-in engine)
def render_data(document, session_id):
    data = answer(document)
    data.update(monster_id=document.data["monster_id"], staging_session=session_id, carrier="sewer_beetle",
                texture_filter=1, profile_texture_filter=1, timings=[],
                role_selection={"idle": "idle", "move": "move", "attack": "attack", "hurt": "hurt", "death": "death",
                                "jump": "idle", "fall": "idle"})
    return data


@pytest.fixture
def rendered(fake, tmp_path, beetle, monkeypatch):
    """A staging session of the stand-in project, and a way to choose what the render check answers."""
    godot, project, set_mode = fake
    session = staging.StagingSession.create(project, tmp_path)
    output = tmp_path / "shots"

    def respond(change=None, renderer=None, **modes):
        data = render_data(beetle, session.id)
        output.mkdir(exist_ok=True)
        for shot in data["shots"]:
            (output / shot["image"]).write_bytes(b"png")
        if change is not None:
            change(data)
        monkeypatch.setenv("RTC_FAKE_RENDER", json.dumps({
            "data": data, "renderer": renderer or {"display_server": "Windows", "rendering_method": "forward_plus",
                                                   "rendering_driver": "d3d12", "video_adapter": "test"}}))
        set_mode(modes.pop("mode", "ok"), **modes)
    yield godot, session, output, respond
    session.remove()


def test_a_render_run_is_checked_like_every_other_bridge_answer(rendered, beetle, tmp_path):
    godot, session, output, respond = rendered
    echo = tmp_path / "echo.json"
    respond(echo=echo)
    result = rendering.render_staged(godot, session, beetle, output, carrier="sewer_beetle", size=SIZE, zoom=ZOOM)
    sent = json.loads(echo.read_text(encoding="utf-8"))
    assert result.passed and result.renderer["rendering_method"] == "forward_plus" and result.output_dir == output.resolve()
    assert sent["request"]["staging_session"] == session.id and sent["request"]["output_dir"] == str(output.resolve())
    assert "--headless" not in sent["arguments"] and sent["project"] == str(session.root)     # a real window
    assert len(sent["request"]["shots"]) == 20 and sent["request"]["size"] == list(SIZE)
    rendering.render_staged(godot, session, beetle, output, size=SIZE, zoom=ZOOM, rendering_method="gl_compatibility")
    sent = json.loads(echo.read_text(encoding="utf-8"))
    assert sent["arguments"][sent["arguments"].index("--rendering-method") + 1] == "gl_compatibility"


@pytest.mark.parametrize("change, renderer, modes, code", [
    (None, {"display_server": "headless"}, {}, rendering.NO_RENDERER),
    (lambda data: data.update(staging_session="another"), None, {}, client.INVALID_RESPONSE),
    (lambda data: data.update(monster_id="frog"), None, {}, client.INVALID_RESPONSE),
    (lambda data: data.update(shots="none"), None, {}, client.INVALID_RESPONSE),
    (lambda data: data["shots"][0].pop("corners"), None, {}, client.INVALID_RESPONSE),
    (lambda data: data["shots"][0].update(image="../../escape.png"), None, {}, client.INVALID_RESPONSE),
    (lambda data: data["shots"][0].update(image="never_written.png"), None, {}, client.INVALID_RESPONSE),
    (None, None, {"mode": "crash"}, client.PROCESS_CRASH),
    (None, None, {"mode": "script_error"}, client.ENGINE_ERROR),
    (None, None, {"mode": "wrong_request"}, client.RESPONSE_MISMATCH),
    (None, None, {"mode": "wrong_project"}, client.RESPONSE_MISMATCH),
    (None, None, {"mode": "no_result"}, client.INVALID_RESPONSE),
    (None, None, {"mode": "fail"}, "UNKNOWN_MONSTER"),
])
def test_a_render_answer_that_cannot_be_trusted_is_refused(rendered, beetle, change, renderer, modes, code):
    godot, session, output, respond = rendered
    respond(change, renderer, **modes)
    with pytest.raises(BridgeError) as caught:
        rendering.render_staged(godot, session, beetle, output, size=SIZE, zoom=ZOOM)
    assert caught.value.code == code, caught.value


def test_a_render_run_reports_differences_as_a_result(rendered, beetle):
    godot, session, output, respond = rendered
    respond(lambda data: (data["shots"][1]["corners"][0].__setitem__(1, 0.0), data.update(texture_filter=2)))
    result = rendering.render_staged(godot, session, beetle, output, size=SIZE, zoom=ZOOM)
    assert not result.passed and len(result.differences) == 2
    assert "off by" in result.differences[0] and "texture_filter: 2 != 1" in result.differences[1]


# ----------------------------------------------------------------------------------- image comparison (Qt)
def test_images_are_compared_by_box_coverage_and_colour(app):
    from PySide6.QtCore import QRect, Qt
    from PySide6.QtGui import QColor, QImage, QPainter
    from gui import render_compare

    def picture(rect, colour="#40a040", extra=None):
        image = QImage(64, 48, QImage.Format.Format_ARGB32)
        image.fill(Qt.GlobalColor.transparent)
        painter = QPainter(image)
        painter.fillRect(QRect(*rect), QColor(colour))
        if extra:
            painter.fillRect(QRect(*extra[0]), QColor(*extra[1]))
        painter.end()
        return image
    base = picture((10, 8, 20, 16))
    same = render_compare.compare_images(base, picture((10, 8, 20, 16)))
    assert same["identical"] and same["preview_box"] == same["rendered_box"] == [10, 8, 30, 24]
    assert same["opaque_in_both"] == 320 and same["colour_differs"] == 0
    moved = render_compare.compare_images(base, picture((11, 8, 20, 16)))
    assert not moved["identical"] and moved["rendered_box"] == [11, 8, 31, 24]
    assert moved["only_in_preview"] == 16 and moved["only_in_rendered"] == 16 and moved["opaque_in_both"] == 304
    tinted = render_compare.compare_images(base, picture((10, 8, 20, 16), "#40a048"))
    assert tinted["colour_differs"] == 0 and tinted["largest_channel_delta"] == 8             # within one step
    recoloured = render_compare.compare_images(base, picture((10, 8, 20, 16), "#a04040"))
    assert recoloured["colour_differs"] == 320 and recoloured["largest_channel_delta"] == 96
    soft = render_compare.compare_images(base, picture((10, 8, 20, 16), extra=((10, 8, 20, 1), (64, 160, 64, 128))))
    assert soft["partly_transparent"] == 0 or soft["colour_differs"] == 0                    # painted over, still opaque
    assert render_compare.compare_images(base, QImage(8, 8, QImage.Format.Format_ARGB32))["same_size"] is False
    empty = QImage(64, 48, QImage.Format.Format_ARGB32)
    empty.fill(Qt.GlobalColor.transparent)
    assert render_compare.bounding_box(empty) is None
    sheet = render_compare.side_by_side([base, None, base], ["a", "b", "c"])
    assert sheet.width() == 64 * 2 + 8 * 3 and sheet.height() == 48 + 8 * 2 + 18


def test_the_preview_image_is_the_workspace_canvas_without_guides(app, beetle):
    from gui import render_compare
    clip = beetle.data["animations"]["clips"][0]["id"]
    right, state = render_compare.preview_image(PROJECT, beetle, clip, 0, 1, SIZE, ZOOM)
    left, _state = render_compare.preview_image(PROJECT, beetle, clip, 0, -1, SIZE, ZOOM)
    assert state == "ok" and (right.width(), right.height()) == SIZE
    box = render_compare.bounding_box(right)
    corners = rendering.expected_corners(beetle, clip, 0, 1, SIZE, ZOOM)
    assert corners[0][0] <= box[0] and box[2] <= corners[1][0] and corners[0][1] <= box[1] and box[3] <= corners[2][1]
    mirrored = render_compare.bounding_box(left)
    assert mirrored[0] == SIZE[0] - box[2] and mirrored[2] == SIZE[0] - box[0]                # mirrored about the origin
    with_shapes, _state = render_compare.preview_image(PROJECT, beetle, clip, 0, 1, SIZE, ZOOM, shapes=True)
    assert render_compare.compare_images(right, with_shapes)["identical"] is False
    shapes = render_compare.slots_as_shapes(beetle, clip, 0)
    assert shapes[0]["kind"] == "body" and all({"kind", "id", "shape"} <= set(row) for row in shapes)
    json.dumps(shapes)
