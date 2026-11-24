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
