import json
from pathlib import Path
import subprocess
import sys
from threading import Event, Timer
from types import SimpleNamespace

import pytest

from document import DocumentError, MapDocument, decode, encode
from godot_bridge import (
    BridgeError, GodotSession, ProjectSettings, RESULT_VERSION, file_hash, fingerprint,
    project_manifest, response, run_child, write_json,
)
from publish_region import publish_scene, recover_project
from source_region import GodotSource, NodeBinding

SLEEP = [sys.executable, "-c", "import time; time.sleep(20)"]


def source(project, scene, region):
    manifest = project_manifest(project, Event())
    return GodotSource("0" * 64, fingerprint(manifest), scene, region, manifest[scene], manifest[region],
                       "uid://scene", "", (NodeBinding("platform", "Terrain/Wall", "Terrain",
                                                       [1, 0, 0, 1, 10, 20], [1, 0, 0, 1, 10, 20], 1, 1),))


@pytest.fixture
def project_settings(tmp_path):
    project = tmp_path / "project"
    project.mkdir()
    for location in ("project.godot", "autoload/content_registry.gd", "data/definitions/region_definition.gd",
                     "data/content/sample.tres", "world/sample.tscn"):
        target = project / location
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(location, encoding="utf-8")
    return ProjectSettings(project, Path(sys.executable), tmp_path / "evidence")


def test_v3_binding_round_trip_and_path_escape(project_settings):
    linked = source(project_settings.project, "world/sample.tscn", "data/content/sample.tres")
    draft = MapDocument(source=linked)
    assert json.loads(encode(draft))["schema_version"] == 3
    assert decode(encode(draft)) == draft
    with pytest.raises(DocumentError):
        decode(encode(draft).replace(b"world/sample.tscn", b"../out.tscn"))


def test_missing_godot(project_settings):
    configuration = ProjectSettings(project_settings.project, project_settings.work / "missing.exe", project_settings.work)
    with pytest.raises(BridgeError, match="INVALID_GODOT_PATH"):
        configuration.checked()


def test_wrong_godot_version_preserves_evidence(project_settings):
    session = GodotSession(project_settings, Event())
    with pytest.raises(BridgeError, match="GODOT_VERSION_MISMATCH"):
        with session:
            pytest.fail("wrong engine was accepted")
    assert (session.evidence / "version.stdout.log").is_file()
    assert not list(session.evidence.glob("snapshot-*"))


@pytest.mark.parametrize("change, exit_code, error", [
    ({"protocol": 2}, 0, "INVALID_RESPONSE"),
    ({"request_id": "other"}, 0, "INVALID_RESPONSE"),
    ({"operation": "validate_document"}, 0, "INVALID_RESPONSE"),
    ({"status": "FAIL", "error_code": "RESOURCE_MISSING"}, 1, "RESOURCE_MISSING"),
    ({}, 3221225477, "PROCESS_CRASH"),
    ({}, 1, "EXPORT_FAILED"),
])
def test_strict_bridge_response(tmp_path, change, exit_code, error):
    path = tmp_path / "result.json"
    write_json(path, {"protocol": 1, "request_id": "fixture", "operation": "import_region",
                      "godot_version": RESULT_VERSION, "status": "PASS", "warnings": [], "data": {}, **change})
    with pytest.raises(BridgeError, match=error):
        response(path, "import_region", "fixture", exit_code, "")


def test_response_rejects_malformed_json(tmp_path):
    path = tmp_path / "result.json"
    path.write_bytes(b'{"protocol":1,"protocol":1}')
    with pytest.raises(BridgeError, match="invalid JSON"):
        response(path, "import_region", "fixture", 0, "")


@pytest.mark.parametrize("cancelled, code", [(False, "TIMEOUT"), (True, "CANCELLED")])
def test_cancel_and_timeout_reap_owned_child(tmp_path, cancelled, code):
    cancel = Event()
    independent = subprocess.Popen(SLEEP)
    timer = Timer(0.25, cancel.set)
    try:
        if cancelled:
            timer.start()
        with pytest.raises(BridgeError, match=code):
            run_child(SLEEP, tmp_path, None, tmp_path, "long-running", cancel, 5 if cancelled else 0.2)
        exit_record = json.loads((tmp_path / "long-running.exit.json").read_text())
        assert exit_record["exit_code"] != 0
        assert independent.poll() is None
    finally:
        timer.cancel()
        independent.kill()
        independent.wait(timeout=5)


@pytest.fixture
def publication(project_settings, tmp_path):
    project = project_settings.project
    linked = source(project, "world/sample.tscn", "data/content/sample.tres")
    stage = tmp_path / "scene-stage"
    staged = stage / linked.scene_path
    staged.parent.mkdir(parents=True)
    staged.write_bytes(b"validated candidate")
    session = SimpleNamespace(settings=project_settings, stage=stage, cancel=Event(),
                              assert_source_unchanged=lambda: None)
    receipt = {"output_hash": file_hash(staged)}
    return session, linked, receipt


def test_successful_publication_preserves_region(publication):
    session, linked, receipt = publication
    scene = publish_scene(session, linked, receipt)
    assert file_hash(scene) == receipt["output_hash"]
    region = session.settings.project / linked.region_path
    assert file_hash(region) == linked.region_hash
    backups = list((session.settings.project / ".rtc-map-publish").glob("scene-*/original.tscn"))
    assert len(backups) == 1 and file_hash(backups[0]) == linked.scene_hash
    assert not list(scene.parent.glob(".rtc-publish-*"))
    assert recover_project(session.settings.project) == []


def test_changed_source_blocks_publish(publication):
    session, linked, receipt = publication
    scene = session.settings.project / linked.scene_path
    scene.write_bytes(b"external")
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED"):
        publish_scene(session, linked, receipt)
    assert scene.read_bytes() == b"external"


def test_failed_commit_rolls_back(publication, monkeypatch):
    session, linked, receipt = publication
    import publish_region

    terminal = publish_region._terminal

    def interrupted(tx, name, record):
        if name == "committed":
            raise OSError("fixture publication receipt could not be written")
        terminal(tx, name, record)

    monkeypatch.setattr(publish_region, "_terminal", interrupted)
    with pytest.raises(OSError, match="receipt"):
        publish_scene(session, linked, receipt)
    assert file_hash(session.settings.project / linked.scene_path) == linked.scene_hash
    assert list((session.settings.project / ".rtc-map-publish").glob("scene-*/rolled-back.json"))


@pytest.mark.parametrize("applied,event", [(True, "committed"), (False, "rolled-back")])
def test_recovers_interrupted_transaction(publication, monkeypatch, applied, event):
    session, linked, receipt = publication
    import publish_region

    replace = publish_region._replace
    scene = session.settings.project / linked.scene_path

    def interrupted(source_path, target, expected, stage=None):
        if target != scene or applied:
            replace(source_path, target, expected, stage)
        if target == scene:
            if not applied:
                stage.write_bytes(b"interrupted write")
            raise SystemExit(9)

    with monkeypatch.context() as inject:
        inject.setattr(publish_region, "_replace", interrupted)
        with pytest.raises(SystemExit):
            publish_scene(session, linked, receipt)
    assert recover_project(session.settings.project) == [f"{linked.scene_path} · {event}"]
    assert file_hash(scene) == (receipt["output_hash"] if applied else linked.scene_hash)
    assert not list(scene.parent.glob(".rtc-publish-*"))
    assert recover_project(session.settings.project) == []


def test_manifest_detects_external_texture_change(project_settings):
    project = project_settings.project
    texture = project / "decor.png"
    texture.write_bytes(b"first")
    before = fingerprint(project_manifest(project, Event()))
    texture.write_bytes(b"later")
    assert fingerprint(project_manifest(project, Event())) != before

def test_cancel_at_publication_keeps_original(publication):
    session, linked, receipt = publication
    session.cancel.set()
    with pytest.raises(BridgeError, match="CANCELLED"):
        publish_scene(session, linked, receipt)
    assert file_hash(session.settings.project / linked.scene_path) == linked.scene_hash
    assert file_hash(session.settings.project / linked.region_path) == linked.region_hash


def test_recovery_does_not_overwrite_an_unrecognized_file(publication, monkeypatch):
    session, linked, receipt = publication
    import publish_region

    scene = session.settings.project / linked.scene_path
    replace = publish_region._replace

    def interrupt(source_path, target, expected, stage=None):
        if target == scene:
            raise SystemExit(23)
        replace(source_path, target, expected, stage)

    with monkeypatch.context() as inject:
        inject.setattr(publish_region, "_replace", interrupt)
        with pytest.raises(SystemExit):
            publish_scene(session, linked, receipt)
    scene.write_bytes(b"external change after the journal was written")
    before = scene.read_bytes()
    with pytest.raises(BridgeError, match="SOURCE_MODIFIED"):
        recover_project(session.settings.project)
    assert scene.read_bytes() == before
    assert file_hash(session.settings.project / linked.region_path) == linked.region_hash


@pytest.mark.parametrize("after_replace", [False, True])
def test_hard_process_exit_recovers_before_and_after_scene_replace(publication, tmp_path, after_replace):
    session, linked, receipt = publication
    from dataclasses import asdict

    state = tmp_path / "publish.json"
    write_json(state, {"source": asdict(linked), "receipt": receipt, "project": str(session.settings.project),
                       "stage": str(session.stage), "after": after_replace})
    program = """
from pathlib import Path
from threading import Event
from types import SimpleNamespace
import os, sys
import publish_region as publisher
from godot_bridge import read_json
from source_region import GodotSource
state = read_json(Path(sys.argv[1]))
project = Path(state["project"])
linked = GodotSource.from_data(state["source"])
target = project / linked.scene_path
replace = publisher._replace
def cut(source, destination, digest, temporary=None):
    if destination != target or state["after"]:
        replace(source, destination, digest, temporary)
    if destination == target:
        if not state["after"]:
            temporary.write_bytes(b"partial data")
        os._exit(97)
publisher._replace = cut
job = SimpleNamespace(settings=SimpleNamespace(project=project), stage=Path(state["stage"]),
                      cancel=Event(), assert_source_unchanged=lambda: None)
publisher.publish_scene(job, linked, state["receipt"])
"""
    child = subprocess.run([sys.executable, "-c", program, str(state)], cwd=Path(__file__).resolve().parents[1],
                           capture_output=True, timeout=15)
    assert child.returncode == 97, child.stderr.decode(errors="replace")
    outcome = "committed" if after_replace else "rolled-back"
    assert recover_project(session.settings.project) == [f"{linked.scene_path} · {outcome}"]
    scene = session.settings.project / linked.scene_path
    assert file_hash(scene) == (receipt["output_hash"] if after_replace else linked.scene_hash)
    assert not list(scene.parent.glob(".rtc-publish-*"))


def test_native_failure_with_complete_result_never_publishes(publication, monkeypatch):
    pytest.importorskip("PySide6")
    import godot_ui

    session, linked, _ = publication
    reply = session.stage.parent / "valid-result.json"
    write_json(reply, {"protocol": 1, "request_id": "fixture", "operation": "validate_export",
                       "godot_version": RESULT_VERSION, "status": "PASS", "warnings": [], "data": {}})

    class FailingSession:
        settings = session.settings
        evidence = reply.parent

        def __init__(self, *_):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *_):
            pass

        def stage_export(self, _document):
            response(reply, "validate_export", "fixture", 0xc0000005, "")

    def reject_publish(*_):
        pytest.fail("failed stage reached publication")

    monkeypatch.setattr(godot_ui, "GodotSession", FailingSession)
    monkeypatch.setattr(godot_ui, "publish_scene", reject_publish)
    with pytest.raises(BridgeError, match="PROCESS_CRASH"):
        godot_ui.run_operation(session.settings, session.cancel, "export_region", (MapDocument(source=linked), None),
                               lambda _: None)
    assert file_hash(session.settings.project / linked.scene_path) == linked.scene_hash
    assert file_hash(session.settings.project / linked.region_path) == linked.region_hash
