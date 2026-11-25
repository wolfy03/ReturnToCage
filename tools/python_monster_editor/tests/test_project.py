"""Checks that read project files. They use the real repository and small throwaway projects."""

import os
import shutil
import struct
import zlib

import pytest

from conftest import PROJECT, edit, load
from rtcmonster import FAIL, WARNING, DocumentError, new_document, validate
from rtcmonster.project import (bind_sources, content_ids, inspect_image, png_size, published_monsters,
                                resolve_project_file, source_states)
from rtcmonster.spec import safe_relative_path


def png(path, width, height):
    def chunk(kind, body):
        return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body))
    rows = b"".join(b"\x00" + b"\x00\x00\x00\x00" * width for _ in range(height))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


@pytest.fixture
def mini(tmp_path):
    """A project folder with one published enemy, one item and one sprite strip."""
    root = tmp_path / "project"
    (root / "data/content/enemies").mkdir(parents=True)
    (root / "data/content/items").mkdir(parents=True)
    (root / "data/content/loot").mkdir(parents=True)
    (root / "data/content/enemies/ant.tres").write_text('[resource]\nid = &"ant"\ndisplay_name = "Worker Ant"\n',
                                                        encoding="utf-8")
    (root / "data/content/items/crumb.tres").write_text('[resource]\nid = &"crumb"\n', encoding="utf-8")
    (root / "data/content/loot/ant_loot.tres").write_text('[resource]\nid = &"ant_loot"\n', encoding="utf-8")
    png(root / "art/idle.png", 128, 32)
    return root


def with_art(document, width=128, height=32, digest=""):
    def change(data):
        data["assets"]["images"] = [{"id": "idle_strip", "path": "art/idle.png", "width": width, "height": height,
                                     "sha256": digest}]
    return edit(document, change)


@pytest.mark.parametrize("value", ["", "/abs/a.png", "C:/a.png", "a\\b.png", "../a.png", "a/../b.png", "a//b.png",
                                   "./a.png", "a/b /c.png", "a/b./c.png", "a.png ", "a\x00.png", "a?.png", 7])
def test_unsafe_relative_paths_are_rejected(value):
    with pytest.raises(DocumentError):
        safe_relative_path(value, (".png",))


def test_published_monsters_are_the_enemy_definitions_the_map_editor_lists():
    assert published_monsters(PROJECT) == {
        "frog": {"display_name": "Trail Frog", "path": "data/content/enemies/frog.tres"},
        "sewer_beetle": {"display_name": "Sewer Beetle", "path": "data/content/enemies/sewer_beetle.tres"}}
    assert "moss_fiber" in content_ids(PROJECT, "items") and "frog_loot" in content_ids(PROJECT, "loot")
    assert published_monsters(PROJECT / "no_such_folder") == {}


def test_a_draft_cannot_reuse_a_published_monster_id(mini):
    assert "duplicate_monster_id" in validate(new_document("ant", "Copy"), mini).codes()
    assert "duplicate_monster_id" not in validate(new_document("bee", "New"), mini).codes()
    # The prototype is not game content, so the map editor's catalog does not list it.
    assert "sewer_rat_prototype" not in published_monsters(PROJECT)


def test_a_bound_document_must_keep_the_id_of_its_definition(beetle):
    assert "binding_id_mismatch" in validate(edit(beetle, lambda d: d.update(monster_id="renamed_beetle")),
                                             PROJECT).codes()


def test_loot_references_are_checked_against_the_project(mini):
    document = new_document("bee", "Bee")
    missing_table = edit(document, lambda d: d["loot"].update(loot_table_id="bee_loot"))
    assert "unknown_loot_table" in validate(missing_table, mini).codes()
    known_table = edit(document, lambda d: d["loot"].update(loot_table_id="ant_loot"))
    assert not validate(known_table, mini).select(FAIL)

    def rows(item):
        return lambda d: d["loot"].update(loot_table_id="bee_loot", entries=[
            {"item_id": item, "weight": 1, "min_amount": 1, "max_amount": 1}])
    assert "unknown_item" in validate(edit(document, rows("gold")), mini).codes()
    assert not validate(edit(document, rows("crumb")), mini).select(FAIL)


def test_images_are_checked_against_the_files(mini):
    document = new_document("bee", "Bee")
    width, height, digest = inspect_image(mini, "art/idle.png")
    assert (width, height) == (128, 32)
    assert validate(with_art(document, digest=digest), mini).status("assets") == "PASS"
    assert "asset_size_mismatch" in validate(with_art(document, 64, 32), mini).codes()
    assert validate(with_art(document, digest="0" * 64), mini).select(WARNING, "assets", "asset_changed")
    missing = edit(with_art(document), lambda d: d["assets"]["images"][0].update(path="art/none.png"))
    assert "asset_missing" in validate(missing, mini).codes()
    (mini / "art/idle.png").write_bytes(b"not an image at all, just text")
    assert "asset_invalid" in validate(with_art(document), mini).codes()


def test_an_image_changed_on_disk_is_noticed(mini):
    document = with_art(new_document("bee", "Bee"), digest=inspect_image(mini, "art/idle.png")[2])
    assert not validate(document, mini).select(WARNING, "assets")
    png(mini / "art/idle.png", 128, 32)
    (mini / "art/idle.png").write_bytes((mini / "art/idle.png").read_bytes() + b"\x00")
    assert validate(document, mini).select(WARNING, "assets", "asset_changed")


def test_oversized_and_malformed_images_are_refused(tmp_path):
    png(tmp_path / "wide.png", 8, 8)
    data = bytearray((tmp_path / "wide.png").read_bytes())
    data[16:20] = struct.pack(">I", 9000)
    (tmp_path / "wide.png").write_bytes(bytes(data))
    with pytest.raises(DocumentError, match="limit"):
        png_size(tmp_path / "wide.png")
    (tmp_path / "short.png").write_bytes(b"\x89PNG")
    with pytest.raises(DocumentError, match="not a PNG"):
        png_size(tmp_path / "short.png")


def test_files_outside_the_project_cannot_be_reached(mini, tmp_path):
    png(tmp_path / "outside.png", 4, 4)
    for name in ("../outside.png", str(tmp_path / "outside.png"), "art/../../outside.png"):
        with pytest.raises(DocumentError):
            resolve_project_file(mini, name, (".png",), 1024)
    with pytest.raises(DocumentError, match="exceeds"):
        resolve_project_file(mini, "art/idle.png", (".png",), 16)
    link = mini / "linked"
    try:
        os.symlink(tmp_path, link, target_is_directory=True)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symbolic links are not available: {error}")
    with pytest.raises(DocumentError, match="linked"):
        resolve_project_file(mini, "linked/outside.png", (".png",), 1024)


def test_source_bindings_notice_changed_and_missing_project_files(tmp_path, beetle):
    project = tmp_path / "copy"
    for row in beetle.data["source_binding"]["files"]:
        target = project / row["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(PROJECT / row["path"], target)
    assert {state for _, state in source_states(beetle, project)} == {"unchanged"}
    assert validate(beetle, PROJECT).status("compatibility") == "PASS"

    scene = project / "gameplay/actors/enemies/sewer_beetle.tscn"
    scene.write_bytes(scene.read_bytes().replace(b"Vector2(34, 22)", b"Vector2(40, 22)"))
    (project / "gameplay/actors/enemies/attack_state.gd").unlink()
    states = dict(source_states(beetle, project))
    assert states["gameplay/actors/enemies/sewer_beetle.tscn"] == "modified"
    assert states["gameplay/actors/enemies/attack_state.gd"] == "missing"
    report = validate(beetle, project)
    assert report.select(WARNING, "compatibility", "source_changed")
    assert report.select(FAIL, "compatibility", "source_missing")

    scene_only = [row["path"] for row in beetle.data["source_binding"]["files"] if row["path"].endswith(".tscn")]
    rebound = bind_sources(beetle, project, scene_only)
    assert {state for _, state in source_states(rebound, project)} == {"unchanged"}


def test_the_examples_only_reference_real_project_files():
    for name in ("sewer_beetle", "frog"):
        document = load(name)
        binding = document.data["source_binding"]
        paths = [row["path"] for row in binding["files"]] + [row["path"] for row in document.data["assets"]["images"]]
        paths += [binding[key] for key in ("definition_path", "actor_scene_path", "animation_profile_path",
                                           "sprite_frames_path", "loot_table_path")]
        assert all((PROJECT / path).is_file() for path in paths)
        assert {binding[key] for key in ("definition_path", "actor_scene_path", "animation_profile_path",
                                         "sprite_frames_path", "loot_table_path")} <= {
            row["path"] for row in binding["files"]}
