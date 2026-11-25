import os
import stat

import pytest

from rtcmonster import (DocumentConflict, DocumentError, document_revision, encode, new_document, read_document,
                        write_document)
from rtcmonster import storage


def leftovers(folder):
    return sorted(path.name for path in folder.iterdir() if not path.name.endswith(".lock"))


def test_save_then_reopen_returns_the_same_document_and_revision(tmp_path):
    document = new_document("moss_slug", "Moss Slug")
    path = tmp_path / "이끼 민달팽이.rtcmonster"
    revision = write_document(path, document)
    assert path.read_bytes() == encode(document)
    assert read_document(path) == (document, revision) and document_revision(path) == revision
    assert leftovers(tmp_path) == [path.name]


def test_a_new_save_never_overwrites_an_existing_file(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    write_document(path, new_document("moss_slug", "First"))
    original = path.read_bytes()
    with pytest.raises(DocumentConflict, match="already exists"):
        write_document(path, new_document("moss_slug", "Second"))
    assert path.read_bytes() == original and leftovers(tmp_path) == [path.name]


def test_an_external_change_is_detected_and_nothing_is_written(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    revision = write_document(path, document)
    theirs = encode(new_document("moss_slug", "Theirs"))
    path.write_bytes(theirs)                      # another program saved in between
    assert document_revision(path) != revision
    with pytest.raises(DocumentConflict, match="changed on disk"):
        write_document(path, document.replace(("stats", "max_health"), 99), revision)
    assert path.read_bytes() == theirs and leftovers(tmp_path) == [path.name]


def test_a_deleted_file_is_also_an_external_change(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    revision = write_document(path, document)
    path.unlink()
    with pytest.raises(DocumentConflict):
        write_document(path, document, revision)
    assert not path.exists()


def test_replacing_the_revision_that_was_read_succeeds(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    revision = write_document(path, document)
    changed = document.replace(("stats", "max_health"), 99)
    second = write_document(path, changed, revision)
    assert second != revision and read_document(path) == (changed, second)


def test_a_failed_save_keeps_the_original_and_leaves_no_temporary_file(tmp_path, monkeypatch):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    revision = write_document(path, document)
    original = path.read_bytes()

    def broken(source, target):
        raise OSError("disk full")

    monkeypatch.setattr(storage.os, "replace", broken)
    with pytest.raises(OSError, match="disk full"):
        write_document(path, document.replace(("stats", "max_health"), 99), revision)
    assert path.read_bytes() == original and leftovers(tmp_path) == [path.name]
    assert read_document(path) == (document, revision)


def test_a_document_that_cannot_be_encoded_never_touches_the_file(tmp_path, monkeypatch):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    revision = write_document(path, document)
    monkeypatch.setattr(storage, "encode", lambda _document: (_ for _ in ()).throw(DocumentError("too large")))
    with pytest.raises(DocumentError, match="too large"):
        write_document(path, document, revision)
    assert read_document(path) == (document, revision) and leftovers(tmp_path) == [path.name]


def test_read_only_files_are_not_replaced(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    revision = write_document(path, document)
    path.chmod(stat.S_IREAD)
    try:
        with pytest.raises(PermissionError):
            write_document(path, document.replace(("stats", "max_health"), 99), revision)
        assert read_document(path) == (document, revision)
    finally:
        path.chmod(stat.S_IREAD | stat.S_IWRITE)


@pytest.mark.parametrize("name", ["slug.json", "slug.rtcmap", "slug", "slug.rtcmonster.bak"])
def test_only_rtcmonster_files_are_read_or_written(tmp_path, name):
    with pytest.raises(DocumentError, match=".rtcmonster"):
        write_document(tmp_path / name, new_document("moss_slug", "Mine"))
    with pytest.raises(DocumentError, match=".rtcmonster"):
        read_document(tmp_path / name)


def test_directories_and_links_are_not_documents(tmp_path):
    folder = tmp_path / "folder.rtcmonster"
    folder.mkdir()
    with pytest.raises(DocumentError, match="regular file"):
        read_document(folder)
    target = tmp_path / "real.rtcmonster"
    write_document(target, new_document("moss_slug", "Mine"))
    link = tmp_path / "link.rtcmonster"
    try:
        os.symlink(target, link)
    except (OSError, NotImplementedError) as error:
        pytest.skip(f"symbolic links are not available: {error}")
    with pytest.raises(DocumentError, match="regular file"):
        read_document(link)
    with pytest.raises(DocumentError, match="regular file"):
        write_document(link, new_document("moss_slug", "Other"), document_revision(target))


def test_a_damaged_file_is_reported_not_replaced_by_defaults(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    path.write_bytes(b'{"schema_version": 1, "document_type": "rtcmonster", "monster_id": ')
    with pytest.raises(DocumentError):
        read_document(path)
    assert path.read_bytes().endswith(b'"monster_id": ')
