from dataclasses import replace
import json

import pytest

from document import MapDocument, decode, encode, read_document, write_document
from objects import DocumentError
from region_design import Connection, RegionDesign, RegionEnvironment, RegionPoint, SpawnPoint


def test_region_design_save_and_reopen(tmp_path):
    design = RegionDesign((RegionPoint("marker", "ENTRY", "entry", [32, 64]),),
                          (Connection("gate", "new_region", "entry"),),
                          (SpawnPoint("spawn", 3, [80, 64]),),
                          RegionEnvironment("res://world/environment/presets/sewer_environment.tres",
                                            "uid://example", "#12345678"))
    original = MapDocument(design=design)
    path = tmp_path / "지역.rtcmap"
    revision = write_document(path, original)
    assert json.loads(path.read_bytes())["schema_version"] == 4
    assert read_document(path) == (original, revision)
    assert decode(encode(replace(original, design=None))).design is None


def test_region_marker_identity_is_shared_across_marker_kinds():
    with pytest.raises(DocumentError, match="duplicate stable marker ID"):
        RegionDesign((RegionPoint("same", "ENTRY", "entry", [0, 0]),),
                     spawn_points=(SpawnPoint("same", 0, [0, 0]),))


@pytest.mark.parametrize("value", [True, -1, 4, 0.0])
def test_spawn_index_matches_godot(value):
    with pytest.raises(DocumentError, match="spawn_index"):
        SpawnPoint("spawn", value, [0, 0])


@pytest.mark.parametrize("path", ["foo.tres", "res://../foo.tres", "res://foo?.tres"])
def test_environment_is_a_project_resource(path):
    with pytest.raises(DocumentError):
        RegionEnvironment(path)
