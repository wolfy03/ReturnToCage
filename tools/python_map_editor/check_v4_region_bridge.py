"""Exercise V4 region conversion in isolated Godot project snapshots."""

import argparse
from dataclasses import replace
from pathlib import Path
from threading import Event

from document import decode, encode
from godot_bridge import BridgeError, GodotSession, ProjectSettings, write_json
from region_design import RegionPoint, SpawnPoint

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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    sewer(ProjectSettings(Path.cwd(), args.godot, args.artifacts))


if __name__ == "__main__":
    main()
