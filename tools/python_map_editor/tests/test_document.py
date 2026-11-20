from pathlib import Path

import pytest

from document import (
    DocumentConflict, DocumentError, MapDocument, decode, encode, read_document, write_document,
)


def test_utf8_round_trip(tmp_path):
    draft = MapDocument("sewer_draft", "하수구", 1600, 910)
    path = tmp_path / "sewer.rtcmap"
    revision = write_document(path, draft)
    assert read_document(path) == (draft, revision)
    assert "하수구" in path.read_text(encoding="utf-8")


@pytest.mark.parametrize("text", [
    b"not JSON",
    b'{"schema_version": true}',
    b'{"schema_version": 2}',
    b'{"schema_version": 1, "schema_version": 1}',
    b'{"schema_version": 1, "region_id": "a", "display_name": "", "width": true, "height": 900}',
    b'{"schema_version": 1, "region_id": "a", "display_name": "", "width": 1600, "height": 900, "objects": []}',
])
def test_rejects_invalid_or_unknown_data(text):
    with pytest.raises(DocumentError):
        decode(text)


@pytest.mark.parametrize("region_id", ["Sewer", "sewer__area", "../sewer", ""])
def test_region_id_must_match_godot_naming(region_id):
    with pytest.raises(DocumentError):
        MapDocument(region_id)


def test_new_save_cannot_overwrite(tmp_path):
    path = tmp_path / "existing.rtcmap"
    write_document(path, MapDocument())
    before = path.read_bytes()
    with pytest.raises(DocumentConflict):
        write_document(path, MapDocument("overwrite"))
    assert path.read_bytes() == before


def test_external_change_rejects_stale_save(tmp_path):
    path = tmp_path / "draft.rtcmap"
    revision = write_document(path, MapDocument())
    changed = MapDocument("external")
    path.write_bytes(encode(changed))
    with pytest.raises(DocumentConflict):
        write_document(path, MapDocument("local"), revision)
    assert read_document(path)[0] == changed


def test_known_revision_can_be_replaced(tmp_path):
    path = tmp_path / "draft.rtcmap"
    revision = write_document(path, MapDocument())
    updated = MapDocument("next_revision")
    new_revision = write_document(path, updated, revision)
    assert read_document(path) == (updated, new_revision)
    assert new_revision != revision


def test_replace_failure_keeps_last_save_and_cleans_stage(tmp_path, monkeypatch):
    path = tmp_path / "draft.rtcmap"
    previous = MapDocument("previous")
    revision = write_document(path, previous)

    def denied(*_):
        raise PermissionError("fixture file lock")

    monkeypatch.setattr("document.os.replace", denied)
    with pytest.raises(PermissionError):
        write_document(path, MapDocument("updated"), revision)
    assert read_document(path) == (previous, revision)
    assert sorted(tmp_path.iterdir()) == [path]


def test_godot_source_extension_is_never_a_draft_target(tmp_path: Path):
    target = tmp_path / "region.tscn"
    target.write_bytes(b"original contents")
    with pytest.raises(DocumentError):
        write_document(target, MapDocument())
    assert target.read_bytes() == b"original contents"
