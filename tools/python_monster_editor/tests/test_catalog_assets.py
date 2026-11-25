"""GATE C: the catalog reports every problem and keeps everything else; images are checked level by level."""

import os
import struct
import zlib

import pytest

from conftest import PROJECT
from rtcmonster import FAIL, MonsterDocument, monster_catalog, new_document, scan_content, validate, write_document
from rtcmonster import catalog, png
from rtcmonster.project import content_ids, inspect_image, png_size, published_monsters
from rtcmonster.schema import MAX_IMAGE_EXTENT


def chunk(kind, body, crc=None):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) if crc is None else crc)


def make_png(width=8, height=8, color=6, depth=8, interlace=0, rows=None, extra=b"", idat_parts=1, palette=False):
    channels = png.CHANNELS[color]
    row_bytes = (width * channels * depth + 7) // 8
    if rows is None:
        if interlace:
            info = png.PngInfo(width, height, depth, color, True)
            rows = b"".join((b"\x00" + b"\x7f" * (length - 1)) * count for length, count in png._expected_rows(info))
        else:
            rows = b"".join(bytes([y % 5]) + bytes(row_bytes) for y in range(height))
    stream = zlib.compress(rows)
    size = max(1, len(stream) // idat_parts)
    parts = [stream[index:index + size] for index in range(0, len(stream), size)]
    return (png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color, 0, 0, interlace))
            + (chunk(b"PLTE", b"\x00\x00\x00\xff\xff\xff") if palette else b"") + extra
            + b"".join(chunk(b"IDAT", part) for part in parts) + chunk(b"IEND", b""))


def tres(path, content_id, name=None, uid=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    header = f'[gd_resource type="Resource" format=3{f" uid=\"{uid}\"" if uid else ""}]\n'
    path.write_bytes((header + f'[resource]\nid = &"{content_id}"\n'
                      + (f'display_name = "{name}"\n' if name else "")).encode("utf-8"))


@pytest.fixture
def project(tmp_path):
    root = tmp_path / "project"
    for folder in ("enemies", "items", "loot"):
        (root / "data/content" / folder).mkdir(parents=True)
    tres(root / "data/content/enemies/ant.tres", "ant", "Worker Ant", "uid://abc123")
    tres(root / "data/content/enemies/bee.tres", "bee", "Bee")
    (root / "art").mkdir()
    return root


# ------------------------------------------------------------------------------------------------- catalog
def test_a_clean_folder_scans_into_entries_with_hash_uid_and_name(project):
    scan = scan_content(project, "enemies")
    assert scan.available and scan.problems == () and scan.duplicates == {}
    ant = scan.entries["ant"]
    assert (ant.path, ant.display_name, ant.uid) == ("data/content/enemies/ant.tres", "Worker Ant", "uid://abc123")
    assert len(ant.sha256) == 64 and scan.entries["bee"].uid == ""
    assert [path for path, _ in scan.files] == ["data/content/enemies/ant.tres", "data/content/enemies/bee.tres"]


def test_the_real_project_catalog_is_clean_and_matches_the_map_editor_view():
    scan = scan_content(PROJECT, "enemies")
    assert scan.available and scan.problems == () and set(scan.entries) == {"frog", "sewer_beetle"}
    assert all(entry.uid == "" or entry.uid.startswith("uid://") for entry in scan.entries.values())
    catalog_ = monster_catalog(PROJECT)
    assert not catalog_.registry_checked
    assert {entry.registration for entry in catalog_.entries} == {catalog.DISCOVERED}


def test_duplicate_ids_report_every_file_and_none_of_them_wins(project):
    tres(project / "data/content/enemies/ant_b.tres", "ant")
    tres(project / "data/content/enemies/ant_c.tres", "ant")
    scan = scan_content(project, "enemies")
    assert set(scan.entries) == {"bee"}
    assert scan.duplicates == {"ant": ("data/content/enemies/ant.tres", "data/content/enemies/ant_b.tres",
                                       "data/content/enemies/ant_c.tres")}
    problems = [problem for problem in scan.problems if problem.code == catalog.DUPLICATE_ID]
    assert sorted(problem.path for problem in problems) == list(scan.duplicates["ant"])
    assert all(problem.id == "ant" and "also defined by" in problem.detail for problem in problems)
    assert "ant" not in published_monsters(project) and "ant" not in content_ids(project, "enemies")
    catalog_ = monster_catalog(project)
    assert not catalog_.is_id_free("ant") and not catalog_.is_id_free("bee") and catalog_.is_id_free("wasp")
    assert catalog_.find("ant") == []                         # nothing to import: no file is authoritative
    # A draft and a bound document both learn about it.
    assert "catalog_duplicate_id" in validate(new_document("ant", "Mine"), project).codes()
    assert "catalog_duplicate_id" not in validate(new_document("wasp", "Mine"), project).codes()


def test_one_bad_file_is_a_recorded_problem_and_the_rest_is_kept(project):
    enemies = project / "data/content/enemies"
    (enemies / "latin.tres").write_bytes(b'[resource]\nid = &"x"\n\xff\xfe')
    (enemies / "noid.tres").write_bytes(b"[resource]\nscript = null\n")
    (enemies / "badid.tres").write_bytes(b'[resource]\nid = &"Not Valid"\n')
    (enemies / "huge.tres").write_bytes(b"x" * (catalog.MAX_TEXT_RESOURCE_BYTES + 1))
    (enemies / "folder.tres").mkdir()
    (enemies / "notes.txt").write_text("ignored", encoding="utf-8")
    scan = scan_content(project, "enemies")
    assert set(scan.entries) == {"ant", "bee"} and scan.available
    assert {(problem.code, problem.path.rsplit("/", 1)[1]) for problem in scan.problems} == {
        (catalog.INVALID_ENCODING, "latin.tres"), (catalog.MISSING_ID, "noid.tres"),
        (catalog.INVALID_ID, "badid.tres"), (catalog.TOO_LARGE, "huge.tres"),
        (catalog.NOT_A_REGULAR_FILE, "folder.tres")}
    assert set(published_monsters(project)) == {"ant", "bee"}
    report = validate(new_document("wasp", "Wasp"), project)
    assert len(report.select("WARNING", "references", "catalog_problem")) == 5 and not report.select(FAIL)


def test_a_linked_resource_is_not_followed(project, tmp_path):
    outside = tmp_path / "outside.tres"
    tres(outside, "smuggled")
    try:
        os.symlink(outside, project / "data/content/enemies/link.tres")
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symbolic links are not available: {error}")
    scan = scan_content(project, "enemies")
    assert "smuggled" not in scan.entries
    assert (catalog.NOT_A_REGULAR_FILE, "data/content/enemies/link.tres") in {
        (problem.code, problem.path) for problem in scan.problems}


def test_an_unavailable_folder_differs_from_an_empty_one(project, tmp_path):
    empty = scan_content(project, "loot")
    assert empty.available and empty.entries == {} and empty.problems == ()
    missing = scan_content(tmp_path / "nowhere", "enemies")
    assert not missing.available and [problem.code for problem in missing.problems] == [catalog.FOLDER_UNAVAILABLE]
    assert published_monsters(tmp_path / "nowhere") == {}
    assert not monster_catalog(tmp_path / "nowhere").available


def test_found_on_disk_is_not_registered_in_godot(project):
    assert {entry.registration for entry in monster_catalog(project).entries} == {catalog.DISCOVERED}
    verified = monster_catalog(project, registry_ids={"ant"})
    assert verified.registry_checked
    assert {entry.monster_id: entry.registration for entry in verified.entries} == {
        "ant": catalog.REGISTRY_VERIFIED, "bee": catalog.NOT_IN_REGISTRY}


def test_drafts_are_listed_apart_from_game_content(project, tmp_path):
    drafts = tmp_path / "drafts"
    drafts.mkdir()
    write_document(drafts / "wasp.rtcmonster", new_document("wasp", "Wasp"))
    write_document(drafts / "ant.rtcmonster", new_document("ant", "My Ant"))
    (drafts / "broken.rtcmonster").write_bytes(b"{")
    result = monster_catalog(project, drafts=sorted(drafts.glob("*.rtcmonster")))
    by_source = {(entry.monster_id, entry.source, entry.registration) for entry in result.entries}
    assert by_source == {("ant", "game", catalog.DISCOVERED), ("bee", "game", catalog.DISCOVERED),
                         ("ant", "draft", catalog.DRAFT), ("wasp", "draft", catalog.DRAFT)}
    assert {problem.code for problem in result.problems} == {catalog.DRAFT_UNREADABLE,
                                                             catalog.DRAFT_SHADOWS_PUBLISHED}
    assert len(result.find("ant")) == 2 and not result.is_id_free("wasp")


def test_a_scan_fingerprint_tells_what_changed(project):
    first = scan_content(project, "enemies")
    assert scan_content(project, "enemies").fingerprint == first.fingerprint
    tres(project / "data/content/enemies/wasp.tres", "wasp")
    tres(project / "data/content/enemies/bee.tres", "bee", "Queen Bee")
    (project / "data/content/enemies/ant.tres").unlink()
    second = scan_content(project, "enemies")
    assert second.fingerprint != first.fingerprint
    assert second.changes_since(first) == (("data/content/enemies/wasp.tres",), ("data/content/enemies/ant.tres",),
                                           ("data/content/enemies/bee.tres",))


def test_crlf_resources_are_read_like_lf_ones(project):
    (project / "data/content/enemies/crlf.tres").write_bytes(
        b'[resource]\r\nid = &"moth"\r\ndisplay_name = "Moth"\r\n')
    entry = scan_content(project, "enemies").entries["moth"]
    assert entry.display_name == "Moth"


# -------------------------------------------------------------------------------------------------- images
def image_report(project, payload, width=8, height=8):
    (project / "art/x.png").write_bytes(payload)
    data = new_document("wasp", "Wasp").to_dict()
    data["assets"]["images"] = [{"id": "strip", "path": "art/x.png", "width": width, "height": height}]
    return validate(MonsterDocument(data), project)


GOOD = {
    "rgba": make_png(), "opaque_rgb": make_png(color=2), "grey": make_png(color=0), "grey_alpha": make_png(color=4),
    "sixteen_bit": make_png(depth=16), "one_bit": make_png(color=0, depth=1, width=13),
    "indexed": make_png(color=3, palette=True), "interlaced": make_png(interlace=1, width=9, height=7),
    "split_idat": make_png(width=64, height=64, idat_parts=5), "one_pixel": make_png(1, 1),
    "ancillary_chunks": make_png(extra=chunk(b"tEXt", b"Comment\x00hello") + chunk(b"gAMA", b"\x00\x00\xb1\x8f")),
    "transparent": make_png(rows=b"".join(b"\x00" + b"\x00\x00\x00\x00" * 8 for _ in range(8))),
}
BROKEN = {
    "header_only": (png.INTEGRITY, png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0))),
    "corrupt_idat": (png.INTEGRITY, make_png()[:41] + bytes(reversed(make_png()[41:60])) + make_png()[60:]),
    "idat_is_not_zlib": (png.INTEGRITY, png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0))
                         + chunk(b"IDAT", b"definitely not deflate") + chunk(b"IEND", b"")),
    "crc_error": (png.INTEGRITY, png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0))
                  + chunk(b"IDAT", zlib.compress(bytes(8 * 33)), crc=1) + chunk(b"IEND", b"")),
    "truncated": (png.INTEGRITY, make_png()[:-9]),
    "too_few_rows": (png.INTEGRITY, make_png(rows=b"\x00" + bytes(32))),
    "too_many_rows": (png.INTEGRITY, make_png(rows=bytes(33 * 9))),
    "bad_filter_type": (png.INTEGRITY, make_png(rows=b"".join(b"\x09" + bytes(32) for _ in range(8)))),
    "no_iend": (png.INTEGRITY, make_png()[:-12]),
    "data_after_iend": (png.INTEGRITY, make_png() + b"trailing"),
    "indexed_without_palette": (png.INTEGRITY, make_png(color=3)),
    "missing_idat": (png.INTEGRITY, png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0))
                     + chunk(b"IEND", b"")),
    "bad_signature": (png.HEADER, b"\x89PNX" + make_png()[4:]),
    "not_an_image": (png.HEADER, b"GIF89a" + bytes(64)),
    "ihdr_missing": (png.HEADER, png.SIGNATURE + chunk(b"IDAT", bytes(13)) + bytes(16)),
    "invalid_colour_type": (png.HEADER, png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 5, 0, 0, 0))
                            + chunk(b"IEND", b"")),
    "zero_width": (png.HEADER, png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 0, 8, 8, 6, 0, 0, 0))
                   + chunk(b"IEND", b"")),
    "oversized": (png.HEADER, png.SIGNATURE
                  + chunk(b"IHDR", struct.pack(">IIBBBBB", MAX_IMAGE_EXTENT + 1, 8, 8, 6, 0, 0, 0)) + chunk(b"IEND", b"")),
    "empty_file": (png.HEADER, b""),
}


@pytest.mark.parametrize("label", list(GOOD))
def test_intact_pngs_of_every_format_pass_the_integrity_level(project, label):
    payload = GOOD[label]
    info = png.read_header(payload, MAX_IMAGE_EXTENT)
    png.verify(payload, info)
    report = image_report(project, payload, info.width, info.height)
    assert report.status("assets") == "PASS", [item for item in report.findings if item.domain == "assets"]
    assert GOOD["rgba"] and png.read_header(GOOD["rgba"], MAX_IMAGE_EXTENT).has_alpha
    assert not png.read_header(GOOD["opaque_rgb"], MAX_IMAGE_EXTENT).has_alpha


@pytest.mark.parametrize("label", list(BROKEN))
def test_each_kind_of_damage_is_reported_at_its_level(project, label):
    level, payload = BROKEN[label]
    code = "asset_corrupt" if level == png.INTEGRITY else "asset_invalid"
    report = image_report(project, payload)
    finding, = report.select(FAIL, "assets")
    assert finding.code == code and finding.remedy == "project" and finding.related == ("art/x.png",)
    if level == png.INTEGRITY:
        assert png_size(project / "art/x.png") == (8, 8)       # the header alone would have passed
    with pytest.raises(png.PngError) as caught:
        inspect_image(project, "art/x.png")
    assert caught.value.level == level


def test_a_compression_bomb_stops_at_the_promised_size(project):
    bomb = (png.SIGNATURE + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(64 * 1024 * 1024), 9)) + chunk(b"IEND", b""))
    assert len(bomb) < 200_000
    with pytest.raises(png.PngError, match="longer than the image size"):
        png.verify(bomb, png.read_header(bomb, MAX_IMAGE_EXTENT))


def test_godot_import_is_never_claimed_by_the_static_check(project):
    report = image_report(project, GOOD["rgba"])
    assert report.status("assets") == "PASS"
    assert report.select("NOT_EVALUATED", "runtime", "asset_godot_import_not_run")
    without_project = validate(MonsterDocument({**new_document("wasp", "W").to_dict(), "assets": {"images": [
        {"id": "s", "path": "art/x.png", "width": 8, "height": 8}]}}))
    assert without_project.status("assets") == "NOT_EVALUATED"
    assert not validate(new_document("wasp", "W")).select(code="asset_godot_import_not_run")   # no images, no claim


def test_rects_are_checked_against_the_declared_and_the_real_size(project):
    (project / "art/x.png").write_bytes(make_png(32, 16))
    data = new_document("wasp", "Wasp").to_dict()
    data["assets"]["images"] = [{"id": "strip", "path": "art/x.png", "width": 32, "height": 16}]
    data["animations"]["clips"] = [{"id": "idle", "loop": True, "frames": [
        {"image": "strip", "rect": [16, 0, 32, 16]}]}]
    assert "source_rect_outside_image" in validate(MonsterDocument(data), project).codes()
    data["assets"]["images"][0]["width"] = 64           # a lie about the size hides the rect error ...
    report = validate(MonsterDocument(data), project)
    assert "asset_size_mismatch" in report.codes()       # ... and is caught against the real file


def test_fixing_the_file_invalidates_the_old_result(project):
    report = image_report(project, BROKEN["truncated"][1])
    document = MonsterDocument({**new_document("wasp", "Wasp").to_dict(), "assets": {"images": [
        {"id": "strip", "path": "art/x.png", "width": 8, "height": 8}]}})
    assert report.status("assets") == FAIL and report.is_current(document)
    (project / "art/x.png").write_bytes(GOOD["rgba"])
    assert report.stale_inputs() == ["art/x.png"] and not report.is_current(document)
    assert validate(document, project).status("assets") == "PASS"


def test_every_shipped_enemy_strip_passes_the_integrity_level():
    strips = sorted((PROJECT / "assets/characters/enemies").glob("*/*.png"))
    assert len(strips) == 13
    for path in strips:
        payload = path.read_bytes()
        png.verify(payload, png.read_header(payload, MAX_IMAGE_EXTENT))
