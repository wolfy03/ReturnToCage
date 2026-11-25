"""GATE D: whatever goes wrong while saving, the file on disk is the old one or the new one - never neither."""

import os
import subprocess
import sys
import textwrap
import threading
import time
from pathlib import Path

import pytest

from rtcmonster import (DocumentConflict, document_revision, encode, new_document, read_document, write_document)
from rtcmonster import storage

TOOL = Path(__file__).resolve().parents[1]


@pytest.fixture
def saved(tmp_path):
    path = tmp_path / "slug.rtcmonster"
    document = new_document("moss_slug", "Mine")
    return path, document, write_document(path, document)


def leftovers(folder):
    return sorted(path.name for path in folder.iterdir() if not path.name.endswith(".lock"))


def boom(*_args, **_kwargs):
    raise OSError("injected failure")


class FailingStream:
    """Wraps the temporary file and fails in one chosen method."""

    def __init__(self, real, method):
        self._real, self._method = real, method

    def __getattr__(self, name):
        if name == self._method:
            return boom
        return getattr(self._real, name)

    def __enter__(self):
        self._real.__enter__()
        return self

    def __exit__(self, *details):
        return self._real.__exit__(*details)


def failing_tempfile(monkeypatch, method):
    real = storage.tempfile.NamedTemporaryFile

    def factory(*args, **kwargs):
        return FailingStream(real(*args, **kwargs), method)
    monkeypatch.setattr(storage.tempfile, "NamedTemporaryFile", factory)


FAULTS = {
    "temporary_file_cannot_be_created": lambda mp: mp.setattr(storage.tempfile, "NamedTemporaryFile", boom),
    "write_fails": lambda mp: failing_tempfile(mp, "write"),
    "flush_fails": lambda mp: failing_tempfile(mp, "flush"),
    "fsync_fails": lambda mp: mp.setattr(storage.os, "fsync", boom),
    "replace_fails": lambda mp: mp.setattr(storage.os, "replace", boom),
    "revision_cannot_be_read_back": lambda mp: mp.setattr(storage, "document_revision", boom),
    "interrupted_like_a_cancel": lambda mp: mp.setattr(
        storage.os, "replace", lambda *_a: (_ for _ in ()).throw(KeyboardInterrupt())),
}


@pytest.mark.parametrize("fault", list(FAULTS))
def test_a_failed_update_keeps_the_original_and_leaves_nothing_behind(monkeypatch, saved, fault):
    path, document, revision = saved
    original = path.read_bytes()
    FAULTS[fault](monkeypatch)
    with pytest.raises((OSError, KeyboardInterrupt)):
        write_document(path, document.replace(("stats", "max_health"), 99), revision)
    monkeypatch.undo()
    assert path.read_bytes() == original and leftovers(path.parent) == [path.name]
    assert read_document(path) == (document, revision)
    # The same save works once the fault is gone: no lock or state was left stuck.
    assert write_document(path, document.replace(("stats", "max_health"), 99), revision) != revision


@pytest.mark.parametrize("fault", ["temporary_file_cannot_be_created", "write_fails", "fsync_fails"])
def test_a_failed_first_save_creates_no_file(monkeypatch, tmp_path, fault):
    path = tmp_path / "new.rtcmonster"
    FAULTS[fault](monkeypatch)
    with pytest.raises(OSError):
        write_document(path, new_document("moss_slug", "Mine"))
    monkeypatch.undo()
    assert not path.exists() and leftovers(tmp_path) == []


def test_a_first_save_whose_final_rename_fails_creates_no_file(monkeypatch, tmp_path):
    path = tmp_path / "new.rtcmonster"
    monkeypatch.setattr(storage.Path, "rename", boom)
    monkeypatch.setattr(storage.os, "link", boom)
    with pytest.raises(OSError):
        write_document(path, new_document("moss_slug", "Mine"))
    monkeypatch.undo()
    assert not path.exists() and leftovers(tmp_path) == []


def test_the_lock_refuses_a_second_saver_and_is_released_afterwards(saved):
    path, document, revision = saved
    with storage._save_lock(path):
        with pytest.raises(DocumentConflict, match="another editor"):
            write_document(path, document.replace(("stats", "max_health"), 99), revision)
        assert read_document(path) == (document, revision)
    assert write_document(path, document.replace(("stats", "max_health"), 99), revision) != revision


def test_concurrent_savers_in_one_process_produce_exactly_one_winner(saved):
    path, document, revision = saved
    results, barrier = [], threading.Barrier(8)

    def save(value):
        barrier.wait()
        try:
            results.append(("saved", write_document(path, document.replace(("stats", "max_health"), value), revision)))
        except DocumentConflict as error:
            results.append(("conflict", str(error)))

    threads = [threading.Thread(target=save, args=(100 + index,)) for index in range(8)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    winners = [item for item in results if item[0] == "saved"]
    assert len(winners) == 1 and len(results) == 8
    final, final_revision = read_document(path)
    assert final_revision == winners[0][1] and 100 <= final.data["stats"]["max_health"] < 108
    assert leftovers(path.parent) == [path.name]


def test_concurrent_savers_in_separate_processes_produce_exactly_one_winner(saved):
    path, _document, revision = saved
    script = textwrap.dedent("""
        import sys, time
        sys.path.insert(0, sys.argv[1])
        from rtcmonster import DocumentConflict, read_document, write_document
        path, revision, value, start = sys.argv[2], sys.argv[3], int(sys.argv[4]), float(sys.argv[5])
        document, _ = read_document(path)
        while time.time() < start:
            pass
        try:
            write_document(path, document.replace(("stats", "max_health"), value), revision)
            print("saved")
        except DocumentConflict:
            print("conflict")
    """)
    start = time.time() + 1.5
    children = [subprocess.Popen([sys.executable, "-c", script, str(TOOL), str(path), revision, str(200 + index),
                                  str(start)], stdout=subprocess.PIPE, text=True) for index in range(6)]
    outcomes = [child.communicate(timeout=60)[0].strip() for child in children]
    assert all(child.returncode == 0 for child in children)
    assert outcomes.count("saved") == 1 and outcomes.count("conflict") == 5
    final, _ = read_document(path)
    assert 200 <= final.data["stats"]["max_health"] < 206 and leftovers(path.parent) == [path.name]


def test_overwriting_another_file_needs_the_revision_seen_at_approval(tmp_path, saved):
    path, document, _revision = saved
    target = tmp_path / "other.rtcmonster"
    write_document(target, new_document("other_one", "Other"))
    # "Save as" onto an existing file is refused unless the caller states which revision it agreed to replace.
    with pytest.raises(DocumentConflict, match="already exists"):
        write_document(target, document)
    approved = document_revision(target)                      # what the user saw when confirming
    target.write_bytes(encode(new_document("other_one", "Changed meanwhile")))
    with pytest.raises(DocumentConflict, match="changed on disk"):
        write_document(target, document, approved)
    assert read_document(target)[0].data["metadata"]["display_name"] == "Changed meanwhile"
    assert write_document(target, document, document_revision(target)) == document.fingerprint


def test_the_file_revision_is_the_documents_fingerprint(saved):
    path, document, revision = saved
    assert revision == document.fingerprint == document_revision(path)
    edited = document.replace(("stats", "max_health"), 99)
    assert edited.fingerprint != revision                      # "dirty" is a comparison, not a flag
    assert write_document(path, edited, revision) == edited.fingerprint


def test_temporaries_left_by_a_killed_save_are_found_only_when_old(tmp_path, saved):
    path, document, revision = saved
    dead = tmp_path / (storage.TEMPORARY_PREFIX + "abandoned")
    fresh = tmp_path / (storage.TEMPORARY_PREFIX + "inprogress")
    dead.write_bytes(b"partial")
    fresh.write_bytes(b"partial")
    old = time.time() - 7200
    os.utime(dead, (old, old))
    assert storage.stale_temporaries(tmp_path) == [dead]
    assert read_document(path) == (document, revision)        # a leftover is never mistaken for a document
    assert storage.remove_stale_temporaries(tmp_path) == [dead]
    assert fresh.exists() and not dead.exists() and path.exists()
    assert storage.stale_temporaries(tmp_path, older_than_seconds=0) == [fresh]
