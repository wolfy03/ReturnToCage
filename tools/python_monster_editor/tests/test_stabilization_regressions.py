"""Defects found in the MONSTER-STEP 1 review. Each test failed on b2e32b3 and passes after the fix.

They use only the API that already existed, so the "before" run is meaningful:
16 of these 19 cases failed before the stabilization (the three that passed
are the intact-image control and two inputs Python already rejected by
accident, ``tick_of(x, nan)`` and ``tick_of(nan)``).
"""

import json
import struct
import zlib

import pytest

from rtcmonster import FAIL, MonsterDocument, encode, new_document, validate
from rtcmonster.geometry import actor_to_sprite, sprite_to_actor
from rtcmonster.project import content_ids, png_size, published_monsters
from rtcmonster.timing import tick_of, window_ticks

SIGNATURE = bytes([0x89]) + b"PNG" + bytes([13, 10, 26, 10])
ZERO = bytes(1)


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))


def png_bytes(width, height, idat=None):
    rows = b"".join(ZERO + bytes(4 * width) for _ in range(height))
    return (SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows) if idat is None else idat) + chunk(b"IEND", b""))


@pytest.fixture
def project(tmp_path):
    root = tmp_path / "project"
    for folder in ("enemies", "items", "loot"):
        (root / "data/content" / folder).mkdir(parents=True)
    (root / "data/content/enemies/ant.tres").write_text('[resource]\nid = &"ant"\ndisplay_name = "Ant"\n', "utf-8")
    (root / "art").mkdir()
    return root


def with_image(document, name, width=8, height=8):
    data = document.to_dict()
    data["assets"]["images"] = [{"id": "strip", "path": f"art/{name}", "width": width, "height": height}]
    return MonsterDocument(data)


# ------------------------------------------------------------------------------------------- FIX-01 immutability
def test_the_data_property_cannot_be_used_to_change_a_document():
    document = new_document("moss_slug", "Moss Slug")
    before = encode(document)
    for mutate in (
            lambda data: data["stats"].__setitem__("max_health", -100),
            lambda data: data["behavior"]["states"].append({"id": "x"}),
            lambda data: data["behavior"]["states"][0]["transitions"].clear(),
            lambda data: data["collision"]["body"]["shape"]["size"].__setitem__(0, 0),
            lambda data: data.pop("stats"),
            lambda data: data["metadata"]["tags"].extend(["a"]),
            lambda data: data["stats"].update(max_health=1),
            lambda data: data["collision"]["hurtboxes"].sort(key=str),
    ):
        try:
            mutate(document.data)
        except (TypeError, AttributeError):
            pass
        assert encode(document) == before
    assert document.data["stats"]["max_health"] == 20


def test_an_earlier_snapshot_is_not_changed_through_a_later_one():
    first = new_document("moss_slug", "Moss Slug")
    second = first.replace(("stats", "max_health"), 30)
    try:
        second.data["metadata"]["tags"].append("oops")
    except (TypeError, AttributeError):
        pass
    assert first.data["metadata"]["tags"] == [] and second.data["metadata"]["tags"] == []
    assert json.loads(encode(first))["stats"]["max_health"] == 20


# ----------------------------------------------------------------------------------------------- FIX-05 catalog
def test_a_duplicated_content_id_is_not_silently_resolved_to_the_first_file(project):
    (project / "data/content/enemies/ant_copy.tres").write_text('[resource]\nid = &"ant"\n', "utf-8")
    (project / "data/content/enemies/bee.tres").write_text('[resource]\nid = &"bee"\n', "utf-8")
    assert "ant" not in published_monsters(project) and "ant" not in content_ids(project, "enemies")
    assert "bee" in published_monsters(project)


def test_one_unreadable_resource_does_not_empty_the_catalog(project):
    (project / "data/content/enemies/broken.tres").write_bytes(b'[resource]\nid = &"x"\n' + bytes([255, 254, 255]))
    assert "ant" in published_monsters(project)


# ------------------------------------------------------------------------------------------------ FIX-06 images
BROKEN_IMAGES = {
    "header_only": SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0)),
    "corrupt_idat": png_bytes(8, 8, idat=b"this is not a zlib stream"),
    "truncated": png_bytes(8, 8)[:-20],
    "bad_crc": png_bytes(8, 8)[:-5] + ZERO + png_bytes(8, 8)[-4:],
    "too_few_rows": png_bytes(8, 8, idat=zlib.compress(bytes(33))),
}


@pytest.mark.parametrize("label", list(BROKEN_IMAGES))
def test_an_image_with_a_valid_header_but_broken_data_is_not_accepted(project, label):
    (project / "art/bad.png").write_bytes(BROKEN_IMAGES[label])
    assert png_size(project / "art/bad.png") == (8, 8)        # the header alone still reads
    report = validate(with_image(new_document("bee", "Bee"), "bad.png"), project)
    assert report.status("assets") == FAIL, label


def test_an_intact_image_is_still_accepted(project):
    (project / "art/good.png").write_bytes(png_bytes(8, 8))
    assert validate(with_image(new_document("bee", "Bee"), "good.png"), project).status("assets") == "PASS"


# ------------------------------------------------------------------------------------- FIX-09 geometry and timing
@pytest.mark.parametrize("rate", [0, -60, float("nan"), float("inf")])
def test_a_meaningless_tick_rate_is_an_error_not_a_silent_zero(rate):
    with pytest.raises(ValueError):
        tick_of(0.2, rate)
    with pytest.raises(ValueError):
        window_ticks(0.1, 0.2, rate)


@pytest.mark.parametrize("seconds", [float("nan"), float("inf")])
def test_non_finite_times_are_rejected(seconds):
    with pytest.raises(ValueError):
        tick_of(seconds)


@pytest.mark.parametrize("scale", [[0, 1], [1, 0], [float("nan"), 1]])
def test_a_degenerate_visual_scale_is_reported_clearly(scale):
    presentation = {"faces_right_by_default": True, "visual_scale": scale, "visual_offset": [0, 0]}
    with pytest.raises(ValueError, match="visual_scale"):
        actor_to_sprite([1, 1], (64, 64), presentation)
    with pytest.raises(ValueError, match="visual_scale"):
        sprite_to_actor([1, 1], (64, 64), presentation)
