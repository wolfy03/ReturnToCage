from dataclasses import asdict, replace
import json

import pytest

import document
from document import DocumentError, MapDocument, decode, encode, read_document, write_document
from objects import MapLayer, MapObject, ObjectProperties, rotate, snap


def sample():
    return MapDocument(
        region_id="sewer_preview", display_name="하수구",
        layers=(MapLayer("terrain", "지형"), MapLayer("decorations", "장식", False, True)),
        objects=(
            MapObject("wall", "platform", "terrain", (-32, 4.5), (192, 24), 35, ObjectProperties(True)),
            MapObject("deco", "decoration", "decorations", (20, 50), (44, 56), -25,
                      ObjectProperties(texture_path="assets/장식.png")),
        ),
    )


def test_v1_migrates_only_when_saved(tmp_path):
    path = tmp_path / "legacy.rtcmap"
    legacy = b'{"schema_version":1,"region_id":"legacy","display_name":"Old","width":600,"height":480}'
    path.write_bytes(legacy)
    loaded, revision = read_document(path)
    assert loaded == MapDocument("legacy", "Old", 600, 480)
    assert path.read_bytes() == legacy
    write_document(path, loaded, revision)
    assert json.loads(path.read_bytes())["schema_version"] == 2
    assert read_document(path)[0] == loaded


def test_v2_round_trip(tmp_path):
    path = tmp_path / "배치.rtcmap"
    original = sample()
    write_document(path, original)
    assert read_document(path)[0] == original
    assert "장식.png" in path.read_text(encoding="utf-8")


@pytest.mark.parametrize("changes", [
    {"position": [True, 1]}, {"position": [0]}, {"position": [1e99, 1]},
    {"position": [float("nan"), 1]}, {"position": [float("inf"), 1]},
    {"size": [-1, 32]}, {"size": [3, 32]}, {"rotation": float("-inf")},
    {"type": "unknown"}, {"layer_id": "../x"}, {"id": ""},
])
def test_rejects_invalid_geometry_and_identity(changes):
    with pytest.raises(DocumentError):
        replace(sample().objects[0], **changes)


@pytest.mark.parametrize("target", ["../escape.png", "/root.png", "res://foo.png", "C:/foo.png",
                                    r"textures\foo.png", "assets//foo.png", "tile.ctex", "a/./tile.png"])
def test_texture_must_be_relative_png(target):
    with pytest.raises(DocumentError):
        ObjectProperties(texture_path=target)


def test_document_rejects_broken_references():
    draft = sample()
    with pytest.raises(DocumentError, match="duplicate object"):
        replace(draft, objects=draft.objects * 2)
    with pytest.raises(DocumentError, match="unknown layer"):
        replace(draft, layers=draft.layers[:1])
    with pytest.raises(DocumentError, match="duplicate layer"):
        replace(draft, layers=draft.layers * 2)


@pytest.mark.parametrize("constant", ["NaN", "Infinity", "-Infinity", "1e999"])
def test_decode_rejects_nonfinite_json(constant):
    payload = encode(sample()).replace(b"4.5", constant.encode())
    with pytest.raises(DocumentError):
        decode(payload)


def test_future_version_is_rejected():
    with pytest.raises(DocumentError, match="unsupported"):
        decode(encode(sample()).replace(b'"schema_version":2', b'"schema_version":3'))


def test_minimal_properties_and_wrong_object_properties():
    obj = sample().objects[0]
    assert MapObject.from_data({**asdict(obj), "properties": {}}).properties == ObjectProperties()
    with pytest.raises(DocumentError, match="properties"):
        replace(obj, properties=ObjectProperties(texture_path="tile.png"))


def test_file_limit_applies_before_publish(tmp_path, monkeypatch):
    path = tmp_path / "limit.rtcmap"
    before = MapDocument()
    revision = write_document(path, before)
    monkeypatch.setattr(document, "MAX_FILE_BYTES", len(encode(before)))
    with pytest.raises(DocumentError, match="size limit"):
        write_document(path, sample(), revision)
    assert read_document(path) == (before, revision)


def test_godot_angle_and_grid_conventions():
    assert rotate((20, 0), 90) == pytest.approx((0, 20))
    assert rotate(rotate((10, 4), 35), -35) == pytest.approx((10, 4))
    assert [snap(value, 32) for value in (-48, -1, 0, 15, 16)] == [-32, 0, 0, 0, 32]

