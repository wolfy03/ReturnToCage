"""Conservative retention for completed editor-owned traversal snapshots only."""
import ctypes as c
from ctypes import wintypes as w
import hashlib
import json
import math
import os
from pathlib import Path
import re
import time

FILES = {"request.json", "scene.tscn", "status.json", "result.json", "godot.log"}


def linked(path):
    return path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction())


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def identity(pid):
    """PID plus creation time and executable; inaccessible processes are not dead."""
    if type(pid) is not int or pid <= 0 or os.name != "nt":
        raise ValueError("Cannot establish process identity")
    api = c.WinDLL("kernel32", use_last_error=True)
    api.OpenProcess.argtypes, api.OpenProcess.restype = [w.DWORD, w.BOOL, w.DWORD], w.HANDLE
    api.CloseHandle.argtypes = [w.HANDLE]
    api.WaitForSingleObject.argtypes, api.WaitForSingleObject.restype = [w.HANDLE, w.DWORD], w.DWORD
    api.GetProcessTimes.argtypes = [w.HANDLE] + [c.POINTER(w.FILETIME)] * 4
    api.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, c.POINTER(w.DWORD)]
    handle = api.OpenProcess(0x100000 | 0x1000, False, pid)
    if not handle:
        if c.get_last_error() == 87:  # ERROR_INVALID_PARAMETER: PID no longer exists.
            return None
        raise c.WinError(c.get_last_error())
    try:
        if api.WaitForSingleObject(handle, 0) == 0:
            return None
        values = [w.FILETIME() for _ in range(4)]
        name, length = c.create_unicode_buffer(32768), w.DWORD(32768)
        if not api.GetProcessTimes(handle, *[c.byref(v) for v in values]) or not api.QueryFullProcessImageNameW(handle, 0, name, c.byref(length)):
            raise c.WinError(c.get_last_error())
        return {"pid": pid, "created": (values[0].dwHighDateTime << 32) | values[0].dwLowDateTime,
                "image": name.value.casefold()}
    finally:
        api.CloseHandle(handle)


def read_json(path):
    if path.stat().st_size > 65536:
        raise ValueError("Oversized retention metadata")
    return json.loads(path.read_text(encoding="utf-8-sig"))


def valid_identity(value):
    return (isinstance(value, dict) and set(value) == {"pid", "created", "image"}
            and type(value["pid"]) is int and 0 < value["pid"] <= 0xFFFFFFFF
            and type(value["created"]) is int and 0 < value["created"] < 2 ** 64
            and isinstance(value["image"], str) and 0 < len(value["image"]) <= 32768)


def attest(directory, request, owner):
    """Called by the worker only after a successful child exit and status write."""
    if request.get("origin") != "rtc_field_editor" or owner is None:
        return
    try:
        status = read_json(directory / "status.json")
        if status.get("state") != "complete" or status.get("return_code") != 0 or status.get("engine_error") is not False:
            return
        value = {"schema": 1, "token": directory.name, "owner": owner,
                 "worker": identity(os.getpid()), "completed": time.time(),
                 "files": {name: digest(directory / name) for name in FILES}}
        stage = directory / "retention.tmp"
        # Exclusive creation: never follow or replace an unexpected file.
        with stage.open("x", encoding="utf-8") as stream:
            json.dump(value, stream)
        stage.rename(directory / "retention.json")
        return True
    except (OSError, ValueError, TypeError, KeyError):
        pass  # Retention failure protects the job; it does not change verification.


def _candidate(base, directory, protected):
    if re.fullmatch(r"[a-f0-9]{32}", directory.name) is None or linked(directory) or not directory.is_dir():
        return None
    children = list(directory.iterdir())
    if any(linked(p) or not p.is_file() for p in children):
        return None
    names = {p.name for p in children}
    if names - (FILES | {"retention.json", "released"}) or not FILES | {"retention.json"} <= names:
        return None
    manifest = read_json(directory / "retention.json")
    if type(manifest.get("schema")) is not int or manifest["schema"] != 1 or manifest.get("token") != directory.name or set(manifest.get("files", {})) != FILES:
        return None
    if not valid_identity(manifest.get("owner")) or not valid_identity(manifest.get("worker")):
        return None
    completed = manifest.get("completed")
    if type(completed) not in (int, float) or not math.isfinite(completed) or not 0 < completed <= time.time():
        return None
    for name, expected in manifest["files"].items():
        if not isinstance(expected, str) or digest(directory / name) != expected:
            return None
    request, status = read_json(directory / "request.json"), read_json(directory / "status.json")
    if request.get("origin") != "rtc_field_editor" or request.get("token") != directory.name or status.get("state") != "complete" or type(status.get("return_code")) is not int or status["return_code"] != 0 or status.get("engine_error") is not False:
        return None
    if status.get("owner_pid") != manifest["owner"]["pid"] or status.get("worker_pid") != manifest["worker"]["pid"]:
        return None
    # Never delete while its original worker or a matching live child remains.
    worker = manifest["worker"]
    current = identity(worker["pid"])
    live_worker = current == worker or identity(status["child_pid"]) is not None
    owner = manifest["owner"]
    owner_live = identity(owner["pid"]) == owner
    open_result = owner_live and ("released" not in names or (directory / "released").read_text() != directory.name)
    return completed, not (live_worker or open_result or directory.name in protected)


def prune(base, protected=(), keep=5):
    """No recursion, no stale lock takeover, no legacy/failed/unknown job deletion."""
    base = Path(base)
    if type(keep) is not int or keep < 0 or base.name != "rtc_traversal" or base.parent.name != ".godot" or any(linked(p) for p in [base, *base.parents]):
        return []
    lock = base / ".retention_lock"
    try:
        lock.mkdir()
    except OSError:
        return []
    removed = []
    try:
        candidates = []
        for directory in base.iterdir():
            try:
                candidate = _candidate(base, directory, protected)
                if candidate is not None:
                    stamp, eligible = candidate
                    candidates.append((stamp, directory.name, directory, eligible))
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                continue
        for stamp, _, directory, eligible in sorted(candidates, reverse=True)[keep:]:
            if not eligible:
                continue
            try:
                # Recheck everything under the lock immediately before mutation.
                if _candidate(base, directory, protected) != (stamp, True):
                    continue
                for name in sorted(FILES | {"retention.json", "released"}):
                    path = directory / name
                    if path.exists():
                        path.unlink()
                directory.rmdir()
                removed.append(directory.name)
            except (OSError, ValueError, KeyError, TypeError, AttributeError):
                continue
    finally:
        lock.rmdir()
    return removed
