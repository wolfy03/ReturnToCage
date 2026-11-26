"""Stage a monster's presentation in a copy of the project and check what Godot built. No Qt.

``stage_presentation`` is the whole MONSTER-STEP 3 export path:

1. make a ``StagingSession``: copy the project into a fresh folder outside it and mark the copy;
2. let Godot import the copy (new PNGs become textures);
3. run the bridge's ``stage_monster`` there: Godot builds a ``SpriteFrames`` and an
   ``EnemyAnimationProfile`` with ``ResourceSaver`` and readies a registered enemy actor with the profile;
4. check the response's shape and that every path it names lies inside the copy;
5. run ``read_stage`` in a *new* Godot process, so the readback comes from the files on disk and not from
   objects still in the first process's memory;
6. compare the readback, the staged images and the texture filter with the document.

Ownership of the copy
---------------------
A staging folder is created, used and deleted by one ``StagingSession``. Deleting needs the session
object: its ID must match the marker inside the copy, the folder must still be the one the session made
(not a link put in its place), and it must not contain or be the real project. A marker file alone
authorises nothing - ``remove_staging_copy(path)`` only works for a copy this process made.

``stage_presentation`` removes the copy before it returns, on every path: success, a bridge error, a
malformed response, an unexpected exception, a cancellation. Pass ``keep=True`` to own the copy
afterwards (``result.session.remove()``), or ``keep_on_failure=True`` to keep a failed one for
inspection; a cancelled run never keeps one. A copy that could not be deleted is reported, never hidden:
see ``StageResult.cleanup_error`` and ``leftovers()``.

The real project is never written: the copy is made first, the bridge refuses a project whose marker does
not carry this session's ID, and Python assembles no ``.tres`` text - every resource is created by the engine.

A stage that differs from the document is not an exception: ``StageResult.differences`` lists what
differs and ``passed`` is False. Exceptions (``BridgeError``) are for runs that produced no result.
"""

from dataclasses import dataclass, field
from datetime import datetime, timezone
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import stat
import tempfile
import time
import uuid

from . import client
from .client import BridgeError

MARKER = ".rtc_monster_staging"
STAGING_PREFIX = "rtc-monster-stage-"
OUTPUT_ROOT = "monster_stage"
# Top-level entries Godot does not need to load the game. ``.godot`` is copied: it holds the import cache,
# and without it every staging would re-import the whole project.
NOT_COPIED = (".git", ".github", ".claude", ".vscode", ".idea", "build", "docs", "devtools", "artifacts")
IGNORED_NAMES = ("__pycache__", ".pytest_cache")
IGNORED_SUFFIXES = (".pyc", ".tmp")
STAGE_FAILED, STAGING_INSIDE_PROJECT, NOTHING_TO_STAGE = "STAGE_FAILED", "STAGING_INSIDE_PROJECT", "NOTHING_TO_STAGE"
STAGING_UNSAFE_SOURCE, STAGING_TOO_LARGE, STAGING_NOT_OWNED, STAGING_CLEANUP_FAILED, RESOURCE_PATH_INVALID = (
    "STAGING_UNSAFE_SOURCE", "STAGING_TOO_LARGE", "STAGING_NOT_OWNED", "STAGING_CLEANUP_FAILED",
    "RESOURCE_PATH_INVALID")
IMPORT_TIMEOUT = 600
TOLERANCE = 1e-4
MAX_FILES = 200_000
MAX_BYTES = 8 * 1024 ** 3
FREE_SPACE_RESERVE = 256 * 1024 ** 2
CLEANUP_ATTEMPTS = 4
CLEANUP_PAUSE = 0.25
DEFAULT_TEXTURE_FILTER = 1          # CanvasItem.TEXTURE_FILTER_NEAREST, EnemyAnimationProfile's default
TEXTURE_FILTERS = range(0, 7)       # PARENT_NODE (inherit) .. LINEAR_WITH_MIPMAPS_ANISOTROPIC
PASS, FAIL, WARNING, NOT_EVALUATED = "PASS", "FAIL", "WARNING", "NOT_EVALUATED"
_REPARSE_POINT = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)

# Sessions made by this process whose folder still exists, by session ID.
_sessions = {}


def _delete_tree(path):
    """Delete a folder tree. Returns ``[(path, error)]`` for what could not be deleted. Follows no link."""
    failures = []
    shutil.rmtree(path, onexc=lambda _function, item, error: failures.append((str(item), error)))
    return failures


# ------------------------------------------------------------------------------------------- file safety
def is_link(path):
    """True for anything that is not the plain file or folder it looks like: a symbolic link, a Windows
    junction or any other reparse point. Never follows the entry."""
    try:
        status = os.lstat(path)
    except OSError:
        return False
    if stat.S_ISLNK(status.st_mode):
        return True
    if getattr(status, "st_file_attributes", 0) & _REPARSE_POINT:
        return True
    isjunction = getattr(os.path, "isjunction", None)
    return bool(isjunction and isjunction(path))


def _skipped(name, top_level):
    return (top_level and name in NOT_COPIED) or name in IGNORED_NAMES or name.endswith(IGNORED_SUFFIXES)


def survey(project):
    """``[(relative posix path, size, mtime_ns)]`` of every file a staging copy would hold, sorted.

    Raises ``STAGING_UNSAFE_SOURCE`` for a link, junction, reparse point or special file anywhere in that
    set: following one could copy files from outside the project, and leaving it out silently could drop
    a resource the game needs. The folders in ``NOT_COPIED`` are not looked into at all.
    """
    project = Path(project)
    rows, pending = [], [project]
    while pending:
        folder = pending.pop()
        try:
            entries = sorted(os.scandir(folder), key=lambda entry: entry.name)
        except OSError as error:
            raise BridgeError(STAGE_FAILED, f"cannot read {folder}: {error}") from error
        for entry in entries:
            if _skipped(entry.name, folder == project):
                continue
            path = Path(entry.path)
            relative = path.relative_to(project).as_posix()
            if is_link(path):
                raise BridgeError(STAGING_UNSAFE_SOURCE,
                                  f"{relative} is a link, junction or reparse point; a staging copy never follows one")
            try:
                status = os.lstat(path)
            except OSError as error:
                raise BridgeError(STAGE_FAILED, f"cannot read {relative}: {error}") from error
            if stat.S_ISDIR(status.st_mode):
                pending.append(path)
            elif stat.S_ISREG(status.st_mode):
                rows.append((relative, status.st_size, status.st_mtime_ns))
            else:
                raise BridgeError(STAGING_UNSAFE_SOURCE, f"{relative} is not a regular file or folder")
            if len(rows) > MAX_FILES:
                raise BridgeError(STAGING_TOO_LARGE, f"the project has more than {MAX_FILES} files to copy")
    return sorted(rows)


def _outside(project, folder):
    """True when ``folder`` neither is, contains, nor lies inside ``project`` (both resolved)."""
    return folder != project and project not in folder.parents and folder not in project.parents


# ------------------------------------------------------------------------------------------------ session
class StagingSession:
    """One staging copy: who made it, where it is, and the only way to delete it.

    States: ``ready`` (the copy exists and this object owns it), ``kept`` (left on disk on purpose),
    ``removed``, ``leftover`` (deleting failed; ``cleanup_error`` says why and ``remove`` can be retried).
    """

    def __init__(self, source, parent, operation=""):
        self.id = uuid.uuid4().hex
        self.source = Path(source)
        self.parent = Path(parent)                     # the folder this session created
        self.root = self.parent / "project"            # the project copy inside it
        self.operation = operation
        self.created = datetime.now(timezone.utc).isoformat(timespec="seconds")
        self.state = "new"
        self.files = self.bytes = 0
        self.seconds = 0.0
        self.changed_during_copy = ()                  # source files that moved under the copy
        self.cleanup_error = ""

    # ---- create
    @classmethod
    def create(cls, project, work_folder=None, cancel=None, operation="stage_presentation"):
        """Copy ``project`` into a new folder and mark it. Cancelling removes the partial copy."""
        started = time.monotonic()
        project = Path(project).resolve()
        if not (project / "project.godot").is_file():
            raise BridgeError(client.PROJECT_INVALID, f"not a Godot project: {project}")
        if is_link(project):
            raise BridgeError(STAGING_UNSAFE_SOURCE, f"the project folder itself is a link: {project}")
        if work_folder is not None:
            base = Path(work_folder).resolve()
            if base == project or project in base.parents:         # the project itself, or a folder inside it
                raise BridgeError(STAGING_INSIDE_PROJECT, "the staging folder must be outside the project")
        rows = survey(project)                         # refuses links before anything is created
        total = sum(size for _path, size, _time in rows)
        if total > MAX_BYTES:
            raise BridgeError(STAGING_TOO_LARGE, f"the project copy would be {total} bytes (limit {MAX_BYTES})")
        try:
            parent = Path(tempfile.mkdtemp(prefix=STAGING_PREFIX, dir=work_folder)).resolve()
        except OSError as error:
            raise BridgeError(STAGE_FAILED, f"cannot create a staging folder: {error}") from error
        session = cls(project, parent, operation)
        if not _outside(project, parent):
            session._delete_new()
            raise BridgeError(STAGING_INSIDE_PROJECT, "the staging folder must be outside the project")
        try:
            free = shutil.disk_usage(parent).free
            if free < total + FREE_SPACE_RESERVE:
                raise BridgeError(STAGING_TOO_LARGE, f"not enough free space for the staging copy: "
                                  f"{total} bytes needed, {free} free at {parent}")
            session._copy(rows, cancel)
            session._write_marker()
        except BaseException:
            session._delete_new()                      # a partial copy belongs to nobody yet: just remove it
            raise
        session.state = "ready"
        session.seconds = time.monotonic() - started
        _sessions[session.id] = session
        return session

    def _copy(self, rows, cancel):
        changed = []
        self.root.mkdir()
        made = {self.root}
        for relative, size, mtime in rows:
            if cancel is not None and cancel.is_set():
                raise BridgeError(client.CANCELLED, "the operation was cancelled")
            source, target = self.source / relative, self.root / relative
            try:
                if target.parent not in made:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    made.add(target.parent)
                if is_link(source):                    # replaced by a link since the survey
                    raise BridgeError(STAGING_UNSAFE_SOURCE, f"{relative} became a link while the project was copied")
                shutil.copyfile(source, target, follow_symlinks=False)
                shutil.copystat(source, target, follow_symlinks=False)
                after = os.lstat(source)
            except BridgeError:
                raise
            except OSError as error:
                raise BridgeError(STAGE_FAILED, f"cannot copy {relative}: {error}") from error
            if (after.st_size, after.st_mtime_ns) != (size, mtime):
                changed.append(relative)
            self.files += 1
            self.bytes += size
        self.changed_during_copy = tuple(changed)

    def _write_marker(self):
        text = json.dumps({"tool": "ReturnToCage Monster Editor", "session": self.id, "source": str(self.source),
                           "created": self.created, "operation": self.operation, "pid": os.getpid(),
                           "note": "staging copy; safe to delete"}, ensure_ascii=False, indent=2)
        try:
            (self.root / MARKER).write_text(text + "\n", encoding="utf-8")
        except OSError as error:
            raise BridgeError(STAGE_FAILED, f"cannot mark the staging copy: {error}") from error

    def _delete_new(self):
        """Remove a folder this constructor just made and nobody else has seen."""
        if self.parent.name.startswith(STAGING_PREFIX) and not is_link(self.parent) and _outside(self.source, self.parent):
            shutil.rmtree(self.parent, ignore_errors=True)
        self.state = "removed" if not self.parent.exists() else "leftover"

    # ---- queries
    @property
    def consistent(self):
        """False when a source file changed while it was being copied: the copy is not one snapshot."""
        return not self.changed_during_copy

    def describe(self):
        return {"session": self.id, "root": str(self.root), "source": str(self.source), "created": self.created,
                "operation": self.operation, "state": self.state, "files": self.files, "bytes": self.bytes,
                "changed_during_copy": list(self.changed_during_copy), "cleanup_error": self.cleanup_error}

    def owns(self, path):
        try:
            return Path(path).resolve() in (self.root.resolve(), self.parent.resolve())
        except OSError:
            return False

    # ---- delete
    def check_deletable(self):
        """Raise ``STAGING_NOT_OWNED`` unless the folder on disk is still the one this session made."""
        parent, root = self.parent, self.root

        def refuse(reason):
            raise BridgeError(STAGING_NOT_OWNED, f"refusing to delete {parent}: {reason}")
        if not parent.name.startswith(STAGING_PREFIX) or root.name != "project" or root.parent != parent:
            refuse("it does not have the shape of a staging folder")
        if is_link(parent) or is_link(root):
            refuse("it is a link, not the folder that was created")
        try:
            resolved, source = parent.resolve(strict=True), self.source.resolve()
        except OSError as error:
            refuse(f"it cannot be resolved ({error})")
        if resolved != parent:
            refuse("it no longer resolves to the path that was created")
        if not _outside(source, resolved):
            refuse("it contains, or lies inside, the real project")
        try:
            marker = json.loads((root / MARKER).read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            refuse(f"its marker cannot be read ({error})")
        if not isinstance(marker, dict) or marker.get("session") != self.id:
            refuse("its marker belongs to another staging session")

    def remove(self):
        """Delete the copy. Returns False when it was already gone.

        Raises ``STAGING_NOT_OWNED`` when the folder is not (any longer) this session's, and
        ``STAGING_CLEANUP_FAILED`` when files could not be deleted; then the session stays in
        ``leftovers()`` and ``remove`` can be called again.
        """
        if self.state == "removed":
            return False
        if not self.parent.exists():
            self.state = "removed"
            _sessions.pop(self.id, None)
            return False
        self.check_deletable()
        failures = []
        for attempt in range(CLEANUP_ATTEMPTS):
            failures = _delete_tree(self.parent)
            if not self.parent.exists():
                break
            if attempt + 1 < CLEANUP_ATTEMPTS:
                time.sleep(CLEANUP_PAUSE)              # Windows: a file Godot or a scanner still holds
        if self.parent.exists():
            path, error = failures[0] if failures else (str(self.parent), "unknown reason")
            self.state = "leftover"
            self.cleanup_error = f"{len(failures)} item(s) could not be deleted, first: {path}: {error}"
            raise BridgeError(STAGING_CLEANUP_FAILED,
                              f"the staging copy at {self.parent} was not fully deleted ({self.cleanup_error}). "
                              "The real project is not affected; delete the folder by hand or retry.")
        self.state, self.cleanup_error = "removed", ""
        _sessions.pop(self.id, None)
        return True

    def keep(self):
        """Leave the copy on disk on purpose. It is no longer cleaned up automatically."""
        if self.state == "ready":
            self.state = "kept"
        return self.root

    def __enter__(self):
        return self

    def __exit__(self, _kind, _error, _trace):
        if self.state == "ready":
            try:
                self.remove()
            except BridgeError:
                pass                                   # recorded in cleanup_error / leftovers(); never masks the real error
        return False


def leftovers():
    """Sessions of this process whose copy is still on disk: kept on purpose, or not deletable."""
    return [session for session in _sessions.values() if session.state in ("kept", "leftover")]


def find_stale_copies(work_folder=None):
    """Staging folders found on disk that this process did not make - left by a crashed or killed run.

    Diagnostic only: ``[{"path", "session", "created", "source", "pid"}]``. Nothing is deleted here, and
    nothing is ever deleted automatically: a folder found this way may belong to an editor that is still
    running. Delete one by hand once its marker shows it is yours and old.
    """
    base = Path(work_folder or tempfile.gettempdir())
    found = []
    try:
        candidates = sorted(entry for entry in base.iterdir() if entry.name.startswith(STAGING_PREFIX))
    except OSError:
        return found
    for parent in candidates:
        if any(session.parent == parent for session in _sessions.values()) or is_link(parent):
            continue
        row = {"path": str(parent), "session": "", "created": "", "source": "", "pid": None}
        try:
            marker = json.loads((parent / "project" / MARKER).read_text(encoding="utf-8"))
            if isinstance(marker, dict):
                row.update({key: marker.get(key, row[key]) for key in ("session", "created", "source", "pid")})
        except (OSError, ValueError):
            row["session"] = "(no readable marker)"
        found.append(row)
    return found


def make_staging_copy(project, work_folder=None, cancel=None):
    """Copy the project and return the copy's root. The session stays registered: ``remove_staging_copy``."""
    return StagingSession.create(project, work_folder, cancel).root


def remove_staging_copy(staging_root):
    """Delete a copy this process made. Anything else is refused, marker or not."""
    for session in list(_sessions.values()):
        if session.owns(staging_root):
            return session.remove()
    raise BridgeError(STAGING_NOT_OWNED, f"not a staging copy made by this process: {staging_root}")


# ------------------------------------------------------------------------------------------------- result
@dataclass(frozen=True)
class StageResult:
    monster_id: str
    staging_root: Path              # the project copy; gone unless ``kept``
    sprite_frames_path: str         # res:// paths inside the copy
    profile_path: str
    differences: tuple              # human-readable lines; empty when the stage matches the document
    profile: dict = field(default_factory=dict)      # Godot's readback from a second process
    attach: dict = field(default_factory=dict)       # what a carrier actor did with the profile
    attempts: int = 1
    seconds: float = 0.0
    session: object = None          # the StagingSession; the caller owns it when ``kept``
    kept: bool = False
    cleanup_error: str = ""         # the copy could not be deleted: where and why
    document_fingerprint: str = ""
    project_fingerprint: str = ""   # of the staged source images, see ``source_fingerprint``
    resources: dict = field(default_factory=dict)    # res:// path -> sha256 of each generated resource
    godot_version: str = ""
    areas: dict = field(default_factory=dict)        # area -> PASS / FAIL / WARNING / NOT_EVALUATED
    process: dict = field(default_factory=dict)      # attempts and exit codes of crashed attempts, per call
    notes: tuple = ()               # things worth knowing that are not differences

    @property
    def passed(self):
        """The resources Godot built and read back from disk equal the document.

        This is a structural comparison. It says nothing about how the monster looks when rendered
        (``areas["rendering"]``), and nothing about combat, networking or publishing, which no
        MONSTER-STEP 3 code runs: those areas are always ``NOT_EVALUATED`` here.
        """
        return not self.differences

    def is_current(self, document, project_fingerprint=None):
        """True while the result still describes ``document`` (and, when given, the same source images)."""
        return document.fingerprint == self.document_fingerprint and (
            project_fingerprint is None or project_fingerprint == self.project_fingerprint)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def source_fingerprint(project, document):
    """One hash over the files a stage of this document depends on: its images and the engine pin.

    A changed image, or another engine version, makes an earlier stage result stale.
    """
    digest = hashlib.sha256()
    names = sorted({row["path"] for row in document.data["assets"]["images"]}) + [".godot-version"]
    for name in names:
        digest.update(name.encode("utf-8") + b"\0")
        try:
            digest.update(file_sha256(Path(project) / name).encode("ascii"))
        except OSError:
            digest.update(b"missing")
        digest.update(b"\0")
    return digest.hexdigest()


# ------------------------------------------------------------------------------------------------ request
def texture_filter_of(document):
    """``(value, source)``: the sprite filter a stage of this document asks for.

    Schema V1 has no field for it. An imported document keeps the original profile's value in
    ``source_binding.passthrough.profile_texture_filter``; a document without it (a new draft, or a clone,
    which drops the binding) gets ``EnemyAnimationProfile``'s own default.
    """
    binding = document.data["source_binding"] or {}
    value = (binding.get("passthrough") or {}).get("profile_texture_filter")
    if isinstance(value, int) and not isinstance(value, bool) and value in TEXTURE_FILTERS:
        return value, "passthrough"
    return DEFAULT_TEXTURE_FILTER, "default"


def stage_request(document, carrier="", session_id=""):
    """The ``stage`` payload for a document: plain data, nothing but what the engine needs."""
    data = document.data
    request = {
        "images": {row["id"]: row["path"] for row in data["assets"]["images"]},
        "clips": [{"id": clip["id"], "fps": clip["fps"], "loop": clip["loop"],
                   "frames": [{"image": frame["image"],
                               "rect": list(frame["rect"]) if frame["rect"] is not None else None,
                               "duration": frame["duration"]} for frame in clip["frames"]]}
                  for clip in data["animations"]["clips"]],
        "presentation": {key: (list(value) if isinstance(value, (list, tuple)) else
                               dict(value) if key == "roles" else value)
                         for key, value in data["presentation"].items()},
        "carrier": carrier,
    }
    if session_id:
        request["staging_session"] = session_id
    value, source = texture_filter_of(document)
    if source == "passthrough":
        request["texture_filter"] = value
    return request


def import_assets(godot, staging_root, cancel=None, timeout=IMPORT_TIMEOUT):
    """Let the editor import the copy's assets. Returns the engine log."""
    code, log = client._run([str(godot), "--headless", "--path", str(staging_root), "--import"], staging_root,
                            cancel, timeout)
    if cancel is not None and cancel.is_set():
        raise BridgeError(client.CANCELLED, "the operation was cancelled", log)
    if code < 0 or code > 255:
        raise BridgeError(client.PROCESS_CRASH, f"Godot crashed while importing (exit {code}, 0x{code & 0xffffffff:08X})", log)
    if code != 0:
        raise BridgeError(STAGE_FAILED, f"Godot could not import the staging copy (exit {code})", log)
    return log


# ---------------------------------------------------------------------------------------- response checks
def _number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def _numbers(value, count):
    return isinstance(value, list) and len(value) == count and all(_number(item) for item in value)


def staged_file(staging_root, resource_path, suffixes, folder=""):
    """The file a ``res://`` path names inside the staging copy.

    Raises ``RESOURCE_PATH_INVALID`` for anything that is not a plain ``res://`` path to an existing
    regular file under ``folder`` of the copy: an OS path, ``..``, an unexpected extension, or a path
    that reaches outside the copy through a link.
    """
    def refuse(reason):
        raise BridgeError(RESOURCE_PATH_INVALID, f"{resource_path!r}: {reason}")
    if not isinstance(resource_path, str) or not resource_path.startswith("res://"):
        refuse("not a res:// path")
    relative = resource_path[len("res://"):]
    parts = relative.split("/")
    if not relative or "\\" in relative or ":" in relative or any(part in ("", ".", "..") for part in parts):
        refuse("not a plain project-relative path")
    if not relative.lower().endswith(tuple(suffixes)):
        refuse(f"expected one of {', '.join(suffixes)}")
    if folder and not relative.startswith(folder.rstrip("/") + "/"):
        refuse(f"not inside res://{folder}")
    root = Path(staging_root)
    path = root.joinpath(*parts)
    walked = root
    for part in parts:
        walked = walked / part
        if is_link(walked):
            refuse("reaches the file through a link")
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        refuse("the file does not exist")
    if root.resolve() not in resolved.parents or not resolved.is_file():
        refuse("not a file inside the staging copy")
    return path


def check_profile_readback(profile, staging_root):
    """Raise ``INVALID_RESPONSE`` unless a profile readback has the shape ``compare`` relies on."""
    def bad(what):
        raise BridgeError(client.INVALID_RESPONSE, f"profile readback: {what}")
    if not isinstance(profile, dict):
        bad("not an object")
    if "error" in profile and "animations" not in profile:
        bad(str(profile["error"]))
    if not isinstance(profile.get("animations"), dict) or not isinstance(profile.get("roles"), dict):
        bad("animations or roles missing")
    if not all(isinstance(value, str) for value in profile["roles"].values()):
        bad("a role is not a clip name")
    if not isinstance(profile.get("errors"), list):
        bad("errors missing")
    for key in ("visual_scale", "visual_offset"):
        if not _numbers(profile.get(key), 2):
            bad(f"{key} is not two finite numbers")
    for key in ("attack_hit_frame", "airborne_speed", "move_speed_threshold"):
        if not _number(profile.get(key)):
            bad(f"{key} is not a finite number")
    if not isinstance(profile.get("faces_right_by_default"), bool):
        bad("faces_right_by_default is not a boolean")
    if not isinstance(profile.get("texture_filter"), int) or isinstance(profile.get("texture_filter"), bool):
        bad("texture_filter is not an integer")
    for name, animation in profile["animations"].items():
        if not isinstance(animation, dict) or not _number(animation.get("fps")) or not isinstance(animation.get("loop"), bool) \
                or not isinstance(animation.get("frames"), list):
            bad(f"animation {name} is malformed")
        for index, row in enumerate(animation["frames"]):
            if not isinstance(row, dict) or not _number(row.get("duration")) or not _numbers(row.get("region"), 4):
                bad(f"animation {name} frame {index} is malformed")
            staged_file(staging_root, row.get("texture_path"), (".png",))
    return profile


def check_stage_response(data, session, monster_id):
    """Check the ``stage_monster`` response before anything in it is used. Returns the two resource files."""
    for key, kind in (("sprite_frames_path", str), ("profile_path", str), ("profile", dict), ("attach", dict)):
        if not isinstance(data.get(key), kind):
            raise BridgeError(client.INVALID_RESPONSE, f"stage response has no usable {key}")
    if data.get("monster_id") != monster_id:
        raise BridgeError(client.RESPONSE_MISMATCH, f"stage response is about {data.get('monster_id')!r}")
    if data.get("staging_session") != session.id:
        raise BridgeError(client.RESPONSE_MISMATCH, "stage response comes from another staging session")
    folder = f"{OUTPUT_ROOT}/{monster_id}"
    files = [staged_file(session.root, data[key], (".tres",), folder) for key in ("sprite_frames_path", "profile_path")]
    check_profile_readback(data["profile"], session.root)
    if data["profile"].get("sprite_frames_path") != data["sprite_frames_path"]:
        raise BridgeError(client.INVALID_RESPONSE, "the staged profile does not reference the staged SpriteFrames")
    attach = data["attach"]
    if not isinstance(attach.get("evaluated"), bool) or any(
            not isinstance(attach.get(mode, {}), dict) for mode in ("presentation", "server")):
        raise BridgeError(client.INVALID_RESPONSE, "attach result is malformed")
    return files


# ------------------------------------------------------------------------------------------------ compare
def _close(first, second):
    return abs(float(first) - float(second)) <= TOLERANCE


def _same_numbers(first, second):
    return len(first) == len(second) and all(_close(a, b) for a, b in zip(first, second))


def compare(document, profile, attach=None):
    """Lines describing where Godot's readback differs from the document. Empty means equal."""
    data = document.data
    presentation = data["presentation"]
    lines = []
    if not isinstance(profile, dict) or "animations" not in profile:
        return [f"Godot returned no profile readback: {profile.get('error') if isinstance(profile, dict) else profile!r}"]
    lines += [f"EnemyAnimationProfile.validation_errors: {error}" for error in profile.get("errors", [])]
    images = {row["id"]: row for row in data["assets"]["images"]}
    built = profile["animations"]
    wanted = {clip["id"]: clip for clip in data["animations"]["clips"]}
    for name in sorted(set(wanted) ^ set(built)):
        lines.append(f"clip {name}: {'missing from' if name in wanted else 'unexpected in'} the SpriteFrames")
    for name in sorted(set(wanted) & set(built)):
        clip, animation = wanted[name], built[name]
        if not _close(clip["fps"], animation["fps"]):
            lines.append(f"clip {name}: fps {animation['fps']} != {clip['fps']}")
        if bool(clip["loop"]) != bool(animation["loop"]):
            lines.append(f"clip {name}: loop {animation['loop']} != {clip['loop']}")
        if len(clip["frames"]) != len(animation["frames"]):
            lines.append(f"clip {name}: {len(animation['frames'])} frames != {len(clip['frames'])}")
            continue
        for index, (frame, row) in enumerate(zip(clip["frames"], animation["frames"])):
            image = images.get(frame["image"])
            if image is None:
                lines.append(f"clip {name} frame {index}: image {frame['image']} is not registered")
                continue
            rect = list(frame["rect"]) if frame["rect"] is not None else [0, 0, image["width"], image["height"]]
            if row.get("texture_path") != "res://" + image["path"]:
                lines.append(f"clip {name} frame {index}: texture {row.get('texture_path')} != res://{image['path']}")
            if not _same_numbers(row.get("region", []), rect):
                lines.append(f"clip {name} frame {index}: region {row.get('region')} != {rect}")
            if not _close(row.get("duration", 0), frame["duration"]):
                lines.append(f"clip {name} frame {index}: duration {row.get('duration')} != {frame['duration']}")
    for role, clip_id in presentation["roles"].items():
        if profile["roles"].get(role) != clip_id:
            lines.append(f"role {role}: {profile['roles'].get(role)!r} != {clip_id!r}")
    for key in ("visual_scale", "visual_offset"):
        if not _same_numbers(profile.get(key, []), presentation[key]):
            lines.append(f"{key}: {profile.get(key)} != {list(presentation[key])}")
    for key in ("attack_hit_frame", "airborne_speed", "move_speed_threshold"):
        if not _close(profile.get(key, float("nan")), presentation[key]):
            lines.append(f"{key}: {profile.get(key)} != {presentation[key]}")
    if profile.get("faces_right_by_default") != presentation["faces_right_by_default"]:
        lines.append(f"faces_right_by_default: {profile.get('faces_right_by_default')} != "
                     f"{presentation['faces_right_by_default']}")
    lines += compare_texture_filter(document, profile)
    if attach is not None:
        lines += compare_attach(document, profile, attach)
    return lines


def compare_texture_filter(document, profile):
    """The staged profile's sprite filter against the one the document carries (or the profile default).

    The values are ``CanvasItem.TextureFilter`` numbers and are compared as such: 0 (inherit from the
    parent) is its own value, not "whatever the parent happens to use".
    """
    expected, source = texture_filter_of(document)
    actual = profile.get("texture_filter")
    if actual != expected:
        return [f"texture_filter: {actual} != {expected} ({source})"]
    return []


def compare_attach(document, profile, attach):
    """Lines describing what went wrong when a carrier actor used the staged profile."""
    presentation = document.data["presentation"]
    if not attach.get("evaluated"):
        return [f"attach check not run: {attach.get('reason', 'unknown reason')}"]
    lines = []
    shown, server = attach.get("presentation", {}), attach.get("server", {})
    if not shown.get("has_presenter"):
        lines.append(f"carrier {attach.get('carrier')}: the actor built no animation presenter from the staged profile")
    else:
        if shown.get("sprite_frames_path") != profile.get("sprite_frames_path"):
            lines.append(f"carrier sprite uses {shown.get('sprite_frames_path')}, not the staged SpriteFrames")
        if not shown.get("frame_has_texture"):
            lines.append(f"carrier sprite has no texture for its first '{shown.get('animation')}' frame")
        if shown.get("animation") != presentation["roles"]["idle"]:
            lines.append(f"carrier sprite starts on {shown.get('animation')!r}, not the idle clip")
        if not _same_numbers(shown.get("sprite_position", []), presentation["visual_offset"]):
            lines.append(f"carrier sprite position {shown.get('sprite_position')} != visual_offset")
        scale = shown.get("presenter_scale", [])
        if len(scale) != 2 or not _close(abs(scale[0]), presentation["visual_scale"][0]) \
                or not _close(scale[1], presentation["visual_scale"][1]):
            lines.append(f"carrier presenter scale {scale} != visual_scale")
        if shown.get("texture_filter") != profile.get("texture_filter"):
            lines.append(f"carrier sprite texture_filter {shown.get('texture_filter')} != "
                         f"the profile's {profile.get('texture_filter')}")
    if server.get("has_presenter"):
        lines.append("the server-runtime actor built a presenter; it must not load any visual")
    return lines


def compare_images(document, staging_root):
    """``(differences, notes)`` about the staged PNG files against the hashes the document recorded.

    A stage builds frames from the file that is in the project *now*. When that file is not the one the
    document was authored against, the source rects may still fit and the stage would "pass" while
    showing other pixels - so a hash mismatch is a difference. An image registered without a hash cannot
    be compared and is noted instead.
    """
    differences, notes = [], []
    for row in document.data["assets"]["images"]:
        try:
            path = staged_file(staging_root, "res://" + row["path"], (".png",))
        except BridgeError as error:
            differences.append(f"image {row['id']}: {error.detail}")
            continue
        actual = file_sha256(path)
        if not row["sha256"]:
            notes.append(f"image {row['id']}: no content hash is recorded in the document, so the staged file "
                         "could not be compared with the one the document was made from")
        elif actual != row["sha256"]:
            differences.append(f"image {row['id']}: {row['path']} is not the file the document recorded "
                               f"(sha256 {actual[:12]}… != {row['sha256'][:12]}…); refresh the image in the editor")
    return differences, notes


def compare_readbacks(first, second):
    """Lines where the readback of a new process differs from what the building process reported."""
    if first == second:
        return []
    keys = sorted(key for key in set(first) | set(second) if first.get(key) != second.get(key))
    return [f"readback from disk differs from the building process in: {', '.join(keys)}"]


# -------------------------------------------------------------------------------------------------- stage
def stage_presentation(godot, project, document, work_folder=None, carrier="", cancel=None,
                       timeout=client.DEFAULT_TIMEOUT, keep_on_failure=False, keep=False):
    """Build the document's presentation in a staging copy and return a ``StageResult``.

    The copy is removed before this returns unless ``keep`` is set; then the caller owns
    ``result.session`` and removes it. Whatever goes wrong - a bridge error, a malformed response, any
    other exception - the copy is removed too, unless ``keep_on_failure`` asks for it to be kept for
    inspection (its path is then named in the error). A cancelled run never keeps one.
    """
    if not document.data["animations"]["clips"]:
        raise BridgeError(NOTHING_TO_STAGE, "the document has no animation clips")
    monster_id = document.data["monster_id"]
    fingerprint = document.fingerprint
    version = client.check_version(godot, project, cancel)
    started = time.monotonic()
    session = StagingSession.create(project, work_folder, cancel)
    result = None
    try:
        project_fingerprint = source_fingerprint(session.root, document)
        import_assets(godot, session.root, cancel)
        built = client.call(godot, session.root, "stage_monster", monster_id, cancel, timeout, work_folder,
                            stage=stage_request(document, carrier, session.id))
        files = check_stage_response(built.data, session, monster_id)
        # A second process: nothing of the first one's memory can stand in for the files.
        reread = client.call(godot, session.root, "read_stage", monster_id, cancel, timeout, work_folder,
                             stage={"staging_session": session.id})
        if reread.data.get("monster_id") != monster_id or reread.data.get("staging_session") != session.id:
            raise BridgeError(client.RESPONSE_MISMATCH, "read_stage answered about another stage", reread.log)
        profile = check_profile_readback(reread.data.get("profile"), session.root)
        resources = {built.data[key]: file_sha256(path) for key, path in zip(("sprite_frames_path", "profile_path"), files)}
        if reread.data.get("resources") != resources:
            raise BridgeError(client.INVALID_RESPONSE, "the engine and the editor disagree on the staged files' hashes",
                              reread.log)
        structure = compare(document, profile, built.data["attach"])
        disk = compare_readbacks(built.data["profile"], profile)
        image_lines, notes = compare_images(document, session.root)
        if not session.consistent:
            notes.append("project files changed while they were being copied (" + ", ".join(session.changed_during_copy[:5])
                         + "); the copy is not one consistent snapshot of the project")
        attach_ran = bool(built.data["attach"].get("evaluated"))
        attach_lines = compare_attach(document, profile, built.data["attach"]) if attach_ran else []
        areas = {
            "staging": PASS if session.consistent else WARNING,
            "resources": FAIL if [line for line in structure if line not in attach_lines] else PASS,
            "readback": FAIL if disk else PASS,
            "images": FAIL if image_lines else (WARNING if notes and any("hash" in note for note in notes) else PASS),
            "attach": NOT_EVALUATED if not attach_ran else (FAIL if attach_lines else PASS),
            # Nothing below is exercised by a stage. Headless structure checks are not a rendering check.
            "rendering": NOT_EVALUATED, "combat_runtime": NOT_EVALUATED, "network": NOT_EVALUATED,
            "publish": NOT_EVALUATED,
        }
        process = {"attempts": {"stage_monster": built.attempts, "read_stage": reread.attempts},
                   "crash_exit_codes": list(built.crashes) + list(reread.crashes)}
        result = StageResult(monster_id, session.root, built.data["sprite_frames_path"], built.data["profile_path"],
                             tuple(structure + disk + image_lines), profile, built.data["attach"],
                             max(built.attempts, reread.attempts), time.monotonic() - started, session, keep, "",
                             fingerprint, project_fingerprint, resources, version, areas, process, tuple(notes))
    except BaseException as error:
        cancelled = isinstance(error, BridgeError) and error.code == client.CANCELLED
        if keep_on_failure and not cancelled and isinstance(error, Exception):
            session.keep()
            if isinstance(error, BridgeError):
                raise BridgeError(error.code, f"{error.detail} (staging copy kept: {session.root})", error.log) from error
            raise
        _remove_quietly(session)
        raise
    if keep:
        session.keep()
        return result
    problem = _remove_quietly(session)
    if problem:
        # The check itself succeeded; the user must still hear that a folder was left behind.
        from dataclasses import replace
        result = replace(result, cleanup_error=problem)
    return result


def _remove_quietly(session):
    """Delete a session's copy. Returns "" or what could not be deleted; never raises."""
    try:
        session.remove()
    except BridgeError as error:
        return error.detail
    except OSError as error:
        session.state, session.cleanup_error = "leftover", str(error)
        return f"the staging copy at {session.parent} was not deleted: {error}"
    return ""
