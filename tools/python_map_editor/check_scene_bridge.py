"""Exercise Scene publication and traversal on isolated copies of the Sewer."""

import argparse
from dataclasses import replace
from pathlib import Path
import shutil
from threading import Event
import tempfile
import traceback

from document import decode, encode
from godot_bridge import BridgeError, GodotSession, ProjectSettings, file_hash, project_manifest, read_json, write_json
from objects import MapObject, ObjectProperties
from publish_region import publish_copy, publish_scene

REGION = "data/content/regions/sewer_region.tres"
SCENE = "world/adventure/sewer_region.tscn"
TEXTURE = "assets/backgrounds/clouds_far_atlas_2048x1152.png"
TRAVERSAL_FOLDER = "res://.godot/rtc_traversal/04b3c107b96e4759b76dd552e737c4ab"


def traversal(session, label):
    session._run(f"traversal-prepare-{label}", ["--scene", "res://tools/map_bridge/test_fixture.tscn", "--",
                                               "traversal"])
    request = read_json(session.stage / TRAVERSAL_FOLDER[6:] / "request.json")
    _, logs = session._run(f"traversal-{label}", ["--fixed-fps", str(request["fps"]), "--scene",
                              "res://tools/map_bridge/traversal_validation.tscn", "--", TRAVERSAL_FOLDER + "/request.json"])
    result = read_json(session.stage / TRAVERSAL_FOLDER[6:] / "result.json")
    assert "TRAVERSAL PHYSICS PASS" in logs and result["fingerprint"] == request["fingerprint"]
    assert not result["partial"] and all(route["trace"] for route in result["routes"]
                                         if route["status"] == "Verified Reachable")
    metrics = result["metrics"]
    write_json(session.evidence / f"traversal-{label}.json", result)
    return [metrics[key] for key in ("surfaces", "edges", "verified_edges")]


def transform_fixture(project, settings, cancel):
    with GodotSession(settings, cancel) as session:
        session._run("decorate", ["--scene", "res://tools/map_bridge/test_fixture.tscn", "--", "decorate"])
        for name in (SCENE, REGION):
            shutil.copyfile(session.stage / name, project / name)
    with GodotSession(settings, cancel) as session:
        document, source = session.import_region(REGION)
        assert document.source.scene_uid and document.source.region_uid
        assert any("UNSUPPORTED_TRANSFORM" in warning and "Reflected" in warning for warning in source["warnings"])
        _, decoration = next((item.path, obj) for item in document.source.bindings for obj in document.objects
                             if item.id == obj.id and obj.type == "decoration")
        platform = next(obj for obj in document.objects if obj.type == "platform" and obj.position == (420, 440))
        root_pos = decoration.position
        revised = replace(decoration, position=(root_pos[0] + 10, root_pos[1] - 15),
                          rotation=55, size=(180, 120))
        created = MapObject("new_test_platform", "platform", "terrain", (1170, 305), (110, 18),
                            properties=ObjectProperties(one_way=True))
        changed = replace(document, objects=tuple(revised if item == decoration else item for item in document.objects
                                                   if item != platform) + (created,))
        missing = replace(revised, properties=ObjectProperties(texture_path="assets/absent.png"))
        try:
            session.stage_export(replace(changed, objects=tuple(missing if item == revised else item
                                                                for item in changed.objects)))
        except BridgeError as error:
            if error.code != "RESOURCE_MISSING":
                raise
        else:
            raise AssertionError("missing texture was accepted")
        assert file_hash(project / SCENE) == document.source.scene_hash
        updated, receipt = session.stage_export(changed)
        assert receipt["region_uid"] == document.source.region_uid == updated.source.region_uid
        assert receipt["scene_uid"] == document.source.scene_uid == updated.source.scene_uid
        assert {obj.id for obj in updated.objects} == {obj.id for obj in changed.objects}
        reflected = "Decorations/Nested/Reflected"
        assert source["scene_state"]["nodes"][reflected] == receipt["scene_state"]["nodes"][reflected]
        assert file_hash(project / REGION) == document.source.region_hash
        return {**receipt, "source_preserved": True, "evidence": str(session.evidence)}


def check(project, executable, work, transformations=True):
    cancel = Event()
    original = project_manifest(project, cancel)
    path = work / "roundtrips.json"
    report = {"passed": False}
    try:
        with tempfile.TemporaryDirectory(prefix="rtc-map-integration-", dir=work) as temporary:
            directory = Path(temporary)
            fixture = directory / "하수구 원본"
            fixture.mkdir()
            assert project_manifest(project, cancel, fixture) == original
            settings = ProjectSettings(fixture, executable, work)
            with GodotSession(settings, cancel, print) as session:
                document, source = session.import_region(REGION)
                assert decode(encode(document)) == document and len(document.objects) == 5
                baseline_metrics = traversal(session, "source")
                assert baseline_metrics == [5, 25, 11], baseline_metrics
                noop, receipt = session.stage_export(document)
                assert noop == document and receipt["before_count"] == receipt["node_count"] == source["node_count"]
                assert receipt["source_hash"] == receipt["output_hash"]
                noop_metrics = traversal(session, "noop")
                assert noop_metrics == baseline_metrics
                assert project_manifest(fixture, cancel) == original
                report["noop"] = {**receipt, "traversal": noop_metrics, "evidence": str(session.evidence)}
                write_json(path, report)
            with GodotSession(settings, cancel, print) as session:
                original_west = next(obj for obj in document.objects if obj.position == (420, 440))
                west = replace(original_west, position=(452, 440), size=(256, 22))
                edited = replace(document, objects=tuple(west if obj == original_west else obj for obj in document.objects))
                updated, receipt = session.stage_export(edited)
                before = source["scene_state"]["nodes"]
                after = receipt["scene_state"]["nodes"]
                changed_nodes = sorted(node for node in before if before[node] != after[node])
                assert changed_nodes == ["Terrain/WestPlatform", "Terrain/WestPlatform/CollisionShape2D",
                                         "Terrain/WestPlatform/Visual"], changed_nodes
                assert before.keys() == after.keys()
                binding = next(item for item in updated.source.bindings if item.id == west.id)
                assert binding.world_transform[-2:] == (452, 440)
                metrics = traversal(session, "edited")
                assert metrics == [5, 26, 14], metrics
                copy = publish_copy(session, directory / "하수구 게시 복사본", document.source, receipt)
                assert file_hash(copy / SCENE) == receipt["output_hash"] and file_hash(copy / REGION) == receipt["region_hash"]
                assert project_manifest(fixture, cancel) == original
                publish_scene(session, document.source, receipt)
                expected = {**original, SCENE: receipt["output_hash"]}
                assert project_manifest(fixture, cancel) == project_manifest(copy, cancel) == expected
                assert updated.source.scene_hash == receipt["output_hash"]
                report["edited"] = {**receipt, "traversal": metrics, "changed_nodes": changed_nodes,
                                    "evidence": str(session.evidence)}
                write_json(path, report)
            if transformations:
                # The transform fixture starts from the unmodified gameplay scene.
                shutil.copyfile(project / SCENE, fixture / SCENE)
                report["transform"] = transform_fixture(fixture, settings, cancel)
            report["passed"] = project_manifest(project, cancel) == original
    except Exception:
        report["error"] = traceback.format_exc()
        print(report["error"])
    finally:
        write_json(path, report)
    return 0 if report["passed"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--project", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--core-only", action="store_true", help="Run the two baseline Sewer round-trips")
    args = parser.parse_args()
    parent = args.artifacts.resolve()
    parent.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix="scene-bridge-", dir=parent))
    print(f"BRIDGE EVIDENCE {evidence}", flush=True)
    return check(args.project.resolve(), args.godot, evidence, not args.core_only)


if __name__ == "__main__":
    raise SystemExit(main())
