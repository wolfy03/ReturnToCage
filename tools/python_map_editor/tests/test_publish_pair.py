from pathlib import Path
import stat
import subprocess
import sys
from threading import Event
from types import SimpleNamespace

import pytest

from document import MapDocument
from godot_bridge import BridgeError, file_hash, project_manifest
import publish_region
from publish_region import publish_pair, recover_project
from region_design import RegionDesign


SCENE = "world/adventure/new_region.tscn"
REGION = "data/content/regions/new_region.tres"
CRASH_SCRIPT = r'''
import os
from pathlib import Path
from threading import Event
from types import SimpleNamespace
import sys
sys.path.insert(0, sys.argv[1])
from document import MapDocument
from godot_bridge import file_hash, project_manifest
from region_design import RegionDesign
import publish_region

project, stage = map(Path, sys.argv[2:4])
phase = sys.argv[4]
paths = ('world/adventure/new_region.tscn', 'data/content/regions/new_region.tres')
cancel = Event()
manifest = project_manifest(project, cancel)
session = SimpleNamespace(settings=SimpleNamespace(project=project), stage=stage, cancel=cancel,
                          manifest=manifest, assert_source_unchanged=lambda: None)
source = SimpleNamespace(scene_path=paths[0], region_path=paths[1], scene_hash=manifest.get(paths[0]),
                         region_hash=manifest.get(paths[1])) if paths[0] in manifest else None
document = SimpleNamespace(region_id='new_region', source=source, design=RegionDesign())
receipt = {'scene_path': paths[0], 'region_path': paths[1], 'scene_hash': file_hash(stage / paths[0]),
           'region_hash': file_hash(stage / paths[1]), 'runtime': {'overall': 'PASS'}}
write = publish_region._durable_json
def checkpoint(path, data):
    if phase == 'start' and path.name == 'pending.json':
        os._exit(42)
    write(path, data)
    if phase == 'committed' and path.name == 'committed.json':
        os._exit(42)
    if phase == data['phase'] and path.name == 'pending.json':
        os._exit(42)
publish_region._durable_json = checkpoint
publish_region.publish_pair(session, document, receipt)
'''


def fixture(tmp_path, existing=False):
    project, stage = [tmp_path / name for name in ("project", "stage")]
    for root in (project, stage):
        for path in (SCENE, REGION):
            (root / path).parent.mkdir(parents=True, exist_ok=True)
    for index, path in enumerate((SCENE, REGION)):
        (stage / path).write_bytes(f"after-{index}".encode())
        if existing:
            (project / path).write_bytes(f"before-{index}".encode())
    receipt = {"scene_path": SCENE, "region_path": REGION, "scene_hash": file_hash(stage / SCENE),
               "region_hash": file_hash(stage / REGION), "runtime": {"overall": "PASS"}}
    cancel = Event()
    return SimpleNamespace(settings=SimpleNamespace(project=project), stage=stage, cancel=cancel,
                           manifest=project_manifest(project, cancel), assert_source_unchanged=lambda: None), receipt


@pytest.mark.parametrize("existing", (False, True))
@pytest.mark.parametrize("phase", ("start", "before-0", "after-0", "before-1", "after-1", "verifying", "committing", "committed"))
def test_pair_recovers_after_real_process_interruption(tmp_path, existing, phase):
    session, receipt = fixture(tmp_path, existing)
    project = session.settings.project
    completed = subprocess.run([sys.executable, "-c", CRASH_SCRIPT, str(Path(publish_region.__file__).parent),
                                str(project), str(session.stage), phase], timeout=20, check=False)
    assert completed.returncode == 42
    events = recover_project(project)
    if phase == "committed":
        assert len(events) == 1 and "committed" in events[0]
        assert [file_hash(project / path) for path in (SCENE, REGION)] == [receipt["scene_hash"], receipt["region_hash"]]
    else:
        assert not events if phase == "start" else len(events) == 1 and "rolled-back" in events[0]
        assert project_manifest(project, Event()) == session.manifest
    assert recover_project(project) == []
    assert recover_project(project) == []
    assert not list(project.rglob("*.part"))


def test_cancel_after_first_replacement_rolls_back_pair(tmp_path, monkeypatch):
    session, receipt = fixture(tmp_path)
    write = publish_region._durable_json

    def cancel(path, record):
        write(path, record)
        if record["phase"] == "after-0":
            session.cancel.set()

    monkeypatch.setattr(publish_region, "_durable_json", cancel)
    with pytest.raises(BridgeError, match="CANCELLED"):
        publish_pair(session, MapDocument(design=RegionDesign()), receipt)
    assert project_manifest(session.settings.project, Event()) == session.manifest


def test_recovery_preserves_unknown_external_bytes(tmp_path):
    session, _ = fixture(tmp_path, existing=True)
    project = session.settings.project
    completed = subprocess.run([sys.executable, "-c", CRASH_SCRIPT, str(Path(publish_region.__file__).parent),
                                str(project), str(session.stage), "after-0"], timeout=20, check=False)
    assert completed.returncode == 42
    (project / REGION).write_bytes(b"external writer")
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED"):
        recover_project(project)
    assert (project / REGION).read_bytes() == b"external writer"
    assert (project / SCENE).read_bytes() == b"after-0"


def test_pair_rejects_tampered_artifact_and_preview(tmp_path):
    session, receipt = fixture(tmp_path)
    draft = MapDocument(design=RegionDesign())
    with pytest.raises(BridgeError, match="UNSUPPORTED_NODE"):
        publish_pair(session, draft, {**receipt, "unmapped_connections": ["preview"]})
    (session.stage / REGION).write_bytes(b"tampered")
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED"):
        publish_pair(session, draft, receipt)
    assert project_manifest(session.settings.project, Event()) == session.manifest


def linked_draft(session):
    source = SimpleNamespace(scene_path=SCENE, region_path=REGION, scene_hash=session.manifest[SCENE],
                             region_hash=session.manifest[REGION])
    return SimpleNamespace(region_id="new_region", design=RegionDesign(), source=source)


@pytest.mark.parametrize(("boundary", "path"), [("approval", SCENE), ("before-0", SCENE), ("after-0", REGION),
                                                ("committing", SCENE), ("committing", REGION)])
def test_external_change_never_gets_overwritten(tmp_path, monkeypatch, boundary, path):
    session, receipt = fixture(tmp_path, existing=True)
    target = session.settings.project / path
    original = publish_region._durable_json

    def external(record_path, record):
        original(record_path, record)
        if record_path.name == "pending.json" and record["phase"] == boundary:
            target.write_bytes(b"independent writer")

    monkeypatch.setattr(publish_region, "_durable_json", external)
    if boundary == "approval":
        target.write_bytes(b"independent writer")
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED") as error:
        publish_pair(session, linked_draft(session), receipt)
    assert path.replace("/", "\\") in str(error.value) or path in str(error.value)
    assert file_hash(target) in str(error.value)
    assert target.read_bytes() == b"independent writer"
    if boundary != "approval":
        journal = next((session.settings.project / publish_region.JOURNAL_NAME).glob("pair-*"))
        assert (journal / "pending.json").is_file() and (journal / "before-0").is_file()
        assert not (journal / "committed.json").exists()


def test_corrupt_journal_and_unknown_terminal_content_are_retained(tmp_path, monkeypatch):
    session, receipt = fixture(tmp_path, existing=True)
    root = session.settings.project
    for path in (SCENE, REGION):
        (session.stage / path).write_bytes((root / path).read_bytes())
    same = {**receipt, "scene_hash": session.manifest[SCENE], "region_hash": session.manifest[REGION]}
    publish_pair(session, linked_draft(session), same)
    journal = root / publish_region.JOURNAL_NAME
    assert not list(journal.glob("pair-*"))
    monkeypatch.setattr(publish_region, "PAIR_HISTORY", 0)
    for path in (SCENE, REGION):
        (session.stage / path).write_bytes(b"verified replacement")
    changed = {**receipt, "scene_hash": file_hash(session.stage / SCENE),
               "region_hash": file_hash(session.stage / REGION)}
    damaged = journal / "pair-damaged"
    damaged.mkdir()
    (damaged / "committed.json").write_text("invalid JSON", encoding="utf-8")
    publish_pair(session, linked_draft(session), changed)
    assert sorted(journal.glob("pair-*")) == [damaged]
    pending = damaged / "pending.json"
    pending.write_text("invalid JSON", encoding="utf-8")
    with pytest.raises(BridgeError, match="EXPORT_FAILED"):
        recover_project(root)
    assert pending.is_file() and file_hash(root / SCENE) == changed["scene_hash"]


@pytest.mark.parametrize("change", ["deleted", "read-only", "symlink"])
def test_pair_preflight_preserves_other_file_for_unsafe_target(tmp_path, change):
    session, receipt = fixture(tmp_path, existing=True)
    root = session.settings.project
    target = root / REGION
    old = target.stat().st_mode
    if change == "deleted":
        target.unlink()
    elif change == "read-only":
        target.chmod(stat.S_IREAD)
    else:
        target.unlink()
        try:
            target.symlink_to(session.stage / REGION)
        except OSError as error:
            pytest.skip(f"symlinks not available: {error}")
    try:
        with pytest.raises(BridgeError, match="SOURCE_MODIFIED|EXPORT_FAILED|INVALID_PROJECT"):
            publish_pair(session, linked_draft(session), receipt)
        assert file_hash(root / SCENE) == session.manifest[SCENE]
        assert not list((root / publish_region.JOURNAL_NAME).glob("pair-*"))
        if change == "symlink":
            assert target.is_symlink() and file_hash(session.stage / REGION) == receipt["region_hash"]
    finally:
        if change == "read-only":
            target.chmod(old)


def test_other_editor_lock_blocks_entire_pair(tmp_path):
    session, receipt = fixture(tmp_path)
    root = session.settings.project
    journal = publish_region._journal_root(root)
    with publish_region._save_lock(journal / "publish.lock"):
        completed = subprocess.run([sys.executable, "-c", CRASH_SCRIPT, str(Path(publish_region.__file__).parent),
                                    str(root), str(session.stage), "before-0"], timeout=20, check=False,
                                   capture_output=True, text=True)
    assert completed.returncode == 1 and "another process is publishing" in completed.stderr
    assert not list(journal.glob("pair-*"))
    assert project_manifest(root, Event()) == session.manifest


def test_external_write_as_completion_is_recorded_keeps_recovery_evidence(tmp_path, monkeypatch):
    session, receipt = fixture(tmp_path, existing=True)
    root = session.settings.project
    original = publish_region._durable_json

    def external(path, record):
        original(path, record)
        if path.name == "committed.json":
            (root / REGION).write_bytes(b"external write at completion")

    monkeypatch.setattr(publish_region, "_durable_json", external)
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED"):
        publish_pair(session, linked_draft(session), receipt)
    assert (root / REGION).read_bytes() == b"external write at completion"
    journal = next((root / publish_region.JOURNAL_NAME).glob("pair-*"))
    assert (journal / "pending.json").is_file() and (journal / "before-1").is_file()
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED"):
        recover_project(root)
