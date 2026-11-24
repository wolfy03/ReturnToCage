from dataclasses import replace
import json
from pathlib import Path

import pytest

from document import MapDocument, decode, encode
from objects import DocumentError, MapObject, ObjectProperties
from terrain_atlas import atlas_error, discover_themes, read_theme, slice_boxes

PROJECT = Path(__file__).resolve().parents[3]


def test_registered_themes_and_v5_round_trip():
    themes, errors = discover_themes(PROJECT)
    assert set(themes) == {"sewer_concrete", "forest_ground"}
    assert not errors
    surface = themes["sewer_concrete"]
    platform = MapObject("platform_a", "platform", "terrain", (31, 45), surface.minimum_size,
                         rotation=15, properties=ObjectProperties(True, terrain=surface))
    doc = MapDocument(objects=(platform,))
    data = json.loads(encode(doc))
    assert data["schema_version"] == 5
    assert decode(encode(doc)) == doc
    with pytest.raises(DocumentError, match="smaller"):
        replace(platform, size=(surface.border_size[0] - 1, 100))
    legacy = replace(doc, objects=(replace(platform, properties=ObjectProperties(True)),))
    assert json.loads(encode(legacy))["schema_version"] == 2
    assert decode(encode(legacy)) == legacy


def test_nine_boxes_preserve_asymmetric_corners_and_zero_center():
    surface = read_theme(PROJECT, "forest_ground")
    cells = list(slice_boxes(surface, *surface.border_size))
    assert cells[0] == ((0, 0, 7, 6), (0, 0, 7, 6))
    assert cells[4] == ((7, 6, 13, 11), (7, 6, 0, 0))
    assert cells[8] == ((20, 17, 9, 5), (7, 6, 9, 5))


def test_metadata_rejects_missing_asset_and_bad_override(tmp_path):
    surface = read_theme(PROJECT, "sewer_concrete")
    assert "missing" in atlas_error(tmp_path, surface)
    with pytest.raises(DocumentError):
        replace(surface, texture_path="assets/terrain/../secret.png")
    with pytest.raises(DocumentError, match="positive center"):
        replace(surface, margins=(20, 6, 9, 5))


def test_qt_tiles_clip_without_stretching(monkeypatch):
    monkeypatch.setenv("QT_QPA_PLATFORM", "offscreen")
    pytest.importorskip("PySide6")
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QImage, QPainter
    from PySide6.QtWidgets import QApplication
    from terrain_renderer import TerrainCache, draw_terrain

    app = QApplication.instance() or QApplication([])
    surface = read_theme(PROJECT, "sewer_concrete")
    tile_cache = TerrainCache()
    tiles = tile_cache.lookup(PROJECT, surface)
    assert len(tiles) == 9
    source = QImage(str(PROJECT / surface.texture_path))
    for w, h in ((16, 11), (128, 128), (192, 192), (256, 128), (512, 128), (768, 256)):
        output = QImage(w, h, QImage.Format.Format_ARGB32)
        output.fill(0)
        painter = QPainter(output)
        rect = QRectF(0, 0, w, h)
        draw_terrain(painter, rect, rect, surface, tiles)
        painter.end()
        for (sx, sy, sw, sh), (x, y, dw, dh) in slice_boxes(surface, w, h):
            for py in range(y, y + dh):
                for px in (range(x, x + dw) if py % 19 == 0 else range(x, min(x + 2, x + dw))):
                    assert output.pixel(px, py) == source.pixel(sx + (px - x) % sw, sy + (py - y) % sh)
    assert app is QApplication.instance()


def test_terrain_preset_keeps_properties_and_unknown_surface_fields_block_load():
    from placement_presets import capture_preset, load_preset

    surface = read_theme(PROJECT, "sewer_concrete")
    original = MapObject("platform_a", "platform", "terrain", (10, 20), (80, 64), rotation=12,
                         properties=ObjectProperties(terrain=replace(surface, margins=(6, 5, 7, 4))))
    label, (reloaded,) = load_preset(capture_preset("terrain test", (original,)))
    assert label == "terrain test"
    assert reloaded.properties == original.properties and reloaded.rotation == original.rotation
    data = json.loads(encode(MapDocument(objects=(original,))))
    data["objects"][0]["properties"]["terrain"]["future_property"] = True
    with pytest.raises(DocumentError, match="invalid object property fields"):
        decode(json.dumps(data).encode())


def test_modified_atlas_dimensions_are_rejected(tmp_path):
    import shutil

    root = tmp_path / "project"
    shutil.copytree(PROJECT / "assets/terrain", root / "assets/terrain")
    atlas = read_theme(root, "sewer_concrete")
    metadata = root / "assets/terrain/sewer_concrete.json"
    valid = metadata.read_text(encoding="utf-8")
    data = json.loads(valid)
    data["source_size"][0] += 1
    metadata.write_text(json.dumps(data), encoding="utf-8")
    assert "dimensions" in atlas_error(root, atlas)


def test_linked_texture_is_rejected(tmp_path):
    import shutil

    root = tmp_path / "project"
    shutil.copytree(PROJECT / "assets/terrain", root / "assets/terrain")
    atlas = read_theme(root, "sewer_concrete")
    outside = tmp_path / "outsider.png"
    source = root / atlas.texture_path
    source.rename(outside)
    try:
        source.symlink_to(outside)
    except OSError:
        pytest.skip("symbolic link requires local privilege")
    assert "linked terrain path" in atlas_error(root, atlas)


def test_bridge_requires_registered_texture_without_rewriting_uid(tmp_path):
    import shutil
    from godot_bridge import BridgeError, GodotSession, file_hash

    shutil.copytree(PROJECT / "assets/terrain", tmp_path / "assets/terrain")
    surface = read_theme(tmp_path, "sewer_concrete")
    platform = MapObject("platform_a", "platform", "terrain", (31, 45), (80, 24),
                         properties=ObjectProperties(terrain=surface))
    document = MapDocument(objects=(platform,))
    session = GodotSession.__new__(GodotSession)
    session.stage = tmp_path
    session.manifest = {}
    with pytest.raises(BridgeError) as missing:
        session._check_atlases(document)
    assert missing.value.code == "RESOURCE_MISSING"
    sidecar = surface.texture_path + ".import"
    path = tmp_path / sidecar
    session.manifest[sidecar] = file_hash(path)
    session._check_atlases(document)
    path.write_text('uid="uid://replacement"\n', encoding="utf-8")
    with pytest.raises(BridgeError) as drift:
        session._check_atlases(document)
    assert drift.value.code == "UID_CONFLICT"
