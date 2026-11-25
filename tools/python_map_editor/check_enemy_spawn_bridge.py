"""Schema V6 data-safety gate: publish enemy spawn edits into a disposable project copy and reload them."""

import argparse
from dataclasses import replace
import json
from pathlib import Path
import re
import tempfile
from threading import Event

from document import decode, encode
from godot_bridge import BridgeError, GodotSession, ProjectSettings, file_hash, project_manifest, write_json
from publish_region import publish_pair, recover_project
from region_design import EnemySpawn, RegionEnvironment
from region_wizard import create_region

FOREST = "data/content/regions/forest_region.tres"
FOREST_SCENE = "world/adventure/forest_region.tscn"
AUTHORED = {"forest_beetle_ledge": "sewer_beetle", "forest_frog_hollow": "frog",
            "forest_beetle_trail": "sewer_beetle", "forest_frog_east": "frog"}


def declared_enemies(project, region=FOREST):
    """RegionDefinition.enemy_ids as written on disk. An empty array is omitted by Godot."""
    text = (project / region).read_text(encoding="utf-8")
    match = re.search(r"^enemy_ids = Array\[StringName\]\(\[(.*)\]\)$", text, re.MULTILINE)
    return re.findall(r'&"([a-z0-9_]+)"', match[1]) if match else []


def marker_count(project, scene=FOREST_SCENE):
    return len(re.findall(r"^enemy_id = ", (project / scene).read_text(encoding="utf-8"), re.MULTILINE))


def by_spawn(design):
    return {row.spawn_id: (row.enemy_id, row.enabled, row.position) for row in design.enemy_spawns}


def publish(settings, change, region=FOREST):
    """Import, edit, stage, publish. Returns the imported draft and the staged result."""
    with GodotSession(settings, Event(), print) as session:
        draft, original = session.import_region(region, design=True)
        edited = change(draft)
        staged, receipt = session.stage_design(edited)
        publish_pair(session, edited, receipt)
        assert recover_project(settings.project) == []
        for key in ("scene_uid", "region_uid"):
            assert receipt[key] == original[key] == getattr(draft.source, key), key
        return draft, staged, receipt


def reload(settings, region=FOREST):
    with GodotSession(settings, Event(), print) as session:
        return session.import_region(region, design=True)


def refused(session, document, code):
    try:
        session.stage_design(document)
    except BridgeError as error:
        assert error.code == code, error
        return str(error)
    raise AssertionError(f"bridge accepted a document that must fail with {code}")


def data_safety(settings, round_trips):
    cancel = Event()
    settings.work.mkdir(parents=True, exist_ok=True)
    results = {}
    with tempfile.TemporaryDirectory(prefix="v6-enemy-copy-", dir=settings.work) as directory:
        project = Path(directory)
        source_manifest = project_manifest(settings.project, cancel, project)
        isolated = replace(settings, project=project)
        scene_uid = region_uid = None

        # A. A linked draft saved before V6 publishes a terrain edit and keeps every enemy node.
        def legacy_edit(draft):
            enemy_ids = {row.id for row in draft.design.enemy_spawns}
            source = replace(draft.source, bindings=tuple(item for item in draft.source.bindings if item.id not in enemy_ids))
            log = next(item for item in draft.objects if item.type == "platform"
                       and item.properties.terrain.theme_id == "forest_fallen_log")
            moved = replace(log, position=(log.position[0] + 16, log.position[1]))
            legacy = replace(draft, source=source, design=replace(draft.design, enemy_spawns=None),
                             objects=tuple(moved if item.id == log.id else item for item in draft.objects))
            assert json.loads(encode(legacy))["schema_version"] == 5 and decode(encode(legacy)) == legacy
            return legacy

        imported, staged, receipt = publish(isolated, legacy_edit)
        scene_uid, region_uid = imported.source.scene_uid, imported.source.region_uid
        assert staged.design.enemy_spawns is None and json.loads(encode(staged))["schema_version"] == 5
        after, _ = reload(isolated)
        assert by_spawn(after.design) == by_spawn(imported.design) and {k: v[0] for k, v in by_spawn(after.design).items()} == AUTHORED
        assert {row.id for row in after.design.enemy_spawns} == {row.id for row in imported.design.enemy_spawns}
        assert declared_enemies(project) == ["sewer_beetle", "frog"] and marker_count(project) == 4
        assert after.objects != imported.objects  # the terrain edit did land
        results["v5_linked_publish_keeps_enemies"] = "PASS"

        # B. An empty V6 list removes every enemy marker and empties RegionDefinition.enemy_ids.
        _, staged, receipt = publish(isolated, lambda draft: replace(draft, design=replace(draft.design, enemy_spawns=())))
        assert staged.design.enemy_spawns == () and json.loads(encode(staged))["schema_version"] == 6
        emptied, _ = reload(isolated)
        assert emptied.design.enemy_spawns == () and declared_enemies(project) == [] and marker_count(project) == 0
        assert emptied.objects == after.objects and emptied.design.region_points == after.design.region_points
        results["empty_list_removes_all_enemies"] = "PASS"
        results["empty_list_runtime"] = receipt["runtime"]["overall"]

        # C. Add enemies again after removing all of them; a disabled spawn survives the reload.
        wanted = (EnemySpawn("enemy_readded_frog", "forest_frog_back", "frog", (1100, 565)),
                  EnemySpawn("enemy_readded_beetle", "forest_beetle_off", "sewer_beetle", (640, 477), False),
                  EnemySpawn("enemy_readded_frog_b", "forest_frog_east_b", "frog", (2200, 525)))
        _, staged, receipt = publish(isolated, lambda draft: replace(draft, design=replace(draft.design, enemy_spawns=wanted)))
        readded, _ = reload(isolated)
        assert {row.id: row for row in readded.design.enemy_spawns} == {row.id: row for row in wanted}
        assert by_spawn(readded.design)["forest_beetle_off"] == ("sewer_beetle", False, (640, 477))
        assert declared_enemies(project) == ["frog", "sewer_beetle"] and marker_count(project) == 3
        assert decode(encode(readded)) == readded and json.loads(encode(readded))["schema_version"] == 6
        results["readd_after_removal_and_disabled_reload"] = "PASS"

        # Dropping the only beetle updates enemy_ids; the frogs keep their declaration.
        publish(isolated, lambda draft: replace(draft, design=replace(
            draft.design, enemy_spawns=tuple(row for row in draft.design.enemy_spawns if row.enemy_id == "frog"))))
        assert declared_enemies(project) == ["frog"] and marker_count(project) == 2
        results["enemy_ids_follow_removed_kind"] = "PASS"

        # D. Invalid enemy lists are refused and leave the project byte-identical.
        before = project_manifest(project, cancel)
        with GodotSession(isolated, cancel, print) as session:
            draft, _ = session.import_region(FOREST, design=True)
            first, second = draft.design.enemy_spawns
            for name, rows, code in (
                    ("unknown_enemy", (replace(first, enemy_id="dragon"), second), "RESOURCE_MISSING"),
                    ("unknown_enemy_disabled", (replace(first, enemy_id="dragon", enabled=False), second), "RESOURCE_MISSING"),
                    ("new_unknown_enemy", (first, second, EnemySpawn("enemy_bad", "bad_spawn", "dragon", (480, 525))), "RESOURCE_MISSING"),
                    ("duplicate_spawn_id", (first, replace(second, spawn_id=first.spawn_id)), "INVALID_DOCUMENT")):
                results["rejected_" + name] = refused(session, replace(draft, design=replace(draft.design, enemy_spawns=rows)), code)
            session.assert_source_unchanged()
        assert project_manifest(project, cancel) == before and recover_project(project) == []
        results["rejections_leave_project_unchanged"] = "PASS"

        # E. A source changed after import is refused at staging and again at publication.
        scene_file = project / FOREST_SCENE
        pristine = scene_file.read_bytes()
        with GodotSession(isolated, cancel, print) as session:
            draft, _ = session.import_region(FOREST, design=True)
            moved = replace(draft, design=replace(draft.design, enemy_spawns=(
                replace(draft.design.enemy_spawns[0], position=(1120, 565)), draft.design.enemy_spawns[1])))
            staged, receipt = session.stage_design(moved)
            scene_file.write_bytes(pristine + b"\n")
            try:
                publish_pair(session, moved, receipt)
            except BridgeError as error:
                assert error.code == "SOURCE_MODIFIED", error
            else:
                raise AssertionError("published over a Scene that changed after import")
            assert scene_file.read_bytes() == pristine + b"\n" and recover_project(project) == []
        with GodotSession(isolated, cancel, print) as session:
            draft, _ = session.import_region(FOREST, design=True)
            scene_file.write_bytes(pristine)
            try:
                session.stage_design(draft)
            except BridgeError as error:
                assert error.code == "SOURCE_MODIFIED", error
            else:
                raise AssertionError("staged a draft whose source changed after import")
        assert project_manifest(project, cancel) == before
        results["changed_source_blocks_stage_and_publish"] = "PASS"

        # F. Cancelling at publication keeps the original pair and leaves no journal behind.
        cancelled = Event()
        with GodotSession(isolated, cancelled, print) as session:
            draft, _ = session.import_region(FOREST, design=True)
            moved = replace(draft, design=replace(draft.design, enemy_spawns=draft.design.enemy_spawns[:1]))
            _, receipt = session.stage_design(moved)
            cancelled.set()
            try:
                publish_pair(session, moved, receipt)
            except BridgeError as error:
                assert error.code == "CANCELLED", error
            else:
                raise AssertionError("a cancelled publication was applied")
        assert project_manifest(project, cancel) == before and recover_project(project) == []
        assert marker_count(project) == 2
        results["cancel_at_publication_keeps_original"] = "PASS"

        # G. A wizard region with enemies is published as a new pair, reloaded and edited.
        new_region = "data/content/regions/v6_enemy_field.tres"
        new_scene = "world/adventure/v6_enemy_field.tscn"
        draft = create_region("v6_enemy_field", "V6 enemy field", 1200, 600, "flat", 4, RegionEnvironment())
        assert draft.design.enemy_spawns is None
        slot = draft.design.spawn_points[0].position
        spawns = (EnemySpawn("enemy_field_frog", "field_frog", "frog", (slot[0] + 420, slot[1])),
                  EnemySpawn("enemy_field_beetle", "field_beetle", "sewer_beetle", (slot[0] + 640, slot[1]), False))
        draft = replace(draft, design=replace(draft.design, enemy_spawns=spawns))
        assert json.loads(encode(draft))["schema_version"] == 6
        with GodotSession(isolated, cancel, print) as session:
            saved, receipt = session.stage_design(draft)
            scene, definition = publish_pair(session, draft, receipt)
            assert file_hash(scene) == saved.source.scene_hash and file_hash(definition) == saved.source.region_hash
            results["new_region_runtime"] = receipt["runtime"]["overall"]
        reopened, _ = reload(isolated, new_region)
        assert reopened.source == saved.source
        assert {row.id: row for row in reopened.design.enemy_spawns} == {row.id: row for row in spawns}
        assert declared_enemies(project, new_region) == ["frog", "sewer_beetle"] and marker_count(project, new_scene) == 2
        _, edited, receipt = publish(isolated, lambda item: replace(item, design=replace(item.design, enemy_spawns=(
            replace(item.design.enemy_spawns[0], position=(slot[0] + 460, slot[1])),
            replace(item.design.enemy_spawns[1], enabled=True)))), new_region)
        assert (edited.source.scene_uid, edited.source.region_uid) == (saved.source.scene_uid, saved.source.region_uid)
        again, _ = reload(isolated, new_region)
        assert by_spawn(again.design) == {"field_frog": ("frog", True, (slot[0] + 460, slot[1])),
                                          "field_beetle": ("sewer_beetle", True, (slot[0] + 640, slot[1]))}
        results["new_region_with_enemies_published_and_edited"] = "PASS"

        # H. Repeated publish and reload: nothing drifts and every Godot process exits cleanly.
        trips = []
        for index in range(round_trips):
            shift = 8 if index % 2 == 0 else -8

            def nudge(draft, shift=shift):
                first, second = draft.design.enemy_spawns
                return replace(draft, design=replace(draft.design, enemy_spawns=(
                    replace(first, position=(first.position[0] + shift, first.position[1])),
                    replace(second, enabled=not second.enabled))))

            _, staged, receipt = publish(isolated, nudge)
            loaded, _ = reload(isolated)
            assert loaded.design == staged.design and loaded.objects == staged.objects and loaded.source == staged.source
            assert (loaded.source.scene_uid, loaded.source.region_uid) == (scene_uid, region_uid)
            assert declared_enemies(project) == ["frog"] and marker_count(project) == 2
            assert decode(encode(loaded)) == loaded
            trips.append({"index": index + 1, "runtime": receipt["runtime"]["overall"], "scene_hash": loaded.source.scene_hash})
            print(f"V6 ROUND TRIP {index + 1}/{round_trips} PASS", flush=True)
        results["round_trips"] = trips

        assert project_manifest(settings.project, cancel) == source_manifest, "the real project changed"
        results["original_project_unchanged"] = "PASS"
    evidence = settings.work / "v6-enemy-spawn-check.json"
    write_json(evidence, results)
    print("V6 ENEMY SPAWN DATA SAFETY PASS", evidence, flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--round-trips", type=int, default=2)
    args = parser.parse_args()
    data_safety(ProjectSettings(Path.cwd(), args.godot, args.artifacts), args.round_trips)


if __name__ == "__main__":
    main()
