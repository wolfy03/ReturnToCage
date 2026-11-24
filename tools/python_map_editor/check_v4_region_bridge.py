"""Exercise V4 region conversion in isolated Godot project snapshots."""

import argparse
from dataclasses import replace
from pathlib import Path
import tempfile
from threading import Event

from document import decode, encode
from godot_bridge import BridgeError, GodotSession, ProjectSettings, file_hash, project_manifest, write_json
from publish_region import publish_pair, recover_project
from region_design import RegionEnvironment, RegionPoint, SpawnPoint
from region_wizard import create_region

SEWER = "data/content/regions/sewer_region.tres"


def sewer(settings):
    with GodotSession(settings, Event(), print) as session:
        draft, original = session.import_region(SEWER, design=True)
        assert draft.design is not None and decode(encode(draft)) == draft
        assert len(draft.design.spawn_points) == 4 and len(draft.design.region_points) == 3
        _, unchanged = session.stage_design(draft)
        for field in ("scene_hash", "region_hash", "scene_state", "scene_uid", "region_uid", "definition_state"):
            assert original[field] == unchanged[field], field

        entry, escape, ladder = draft.design.region_points
        changed_entry = replace(entry, position=(152, 520))
        changed_exit = replace(escape, position=(72, 510))
        changed_spawn = replace(draft.design.spawn_points[0], position=(151, 520))
        new_entry = RegionPoint("fixture_entry", "ENTRY", "fixture_anchor", (390, 520))
        new_exit = RegionPoint("fixture_escape", "ESCAPE", "fixture_anchor", (400, 520))
        design = replace(draft.design, region_points=(changed_entry, changed_exit, new_entry, new_exit),
                         spawn_points=(changed_spawn, *draft.design.spawn_points[1:3], SpawnPoint("fixture_slot", 3, (296, 520))),
                         environment=replace(draft.design.environment, loading_color="#123456"))

        try:
            invalid = replace(draft.design, region_points=(replace(entry, point_id="unsafe_rename"), escape, ladder))
            session.stage_design(replace(draft, design=invalid))
        except BridgeError as error:
            assert error.code == "UNSUPPORTED_NODE" and "settlement exit sewer_gate" in str(error)
        else:
            raise AssertionError("a referenced ENTRY was renamed")

        edited, receipt = session.stage_design(replace(draft, design=design))
        assert receipt["runtime"]["overall"] in ("PASS", "PASS_WITH_WARNINGS")
        assert receipt["scene_hash"] != original["scene_hash"] and receipt["region_hash"] != original["region_hash"]
        assert receipt["scene_uid"] == draft.source.scene_uid and receipt["region_uid"] == draft.source.region_uid
        # Three markers added, two removed, and Sewer gains the official marker group.
        assert receipt["node_count"] == original["node_count"] + 2
        old_bindings = {item.id: item for item in draft.source.bindings}
        new_bindings = {item.id: item for item in edited.source.bindings}
        assert ladder.id not in new_bindings and draft.design.spawn_points[3].id not in new_bindings
        for marker in (changed_entry, changed_exit, changed_spawn):
            before, after = old_bindings[marker.id], new_bindings[marker.id]
            assert before.path == after.path and before.parent == after.parent
            assert before.local_transform[:4] == after.local_transform[:4]
            assert before.world_transform[:4] == after.world_transform[:4]
        before_nodes, after_nodes = original["scene_state"]["nodes"], receipt["scene_state"]["nodes"]
        edited_paths = {old_bindings[m.id].path for m in (entry, escape, ladder, changed_spawn, draft.design.spawn_points[3])}
        for path in before_nodes.keys() - edited_paths:
            assert after_nodes[path] == before_nodes[path], path
        session.assert_source_unchanged()
        write_json(session.evidence / "sewer-v4-check.json", {"no_op": True, "edited": True, "nodes": receipt["node_count"],
                   "runtime": receipt["runtime"]["overall"], "original_nodes": original["node_count"]})
        print("V4 SEWER PASS", session.evidence, flush=True)


def new_regions(settings, templates=("empty", "flat", "platform"), check_unsafe=True):
    with GodotSession(settings, Event(), print) as session:
        results = {}
        env = RegionEnvironment("res://world/environment/presets/sewer_environment.tres", loading_color="#203456")
        floor = create_region("v4_floor", "Fixture", 1200, 600, "flat", 4, env).objects
        for template in templates:
            draft = create_region(f"v4_{template}", f"V4 {template}", 1200, 600, template, 4, env)
            if template == "empty":
                assert not draft.objects
                draft = replace(draft, objects=floor)  # Add a floor in the normal document model before live spawn.
            linked, receipt = session.stage_design(draft)
            assert linked.source.scene_uid and linked.source.region_uid and linked.source.scene_uid != linked.source.region_uid
            assert receipt["runtime"]["overall"] in ("PASS", "PASS_WITH_WARNINGS")
            assert receipt["region_path"].endswith(f"/{draft.region_id}.tres")
            assert receipt["scene_path"].endswith(f"/{draft.region_id}.tscn")
            assert all(node in receipt["scene_state"]["nodes"] for node in (
                "NetworkEntityRegistry", "LootSpawnManager", "EnemySpawnManager", "PlayerSpawnManager"))
            if template == "platform":
                assert "Climbables/TemplateLadder/Top" in receipt["scene_state"]["nodes"]
            results[template] = {"nodes": receipt["node_count"], "runtime": receipt["runtime"]["overall"]}
        if check_unsafe:
            unsafe = create_region("v4_no_floor", "Empty without floor", 1200, 600, "empty", 4, RegionEnvironment())
            try:
                session.stage_design(unsafe)
            except BridgeError as error:
                assert error.code == "RUNTIME_LOAD_FAILED", error
                assert "Ground Support" in str(error) or "Player Spawn" in str(error), error
                assert not (settings.project / "world/adventure/v4_no_floor.tscn").exists()
            else:
                raise AssertionError("a floorless region was approved for live spawning")
            results["floorless"] = "BLOCKED"
        write_json(session.evidence / "new-v4-check.json", results)
        print("V4 NEW REGIONS PASS", session.evidence, flush=True)


def publication(settings):
    cancel = Event()
    settings.work.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="v4-publish-copy-", dir=settings.work) as directory:
        project = Path(directory)
        original = project_manifest(settings.project, cancel, project)
        isolated = replace(settings, project=project)
        draft = create_region("v4_publish", "Published region", 1200, 600, "flat", 4, RegionEnvironment())
        with GodotSession(isolated, cancel, print) as session:
            saved, receipt = session.stage_design(draft)
            scene, definition = publish_pair(session, draft, receipt)
            assert file_hash(scene) == saved.source.scene_hash and file_hash(definition) == saved.source.region_hash
            assert recover_project(project) == []
        with GodotSession(isolated, cancel, print) as session:
            reopened, _ = session.import_region(saved.source.region_path, design=True)
            assert reopened.source == saved.source and reopened.design == saved.design
            entry, *others = reopened.design.region_points
            design = replace(reopened.design, region_points=(replace(entry, position=(160, 520)), *others),
                             environment=replace(reopened.design.environment, loading_color="#123456"))
            edited = replace(reopened, design=design)
            updated, receipt = session.stage_design(edited)
            assert publish_pair(session, edited, receipt) == (scene, definition)
            assert file_hash(scene) == updated.source.scene_hash and file_hash(definition) == updated.source.region_hash
            assert updated.source.scene_uid == saved.source.scene_uid and updated.source.region_uid == saved.source.region_uid
            assert project_manifest(settings.project, cancel) == original and recover_project(project) == []
            write_json(session.evidence / "publish-v4-check.json", {"new": True, "edited": True, "uid_preserved": True})
            print("V4 PAIR PUBLICATION PASS", session.evidence, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--only", choices=("sewer", "new", "publish"))
    args = parser.parse_args()
    settings = ProjectSettings(Path.cwd(), args.godot, args.artifacts)
    if args.only in (None, "sewer"):
        sewer(settings)
    if args.only in (None, "new"):
        new_regions(settings)
    if args.only in (None, "publish"):
        publication(settings)


if __name__ == "__main__":
    main()
