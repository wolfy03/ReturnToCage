"""Compare Qt and Godot terrain pixels and verify import, runtime and publication."""

import argparse
from dataclasses import asdict, replace
from pathlib import Path
import shutil
import tempfile
from threading import Event

from check_scene_bridge import traversal
from check_v4_region_bridge import SEWER
from godot_bridge import ENGINE_ERROR, VERSION, GodotSession, ProjectSettings, project_manifest, run_child, write_json
from publish_region import publish_pair, recover_project
from terrain_atlas import read_theme

PROJECT = Path(__file__).resolve().parents[2]


def render(godot, evidence, renderer):
    from PySide6.QtCore import QRectF
    from PySide6.QtGui import QImage, QPainter
    from PySide6.QtWidgets import QApplication
    from terrain_renderer import TerrainCache, draw_terrain

    application = QApplication([])
    cache = TerrainCache()
    cases = []
    specs = [
        (16, 11, 0), (128, 128, 0), (192, 192, 0), (256, 128, 0),
        (512, 128, 0), (768, 256, 0), (24, 256, 0), (256, 128, 90),
    ]
    surface = read_theme(PROJECT, "sewer_concrete")
    forest = read_theme(PROJECT, "forest_ground")
    for index, (w, h, rotation) in enumerate(specs):
        atlas = forest if index % 2 else surface
        cw, ch = (w if not rotation else h) + 16, (h if not rotation else w) + 16
        cases.append({**asdict(atlas), "size": [w, h], "rotation": rotation,
                      "canvas": [cw, ch], "one_way": index % 2 != 0})
        output = QImage(cw, ch, QImage.Format.Format_ARGB32)
        output.fill(0)
        painter = QPainter(output)
        painter.translate(cw / 2, ch / 2)
        painter.rotate(rotation)
        rect = QRectF(-w / 2, -h / 2, w, h)
        draw_terrain(painter, rect, rect, atlas, cache.lookup(PROJECT, atlas))
        painter.end()
        assert output.save(str(evidence / f"qt-{index}.png"))
    write_json(evidence / "cases.json", cases)
    with tempfile.TemporaryDirectory(prefix="rtc-terrain-render-") as directory:
        project = Path(directory)
        (project / "project.godot").write_text(
            f'config_version=5\n[rendering]\nrenderer/rendering_method="{renderer}"\n', encoding="utf-8")
        for relative in ("assets/terrain", "world/adventure"):
            (project / relative).mkdir(parents=True)
        for relative in [*(f"assets/terrain/{item.theme_id}.png" for item in (surface, forest)),
                         "world/adventure/field_platform.gd", "world/adventure/field_platform.tscn"]:
            shutil.copyfile(PROJECT / relative, project / relative)
        shutil.copyfile(PROJECT / "tools/map_bridge/terrain_render_fixture.gd", project / "fixture.gd")
        version_code, version = run_child([str(godot), "--version"], project, None, evidence, "version", Event(), 30)
        assert version_code == 0 and VERSION in version
        command = [str(godot), "--path", str(project), "--rendering-method", renderer,
                   "--resolution", "320x200", "--script", "res://fixture.gd", "--", str(evidence)]
        code, logs = run_child(command, project, None, evidence, "terrain-render", Event(), 90)
        assert code == 0 and "TERRAIN RENDER PASS" in logs and not ENGINE_ERROR.search(logs), logs
    for index in range(len(specs)):
        qt = QImage(str(evidence / f"qt-{index}.png"))
        gd = QImage(str(evidence / f"godot-{index}.png"))
        assert qt.size() == gd.size() and not gd.isNull()
        for y in range(qt.height()):
            for x in range(qt.width()):
                q, g = qt.pixelColor(x, y), gd.pixelColor(x, y)
                assert q.alpha() == g.alpha(), (index, x, y, q.getRgb(), g.getRgb())
                if q.alpha():
                    assert all(abs(a - b) <= 2 for a, b in zip(q.getRgb(), g.getRgb())), (
                        index, x, y, q.getRgb(), g.getRgb())
    assert application is QApplication.instance()
    print(f"TERRAIN PIXEL PARITY PASS ({len(specs)} captures)")


def bridge(godot, evidence):
    cancel = Event()
    with tempfile.TemporaryDirectory(prefix="rtc-terrain-publish-") as directory:
        project = Path(directory)
        original_manifest = project_manifest(PROJECT, cancel, project)
        settings = ProjectSettings(project, godot, evidence)
        with GodotSession(settings, cancel, print) as session:
            draft, original = session.import_region(SEWER, design=True)
            binding = next(item for item in draft.source.bindings if item.path.endswith("/WestPlatform"))
            path = binding.path
            platform = next(obj for obj in draft.objects if obj.id == binding.id)
            terrain = replace(read_theme(project, "sewer_concrete"), margins=(8, 6, 8, 5))
            assert platform.properties.terrain != terrain
            edited = replace(draft, objects=tuple(replace(obj, properties=replace(obj.properties, terrain=terrain))
                                                  if obj.id == platform.id else obj for obj in draft.objects))
            saved, receipt = session.stage_design(edited)
            assert receipt["region_hash"] == original["region_hash"]
            assert receipt["scene_uid"] == original["scene_uid"]
            assert receipt["node_count"] == original["node_count"]
            assert saved.source.bindings == draft.source.bindings
            old_nodes, new_nodes = original["scene_state"]["nodes"], receipt["scene_state"]["nodes"]
            assert {name for name in old_nodes if old_nodes[name] != new_nodes[name]} == {path}
            assert receipt["runtime"]["overall"] in ("PASS", "PASS_WITH_WARNINGS")
            publish_pair(session, edited, receipt)
        assert not recover_project(project)
        with GodotSession(settings, cancel, print) as session:
            reopened, current = session.import_region(SEWER, design=True)
            assert reopened == saved
            _, noop = session.stage_design(reopened)
            assert all(current[key] == noop[key] for key in ("scene_hash", "region_hash", "scene_uid", "region_uid"))
        with GodotSession(settings, cancel, print) as session:
            legacy_view, _ = session.import_region(SEWER)
            assert legacy_view.design is None and legacy_view.objects == saved.objects
            unchanged, receipt = session.stage_export(legacy_view)
            assert unchanged.source.scene_hash == saved.source.scene_hash
            assert receipt["source_hash"] == receipt["output_hash"]
            assert traversal(session, "terrain-appearance-only") == [5, 25, 11]
        assert project_manifest(PROJECT, cancel) == original_manifest
    print("TERRAIN SCENE ROUND-TRIP AND PAIR PUBLISH PASS")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--artifacts", required=True, type=Path)
    parser.add_argument("--only", choices=("render", "bridge"))
    parser.add_argument("--renderer", choices=("gl_compatibility", "forward_plus"), default="gl_compatibility")
    args = parser.parse_args()
    args.artifacts.mkdir(parents=True, exist_ok=True)
    folder = Path(tempfile.mkdtemp(prefix="terrain-", dir=args.artifacts)).resolve()
    if args.only in (None, "render"):
        render(args.godot.resolve(), folder, args.renderer)
    if args.only in (None, "bridge"):
        bridge(args.godot.resolve(), folder)


if __name__ == "__main__":
    main()
