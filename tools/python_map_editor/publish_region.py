"""Publish a verified Scene while retaining a durable before/after receipt."""

import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

from document import DocumentConflict, _save_lock
from godot_bridge import BridgeError, check_cancelled, file_hash, regular, safe_child
from source_region import relative_path, sha256_text

JOURNAL_NAME = ".rtc-map-publish"


def _journal_root(project):
    folder = project / JOURNAL_NAME
    folder.mkdir(exist_ok=True)
    if not folder.is_dir() or folder.is_symlink() or folder.is_junction():
        raise BridgeError("EXPORT_FAILED", f"invalid publication journal directory: {folder}")
    return folder


def _flush_directory(path):
    if os.name != "nt":
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _replace(source, target, expected, stage=None):
    """Stage next to target for a same-volume atomic replace."""
    handle = (stage.open("xb") if stage else
              tempfile.NamedTemporaryFile(prefix=".rtc-publish-", dir=target.parent, delete=False))
    with handle as stream:
        temporary = Path(stream.name)
        try:
            with source.open("rb") as data:
                shutil.copyfileobj(data, stream)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            if expected is not None:
                if not regular(target) or file_hash(target) != expected:
                    raise BridgeError("SOURCE_MODIFIED", str(target))
                if not target.stat().st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                    raise PermissionError(f"read-only file: {target}")
            os.replace(temporary, target)
            _flush_directory(target.parent)
        finally:
            stream.close()
            temporary.unlink(missing_ok=True)


def _durable_json(path, data):
    with tempfile.NamedTemporaryFile(prefix=".journal-", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(json.dumps(data, ensure_ascii=False, allow_nan=False).encode("utf-8"))
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            os.replace(temporary, path)
            _flush_directory(path.parent)
        finally:
            stream.close()
            temporary.unlink(missing_ok=True)


def _read_record(tx):
    file = tx / "pending.json"
    if not regular(file) or file.stat().st_size > 65536:
        raise BridgeError("EXPORT_FAILED", f"missing or oversized publication journal: {tx}")
    try:
        data = json.loads(file.read_text(encoding="utf-8"))
        if set(data) != {"scene", "region", "before", "after", "region_hash"}:
            raise ValueError("wrong publication record")
        relative_path(data["scene"], ".tscn")
        relative_path(data["region"], ".tres")
        for key in ("before", "after", "region_hash"):
            sha256_text(data[key])
        if not regular(tx / "original.tscn") or file_hash(tx / "original.tscn") != data["before"]:
            raise ValueError("backup checksum mismatch")
        return data
    except (ValueError, TypeError, RecursionError) as error:
        raise BridgeError("EXPORT_FAILED", f"invalid publication journal {tx}: {error}") from error


def _terminal(tx, name, record):
    _durable_json(tx / f"{name}.json", record)
    (tx / "pending.json").unlink()
    _flush_directory(tx)


def _scene_stage(scene, tx):
    return scene.with_name(f".rtc-publish-{tx.name}.part")


def _recover(project, journal):
    events = []
    for tx in sorted(journal.glob("scene-*")):
        if tx.is_symlink() or tx.is_junction() or not tx.is_dir():
            raise BridgeError("EXPORT_FAILED", f"untrusted publication transaction: {tx}")
        if not (tx / "pending.json").exists():
            continue
        record = _read_record(tx)
        scene = safe_child(project, record["scene"], ".tscn")
        region = safe_child(project, record["region"], ".tres")
        current = file_hash(scene)
        if file_hash(region) != record["region_hash"] or current not in (record["before"], record["after"]):
            raise BridgeError("SOURCE_MODIFIED", f"publication recovery requires review: {tx}")
        temporary = _scene_stage(scene, tx)
        if regular(temporary):
            temporary.unlink()
        state = "committed" if current == record["after"] else "rolled-back"
        _terminal(tx, state, record)
        events.append(f"{record['scene']} · {state}")
    return events


def recover_project(project):
    candidate = project / JOURNAL_NAME
    if not candidate.exists() and not candidate.is_symlink() and not candidate.is_junction():
        return []
    journal = _journal_root(project)
    try:
        with _save_lock(journal / "publish.lock"):
            return _recover(project, journal)
    except DocumentConflict as error:
        raise BridgeError("SOURCE_MODIFIED", "another process is publishing this project") from error


def publish_scene(session, source, receipt):
    journal = _journal_root(session.settings.project)
    try:
        with _save_lock(journal / "publish.lock"):
            return _publish_scene(session, source, receipt, journal)
    except DocumentConflict as error:
        raise BridgeError("SOURCE_MODIFIED", "another process is publishing this project") from error


def _publish_scene(session, source, receipt, journal):
    project = session.settings.project
    _recover(project, journal)
    session.assert_source_unchanged()
    target = safe_child(project, source.scene_path, ".tscn")
    region = safe_child(project, source.region_path, ".tres")
    approved = safe_child(session.stage, source.scene_path, ".tscn")
    record = {"scene": source.scene_path, "region": source.region_path, "before": source.scene_hash,
              "after": receipt["output_hash"], "region_hash": source.region_hash}
    if (file_hash(target) != record["before"] or file_hash(approved) != record["after"]
            or file_hash(region) != record["region_hash"]):
        raise BridgeError("SOURCE_MODIFIED", str(target))
    if record["before"] == record["after"]:
        return target
    tx = Path(tempfile.mkdtemp(prefix="scene-", dir=journal))
    backup = tx / "original.tscn"
    _replace(target, backup, None)
    if file_hash(backup) != record["before"]:
        raise BridgeError("SOURCE_MODIFIED", f"backup changed: {target}")
    _durable_json(tx / "pending.json", record)
    try:
        check_cancelled(session.cancel)
        if file_hash(region) != record["region_hash"]:
            raise BridgeError("SOURCE_MODIFIED", str(region))
        _replace(approved, target, record["before"], _scene_stage(target, tx))
        if file_hash(target) != record["after"] or file_hash(region) != record["region_hash"]:
            raise BridgeError("SOURCE_MODIFIED", f"publication changed during verification: {target}")
        _terminal(tx, "committed", record)
    except (OSError, BridgeError):
        if regular(target):
            current = file_hash(target)
            if current == record["after"]:
                _replace(backup, target, record["after"], _scene_stage(target, tx))
                current = file_hash(target)
            if current == record["before"]:
                _terminal(tx, "rolled-back", record)
        raise
    return target


def publish_copy(session, destination, source, receipt):
    if destination.exists() or destination.is_symlink() or destination.is_junction():
        raise BridgeError("EXPORT_FAILED", f"Export As requires a new directory: {destination}")
    parent = destination.parent.resolve(strict=True)
    target = parent / destination.name
    if target.is_relative_to(session.settings.project) or target.is_relative_to(session.evidence):
        raise BridgeError("INVALID_PROJECT", "choose a directory outside the source and workspace")
    with tempfile.TemporaryDirectory(prefix=".rtc-project-", dir=parent) as staging:
        root = Path(staging) / "project"
        root.mkdir()
        for name, digest in session.manifest.items():
            check_cancelled(session.cancel)
            staged = safe_child(session.stage, name, Path(name).suffix)
            output = root / name
            output.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(staged, output)
            expected = receipt["output_hash"] if name == source.scene_path else digest
            if file_hash(output) != expected:
                raise BridgeError("SOURCE_MODIFIED", f"verified project copy mismatch: {name}")
        session.assert_source_unchanged()
        with _save_lock(parent / (target.name + ".rtc-export")):
            if target.exists() or target.is_symlink() or target.is_junction():
                raise BridgeError("EXPORT_FAILED", f"Export As destination exists: {target}")
            check_cancelled(session.cancel)
            root.rename(target)
            _flush_directory(parent)
    return target
