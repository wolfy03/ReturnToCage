"""Round-trip the Forest Trail, enemy spawns included, through the Godot bridge in an isolated project snapshot."""

import argparse
from dataclasses import replace
import json
from pathlib import Path
from threading import Event

from document import decode, encode
from godot_bridge import BridgeError, GodotSession, ProjectSettings
from region_design import EnemySpawn
from terrain_atlas import discover_themes

FOREST = "data/content/regions/forest_region.tres"
THEMES = {"forest_grass_dirt", "forest_soil", "forest_tree_root", "forest_fallen_log"}
ENEMY_SPAWNS = {"SpawnPoints/LedgeBeetle": "sewer_beetle", "SpawnPoints/HollowFrog": "frog",
                "SpawnPoints/TrailBeetle": "sewer_beetle", "SpawnPoints/EastFrog": "frog"}


def enemy_spawns(receipt):
    """Enemy markers are outside the Python document; the bridge must carry them through untouched."""
    found = {}
    for path, node in receipt["scene_state"]["nodes"].items():
        enemy = node.get("properties", {}).get("enemy_id")
        if enemy is not None:
            found[path] = (str(enemy).lstrip("&").strip('"'), node)
    return found


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    args = parser.parse_args()
    settings = ProjectSettings(Path.cwd(), args.godot, args.artifacts)
    themes, errors = discover_themes(settings.project)
    assert not errors and THEMES <= set(themes), (errors, sorted(themes))
    with GodotSession(settings, Event(), print) as session:
        draft, original = session.import_region(FOREST, design=True)
        assert draft.region_id == "forest_region" and draft.design is not None
        payload = encode(draft)
        assert json.loads(payload)["schema_version"] == 6 and decode(payload) == draft
        authored = {row.spawn_id: row for row in draft.design.enemy_spawns}
        assert {key: (row.enemy_id, row.enabled) for key, row in authored.items()} == {
            "forest_beetle_ledge": ("sewer_beetle", True), "forest_frog_hollow": ("frog", True),
            "forest_beetle_trail": ("sewer_beetle", True), "forest_frog_east": ("frog", True)}
        assert authored["forest_frog_hollow"].position == (1100, 565)
        platforms = [item for item in draft.objects if item.type == "platform"]
        decorations = [item for item in draft.objects if item.type == "decoration"]
        assert len(platforms) == 12 and len(decorations) == 8, (len(platforms), len(decorations))
        assert {item.properties.terrain.theme_id for item in platforms} == THEMES
        assert all(item.properties.terrain == themes[item.properties.terrain.theme_id] for item in platforms)
        assert sum(item.properties.one_way for item in platforms) == 6
        assert {item.properties.texture_path for item in decorations} == {
            "assets/decorations/forest/bush.png", "assets/decorations/forest/mushroom.png"}
        points = {(item.kind, item.point_id) for item in draft.design.region_points}
        assert points == {("ENTRY", "forest_trail"), ("ESCAPE", "forest_trail"), ("ESCAPE", "forest_overlook")}
        assert sorted(item.spawn_index for item in draft.design.spawn_points) == [0, 1, 2, 3]
        assert draft.design.environment.path == "res://world/environment/presets/forest_environment.tres"
        before = enemy_spawns(original)
        assert {path: enemy for path, (enemy, _) in before.items()} == ENEMY_SPAWNS, before

        # Saving an untouched draft must leave both files byte-identical.
        _, unchanged = session.stage_design(draft)
        for field in ("scene_hash", "region_hash", "scene_state", "scene_uid", "region_uid", "definition_state"):
            assert original[field] == unchanged[field], field

        # A draft saved before Schema V6 knows no enemy markers. It still stages, as V5,
        # and the bridge leaves every FieldEnemySpawnPoint exactly as authored.
        enemy_ids = {row.id for row in draft.design.enemy_spawns}
        legacy_source = replace(draft.source, bindings=tuple(item for item in draft.source.bindings if item.id not in enemy_ids))
        legacy = replace(draft, source=legacy_source, design=replace(draft.design, enemy_spawns=None))
        assert json.loads(encode(legacy))["schema_version"] == 5 and b"enemy_spawns" not in encode(legacy)
        staged_legacy, legacy_receipt = session.stage_design(legacy)
        assert staged_legacy.design.enemy_spawns is None
        for field in ("scene_hash", "region_hash", "scene_state", "definition_state"):
            assert original[field] == legacy_receipt[field], field

        # Edit terrain, decoration and a marker without touching the enemy list.
        log = next(item for item in platforms if item.properties.terrain.theme_id == "forest_fallen_log")
        bush = next(item for item in decorations if item.properties.texture_path.endswith("bush.png"))
        overlook = next(item for item in draft.design.region_points if item.point_id == "forest_overlook")
        moved_log = replace(log, position=(log.position[0] + 16, log.position[1]), size=(log.size[0] + 32, log.size[1]))
        moved_bush = replace(bush, position=(bush.position[0] + 24, bush.position[1]))
        moved_point = replace(overlook, position=(overlook.position[0] - 20, overlook.position[1]))
        objects = tuple({log.id: moved_log, bush.id: moved_bush}.get(item.id, item) for item in draft.objects)
        design = replace(draft.design, region_points=tuple(moved_point if item.id == overlook.id else item
                                                           for item in draft.design.region_points))
        edited, receipt = session.stage_design(replace(draft, objects=objects, design=design))
        assert receipt["runtime"]["overall"] in ("PASS", "PASS_WITH_WARNINGS"), receipt["runtime"]
        assert receipt["scene_hash"] != original["scene_hash"] and receipt["node_count"] == original["node_count"]
        assert receipt["scene_uid"] == draft.source.scene_uid and receipt["region_uid"] == draft.source.region_uid
        after = enemy_spawns(receipt)
        assert {path: node for path, (_, node) in after.items()} == {path: node for path, (_, node) in before.items()}
        assert edited.design.enemy_spawns == draft.design.enemy_spawns
        reloaded = {item.id: item for item in edited.objects}
        assert reloaded[log.id].size == moved_log.size and reloaded[log.id].position == moved_log.position
        assert reloaded[log.id].properties.terrain == log.properties.terrain
        assert reloaded[bush.id].position == moved_bush.position
        assert decode(encode(edited)) == edited

        session.assert_source_unchanged()

    # Schema V6: move, retype, disable, remove and add enemy spawns from the Python document.
    # One session stages one edit of its import, so this starts from a fresh snapshot.
    with GodotSession(settings, Event(), print) as session:
        draft, original = session.import_region(FOREST, design=True)
        authored = {row.spawn_id: row for row in draft.design.enemy_spawns}
        hollow, ledge, trail, east = (authored[key] for key in
                                      ("forest_frog_hollow", "forest_beetle_ledge", "forest_beetle_trail", "forest_frog_east"))
        # Invalid enemy lists are refused by Godot before anything is written.
        for bad, code in (((replace(hollow, enemy_id="dragon"), ledge, trail, east), "RESOURCE_MISSING"),
                          ((hollow, replace(ledge, spawn_id=hollow.spawn_id), trail, east), "INVALID_DOCUMENT")):
            try:
                session.stage_design(replace(draft, design=replace(draft.design, enemy_spawns=bad)))
            except BridgeError as error:
                assert error.code == code, error
            else:
                raise AssertionError(f"bridge accepted an invalid enemy spawn list: {code}")
        added = EnemySpawn("enemy_python_added", "forest_beetle_west", "sewer_beetle", (480, 525))
        wanted = (replace(hollow, position=(1160, 565)), replace(ledge, enemy_id="frog", spawn_id="forest_frog_ledge"),
                  replace(trail, enabled=False), added)
        spawned, receipt = session.stage_design(replace(draft, design=replace(draft.design, enemy_spawns=wanted)))
        assert receipt["runtime"]["overall"] in ("PASS", "PASS_WITH_WARNINGS"), receipt["runtime"]
        assert {row.id: row for row in spawned.design.enemy_spawns} == {row.id: row for row in wanted}
        nodes = set(enemy_spawns(receipt))
        assert nodes == {"SpawnPoints/HollowFrog", "SpawnPoints/LedgeBeetle", "SpawnPoints/TrailBeetle",
                         "SpawnPoints/RTC_enemy_python_added"}, sorted(nodes)
        assert receipt["node_count"] == original["node_count"]
        assert receipt["scene_uid"] == draft.source.scene_uid and receipt["region_uid"] == draft.source.region_uid
        assert spawned.objects == draft.objects and spawned.design.region_points == draft.design.region_points
        assert json.loads(encode(spawned))["schema_version"] == 6 and decode(encode(spawned)) == spawned
        session.assert_source_unchanged()
    print("FOREST REGION BRIDGE PASS")


if __name__ == "__main__":
    main()
