import os
from pathlib import Path
import stat
import subprocess
import sys
import time

import pytest

from document import (
    DocumentConflict, DocumentError, MapDocument, decode, encode, read_document, write_document,
)


def test_utf8_round_trip(tmp_path):
    draft = MapDocument("sewer_draft", "하수구", 1600, 910)
    folder = tmp_path / "맵 작업"
    folder.mkdir()
    path = folder / "하수구.rtcmap"
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
    assert {entry.name for entry in tmp_path.iterdir()} == {path.name, f".{path.name}.lock"}
    monkeypatch.undo()
    assert write_document(path, MapDocument("retry"), revision) != revision


def test_external_write_after_staging_rejects_publish(tmp_path, monkeypatch):
    path = tmp_path / "draft.rtcmap"
    revision = write_document(path, MapDocument())
    external = MapDocument("external")
    real_fsync = os.fsync

    def fsync_and_change(descriptor):
        real_fsync(descriptor)
        path.write_bytes(encode(external))

    monkeypatch.setattr("document.os.fsync", fsync_and_change)
    with pytest.raises(DocumentConflict):
        write_document(path, MapDocument("local"), revision)
    assert read_document(path)[0] == external
    assert not list(tmp_path.glob(".rtcmap-*"))


def test_read_only_file_is_preserved(tmp_path):
    path = tmp_path / "draft.rtcmap"
    draft = MapDocument()
    revision = write_document(path, draft)
    path.chmod(stat.S_IREAD)
    try:
        with pytest.raises(PermissionError):
            write_document(path, MapDocument("replace"), revision)
        assert read_document(path) == (draft, revision)
        assert not list(tmp_path.glob(".rtcmap-*"))
    finally:
        path.chmod(stat.S_IREAD | stat.S_IWRITE)


def test_symlinks_are_rejected_for_documents_and_locks(tmp_path):
    target = tmp_path / "original.rtcmap"
    write_document(target, MapDocument())
    for name in ("link.rtcmap", ".draft.rtcmap.lock"):
        link = tmp_path / name
        try:
            link.symlink_to(target)
        except OSError as error:
            if getattr(error, "winerror", None) == 1314:
                pytest.skip("creating Windows symlinks requires elevated privileges or Developer Mode")
            raise
    with pytest.raises(DocumentError):
        read_document(tmp_path / "link.rtcmap")
    with pytest.raises(DocumentError):
        write_document(tmp_path / "draft.rtcmap", MapDocument())
    assert read_document(target)[0] == MapDocument()


@pytest.mark.skipif(os.name != "nt", reason="Windows directory junction")
def test_document_parent_junction_is_rejected(tmp_path):
    directory = tmp_path / "real"
    directory.mkdir()
    junction = tmp_path / "linked"
    subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(junction), str(directory)],
                   check=True, capture_output=True)
    try:
        assert junction.is_junction()
        with pytest.raises(DocumentError, match="junction"):
            write_document(junction / "draft.rtcmap", MapDocument())
        assert not list(directory.iterdir())
    finally:
        junction.rmdir()  # Remove only the link.


def test_abrupt_exit_releases_document_lock(tmp_path):
    path = tmp_path / "draft.rtcmap"
    revision = write_document(path, MapDocument())
    worker = """
import os, sys
from pathlib import Path
from document import _save_lock

with _save_lock(Path(sys.argv[1])):
    os._exit(23)
"""
    result = subprocess.run([sys.executable, "-c", worker, str(path)], timeout=10,
                            cwd=Path(__file__).resolve().parents[1])
    assert result.returncode == 23
    assert write_document(path, MapDocument("recovered"), revision) != revision


def test_two_processes_cannot_publish_the_same_revision(tmp_path):
    path = tmp_path / "draft.rtcmap"
    revision = write_document(path, MapDocument())
    ready = tmp_path / "ready"
    publish = tmp_path / "publish"
    worker = """
import os, sys, time
from pathlib import Path
from document import MapDocument, write_document

target, ready, publish = map(Path, sys.argv[1:4])
replace = os.replace

def wait_to_publish(source, destination):
    ready.touch()
    deadline = time.monotonic() + 15
    while not publish.exists():
        if time.monotonic() > deadline:
            raise TimeoutError("test did not release the publisher")
        time.sleep(0.02)
    replace(source, destination)

os.replace = wait_to_publish
write_document(target, MapDocument("first_writer"), sys.argv[4])
"""
    process = subprocess.Popen(
        [sys.executable, "-c", worker, str(path), str(ready), str(publish), revision],
        cwd=Path(__file__).resolve().parents[1],
    )
    try:
        deadline = time.monotonic() + 10
        while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.02)
        assert ready.is_file(), "first publisher never reached the atomic replace"
        with pytest.raises(DocumentConflict, match="another editor"):
            write_document(path, MapDocument("second_writer"), revision)
        publish.touch()
        assert process.wait(timeout=10) == 0
        with pytest.raises(DocumentConflict, match="changed on disk"):
            write_document(path, MapDocument("second_writer"), revision)
        assert read_document(path)[0] == MapDocument("first_writer")
        assert not list(tmp_path.glob(".rtcmap-*"))
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)


def test_godot_source_extension_is_never_a_draft_target(tmp_path: Path):
    target = tmp_path / "region.tscn"
    target.write_bytes(b"original contents")
    with pytest.raises(DocumentError):
        write_document(target, MapDocument())
    assert target.read_bytes() == b"original contents"
