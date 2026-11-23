from dataclasses import replace
import json

import pytest

from document import MapDocument, decode, encode, read_document, write_document
from objects import DocumentError
from placement_presets import capture_preset, load_preset
from region_design import Connection, RegionDesign, RegionEnvironment, RegionPoint, SpawnPoint
from region_wizard import create_region


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


@pytest.mark.parametrize(("template", "object_count"), [("empty", 0), ("flat", 1), ("platform", 3)])
def test_wizard_tracks_native_template_geometry(template, object_count):
    draft = create_region("sewer_draft", "하수구", 1200, 600, template, 4, RegionEnvironment())
    assert len(draft.objects) == object_count
    assert [point.position for point in draft.design.region_points] == [(150, 520), (1050, 520)]
    assert [spawn.spawn_index for spawn in draft.design.spawn_points] == [0, 1, 2, 3]
    if template == "platform":
        assert draft.design.template_ladder == (490, 454)
        assert draft.objects[1].properties.one_way
    assert decode(encode(draft)) == draft


def test_wizard_checks_known_region_ids():
    with pytest.raises(DocumentError, match="draft"):
        create_region("draft", "Draft", 1200, 600, "empty", 1, RegionEnvironment(), {"draft"})


def test_preset_preserves_relative_placement():
    draft = create_region("draft", "Draft", 1200, 600, "platform", 1, RegionEnvironment())
    name, rows = load_preset(capture_preset("platforms", draft.objects))
    assert name == "platforms"
    assert rows[0].position == (0, 0)
    assert rows[1].position == (-110, -121)
    assert rows[1].size == draft.objects[1].size and rows[1].properties.one_way
