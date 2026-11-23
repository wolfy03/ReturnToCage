"""Publish a verified Scene while retaining a durable before/after receipt."""

import json
import os
from pathlib import Path
import shutil
import stat
import tempfile

from document import DocumentConflict, _save_lock
from godot_bridge import BridgeError, check_cancelled, file_hash, project_manifest, regular, safe_child
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
    events = _recover_pairs(project, journal)
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


def _pair_targets(project, paths):
    targets = []
    for value, prefix, suffix in zip(paths, ("world/adventure/", "data/content/regions/"), (".tscn", ".tres"), strict=True):
        if not relative_path(value, suffix).startswith(prefix):
            raise BridgeError("INVALID_PROJECT", f"invalid region pair destination: {value}")
        target = project / value
        if (not target.parent.is_dir() or not target.resolve().is_relative_to(project)
                or any(parent.is_symlink() or parent.is_junction() for parent in target.parents if parent != project)):
            raise BridgeError("INVALID_PROJECT", f"unsafe region pair destination: {value}")
        targets.append(target)
    return targets


def _optional_hash(target):
    if regular(target):
        return file_hash(target)
    if os.path.lexists(target):
        raise BridgeError("SOURCE_MODIFIED", f"unexpected file type at {target}")
    return None


def _pair_part(target, tx, index):
    return target.with_name(f".rtc-{tx.name}-{index}.part")


def _install_new(source, target, temporary):
    with temporary.open("xb") as stream, source.open("rb") as data:
        shutil.copyfileobj(data, stream)
        stream.flush()
        os.fsync(stream.fileno())
    try:
        if os.name == "nt":
            temporary.rename(target)  # Windows rename is exclusive when the target already exists.
        else:
            os.link(temporary, target)
    except FileExistsError as error:
        raise BridgeError("SOURCE_MODIFIED", f"destination was created during publication: {target}") from error
    finally:
        temporary.unlink(missing_ok=True)
    _flush_directory(target.parent)


def _read_pair(tx, name):
    item = tx / name
    try:
        if not regular(item) or item.stat().st_size > 65536:
            raise ValueError("missing or oversized journal")
        record = json.loads(item.read_text(encoding="utf-8"))
        if (not isinstance(record, dict) or set(record) != {"version", "files", "phase", "applied"}
                or type(record["version"]) is not int or record["version"] != 1
                or record["phase"] not in ("before-0", "after-0", "before-1", "after-1", "verifying", "committing")
                or not isinstance(record["files"], list) or len(record["files"]) != 2
                or type(record["applied"]) is not int or not 0 <= record["applied"] <= 2):
            raise ValueError("invalid pair transaction")
        for index, change in enumerate(record["files"]):
            if not isinstance(change, dict) or set(change) != {"path", "before", "after"}:
                raise ValueError("invalid file entry")
            sha256_text(change["after"])
            if change["before"] is not None:
                sha256_text(change["before"])
                backup = tx / f"before-{index}"
                if not regular(backup) or file_hash(backup) != change["before"]:
                    raise ValueError("backup hash mismatch")
        return record
    except (OSError, ValueError, TypeError, RecursionError) as error:
        raise BridgeError("EXPORT_FAILED", f"invalid region pair journal {tx}: {error}") from error


def _recover_pair(project, tx):
    record = _read_pair(tx, "pending.json")
    files = record["files"]
    targets = _pair_targets(project, [change["path"] for change in files])
    current = [_optional_hash(target) for target in targets]
    if any(digest not in (change["before"], change["after"]) for digest, change in zip(current, files)):
        raise BridgeError("SOURCE_MODIFIED", f"pair recovery needs review; external data was preserved: {tx}")
    committed = os.path.lexists(tx / "committed.json")
    if committed and (_read_pair(tx, "committed.json") != record or current != [change["after"] for change in files]):
        raise BridgeError("SOURCE_MODIFIED", f"completed pair no longer matches the journal: {tx}")
    for index in reversed(range(len(files))):
        change, target = files[index], targets[index]
        part = _pair_part(target, tx, index)
        if os.path.lexists(part):
            if not regular(part):
                raise BridgeError("SOURCE_MODIFIED", f"unsafe pair staging file: {part}")
            part.unlink()
        if committed or current[index] == change["before"]:
            continue
        if _optional_hash(target) != change["after"]:
            raise BridgeError("SOURCE_MODIFIED", f"pair output changed during recovery: {target}")
        if change["before"] is None:
            target.unlink()
            _flush_directory(target.parent)
        else:
            _replace(tx / f"before-{index}", target, change["after"], part)
    if committed:
        (tx / "pending.json").unlink()
        _flush_directory(tx)
    else:
        _terminal(tx, "rolled-back", record)
    return f"{files[0]['path']} + {files[1]['path']} · {'committed' if committed else 'rolled-back'}"


def _recover_pairs(project, journal):
    events = []
    for tx in sorted(journal.glob("pair-*")):
        if tx.is_symlink() or tx.is_junction() or not tx.is_dir():
            raise BridgeError("EXPORT_FAILED", f"untrusted pair transaction: {tx}")
        if os.path.lexists(tx / "pending.json"):
            events.append(_recover_pair(project, tx))
    return events


def publish_pair(session, document, receipt):
    """Publish exactly the V4 pair verified on the isolated project."""
    if (document.design is None or document.design.connections or receipt.get("unmapped_connections")
            or receipt.get("runtime", {}).get("overall") not in ("PASS", "PASS_WITH_WARNINGS")):
        raise BridgeError("UNSUPPORTED_NODE", "a fully mapped and runtime-verified region pair is required")
    project = session.settings.project
    journal = _journal_root(project)
    try:
        with _save_lock(journal / "publish.lock"):
            _recover(project, journal)
            return _publish_pair_locked(session, document, receipt, journal)
    except DocumentConflict as error:
        raise BridgeError("SOURCE_MODIFIED", "another process is publishing this project") from error


def _publish_pair_locked(session, document, receipt, journal):
    project = session.settings.project
    session.assert_source_unchanged()
    source = document.source
    paths = ((source.scene_path, source.region_path) if source else
             (f"world/adventure/{document.region_id}.tscn", f"data/content/regions/{document.region_id}.tres"))
    if paths != (receipt["scene_path"], receipt["region_path"]):
        raise BridgeError("INVALID_RESPONSE", "verified destinations do not match the document")
    targets = _pair_targets(project, paths)
    approved = tuple(safe_child(session.stage, path, Path(path).suffix) for path in paths)
    expected = (source.scene_hash, source.region_hash) if source else (None, None)
    after = (receipt["scene_hash"], receipt["region_hash"])
    changes = []
    for path, target, output, before, digest in zip(paths, targets, approved, expected, after):
        sha256_text(digest)
        if session.manifest.get(path) != before or _optional_hash(target) != before or file_hash(output) != digest:
            raise BridgeError("SOURCE_MODIFIED", f"pair input or approved output changed: {path}")
        changes.append({"path": path, "before": before, "after": digest})
    if expected == after:
        return tuple(targets)
    tx = Path(tempfile.mkdtemp(prefix="pair-", dir=journal))
    for index, (target, before) in enumerate(zip(targets, expected)):
        if before is not None:
            backup = tx / f"before-{index}"
            _replace(target, backup, None)
            if file_hash(backup) != before:
                raise BridgeError("SOURCE_MODIFIED", f"pair backup differs: {target}")
    record = {"version": 1, "files": changes, "phase": "before-0", "applied": 0}
    pending = tx / "pending.json"
    expected_manifest = dict(session.manifest)
    try:
        for index, (change, target, output) in enumerate(zip(changes, targets, approved)):
            record["phase"] = f"before-{index}"
            _durable_json(pending, record)
            check_cancelled(session.cancel)
            if project_manifest(project, session.cancel) != expected_manifest or file_hash(output) != change["after"]:
                raise BridgeError("SOURCE_MODIFIED", f"pair changed before installing {target}")
            part = _pair_part(target, tx, index)
            if change["before"] is None:
                _install_new(output, target, part)
            elif change["before"] != change["after"]:
                _replace(output, target, change["before"], part)
            expected_manifest[change["path"]] = change["after"]
            record["phase"], record["applied"] = f"after-{index}", index + 1
            _durable_json(pending, record)
        record["phase"] = "verifying"
        _durable_json(pending, record)
        if project_manifest(project, session.cancel) != expected_manifest:
            raise BridgeError("SOURCE_MODIFIED", "published files or project dependencies differ from the verified pair")
        check_cancelled(session.cancel)
        record["phase"] = "committing"
        _durable_json(pending, record)
        _terminal(tx, "committed", record)
    except (OSError, BridgeError):
        if pending.exists():
            _recover_pair(project, tx)
        raise
    return tuple(targets)


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
