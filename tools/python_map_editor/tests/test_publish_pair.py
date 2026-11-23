from pathlib import Path
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
