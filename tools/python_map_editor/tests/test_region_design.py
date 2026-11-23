from dataclasses import replace
import json

import pytest

from document import MapDocument, decode, encode, read_document, write_document
from objects import DocumentError
from placement_presets import capture_preset, load_preset
from region_design import Connection, RegionDesign, RegionEnvironment, RegionPoint, SpawnPoint
from region_index import IndexedRegion
from region_wizard import create_region
from region_validation import EXTERNAL, FAIL, NOT_EVALUATED, PASS, STATIC, WARNING, summarize, validate_region


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
    for dimensions in ((1200, 600), (64, 64), (32768, 32768)):
        resized = create_region("sewer_draft", "하수구", *dimensions, template, 4, RegionEnvironment())
        assert summarize(item.status for item in validate_region(resized) if item.domain == STATIC) == PASS


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


def test_validation_matches_region_point_and_spawn_rules(tmp_path):
    # Sewer shares an ID between an ENTRY and an ESCAPE. Within one kind it must be unique.
    points = (RegionPoint("a", "ENTRY", "gate", [10, 10]), RegionPoint("b", "ESCAPE", "gate", [20, 10]))
    draft = create_region("draft", "Draft", 1200, 600, "flat", 4, RegionEnvironment())
    design = replace(draft.design, region_points=points, connections=(Connection("gate", "draft", "gate"),))
    assert summarize(item.status for item in validate_region(replace(draft, design=design)) if item.domain == STATIC) == PASS
    invalid = replace(design, region_points=(*points, RegionPoint("c", "ENTRY", "gate", [-2, 8])),
                      connections=(*design.connections, Connection("gate", "draft", "wrong")),
                      spawn_points=(SpawnPoint("spawn_a", 0, [600, 565]), SpawnPoint("spawn_b", 1, [600, 565]),
                                    SpawnPoint("spawn_c", 2, [90, 60]), SpawnPoint("spawn_d", 2, [80, 60])),
                      environment=RegionEnvironment("res://missing.tres"))
    findings = validate_region(replace(draft, design=invalid), project=tmp_path.resolve())
    assert {item.code for item in findings if item.status == FAIL} == {
        "duplicate_point", "outside_bounds", "duplicate_connection", "shared_entry_conflict",
        "destination_entry_invalid", "duplicate_slot", "environment_reference",
    }
    assert {item.code for item in findings if item.status == WARNING} == {
        "spawn_capacity", "coincident_spawn", "spawn_center_overlap",
    }
    assert any(item.status == NOT_EVALUATED and item.code == "physics_clearance_check" for item in findings)


def test_external_entry_requires_an_index(tmp_path):
    draft = create_region("draft", "Draft", 1200, 600, "empty", 4, RegionEnvironment())
    link = Connection("draft_exit", "external", "entry")
    draft = replace(draft, design=replace(draft.design, connections=(link,)))
    assert any(item.status == NOT_EVALUATED and item.connection == 0 for item in validate_region(draft))
    record = IndexedRegion("external", tmp_path / "external.rtcmap", "hash", 4, ())
    assert any(item.status == FAIL and item.connection == 0 for item in validate_region(draft, {"external": record}))
    other = replace(record, region_id="other")
    draft = replace(draft, design=replace(draft.design, connections=(link, Connection("draft_exit", "other", "entry"))))
    findings = validate_region(draft, {"external": replace(record, entries=("entry",)),
                                       "other": replace(other, entries=("entry",))})
    assert [item.status for item in findings if item.domain == EXTERNAL] == [PASS, PASS]


@pytest.mark.parametrize(("edit", "exit_id", "expected"), [
    ("unchanged", "draft_exit", None), ("unchanged", "missing", "source_exit_missing"),
    ("unchanged", "draft_entry", "source_exit_missing"), ("duplicate", "draft_exit", "source_exit_ambiguous"),
    ("delete", "draft_exit", "source_exit_missing"), ("rename", "draft_exit", "source_exit_missing"),
])
def test_connection_source_uses_escape_points(edit, exit_id, expected):
    draft = create_region("draft", "Draft", 1200, 600, "empty", 4, RegionEnvironment())
    entry, escape = draft.design.region_points
    points = {"unchanged": (entry, escape), "duplicate": (entry, escape, replace(escape, id="extra_escape")),
              "delete": (entry,), "rename": (entry, replace(escape, point_id="new_exit"))}[edit]
    design = replace(draft.design, region_points=points, connections=(Connection(exit_id, "draft", "draft_entry"),))
    codes = [item.code for item in validate_region(replace(draft, design=design)) if item.connection == 0]
    assert codes == ([expected] if expected else [])


@pytest.mark.parametrize(("change", "state", "status", "code"), [
    ("entry", "modified", NOT_EVALUATED, "destination_modified"),
    ("id", "modified", NOT_EVALUATED, "destination_modified"),
    ("version", "modified", NOT_EVALUATED, "destination_modified"),
    ("missing", "missing", FAIL, "destination_missing"),
    ("invalid", "invalid", FAIL, "destination_invalid"),
    ("unknown_schema", "invalid", FAIL, "destination_invalid"),
])
def test_region_index_rejects_stale_entry_information(tmp_path, change, state, status, code):
    external = create_region("external", "이웃 지역", 1200, 600, "flat", 4, RegionEnvironment())
    path = tmp_path / "이웃.rtcmap"
    original = encode(external)
    path.write_bytes(original)
    record = IndexedRegion.read(path)
    assert record.schema_version == 4 and record.entries == ("external_entry",)
    assert record.sha256 == read_document(path)[1]
    if change == "missing":
        path.unlink()
    else:
        data = {"entry": original.replace(b"external_entry", b"changed_entry"),
                "id": encode(replace(external, region_id="other")),
                "version": encode(replace(external, design=None)), "invalid": b"not JSON",
                "unknown_schema": original.replace(b'"schema_version":4', b'"schema_version":99')}[change]
        path.write_bytes(data)
    checked = record.recheck()
    assert checked.state == state and checked.current_entries is None and checked.sha256 == record.sha256
    draft = create_region("draft", "Draft", 1200, 600, "empty", 4, RegionEnvironment())
    draft = replace(draft, design=replace(draft.design, connections=(Connection("draft_exit", "external", "external_entry"),)))
    assert [(item.status, item.code) for item in validate_region(draft, {"external": checked}) if item.domain == EXTERNAL] == [(status, code)]
    path.write_bytes(original)
    assert checked.recheck() == record


@pytest.mark.parametrize(("states", "expected"), [
    ((), NOT_EVALUATED), ((PASS, PASS), PASS), ((PASS, NOT_EVALUATED), NOT_EVALUATED),
    ((PASS, NOT_EVALUATED, WARNING), WARNING), ((WARNING, NOT_EVALUATED, FAIL), FAIL),
])
def test_summary_requires_evidence_for_every_applicable_domain(states, expected):
    assert summarize(states) == expected
