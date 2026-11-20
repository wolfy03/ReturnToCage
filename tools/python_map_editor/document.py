"""Versioned editing data and atomic draft I/O, independent of Qt and Godot."""

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

SUFFIX = ".rtcmap"
SCHEMA_VERSION = 1
MAX_FILE_BYTES = 64 * 1024
MIN_EXTENT = 64
MAX_EXTENT = 32768


class DocumentError(ValueError):
    pass


class DocumentConflict(DocumentError):
    pass


@dataclass(frozen=True)
class MapDocument:
    region_id: str = "new_region"
    display_name: str = ""
    width: int = 1600
    height: int = 900

    def __post_init__(self):
        if (not isinstance(self.region_id, str) or len(self.region_id) > 64
                or not re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", self.region_id)):
            raise DocumentError("region_id must be snake_case ASCII (1–64 characters)")
        if (not isinstance(self.display_name, str) or len(self.display_name) > 120
                or any(ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF for char in self.display_name)):
            raise DocumentError("display_name must be a single line of at most 120 characters")
        if any(type(value) is not int or not MIN_EXTENT <= value <= MAX_EXTENT
               for value in (self.width, self.height)):
            raise DocumentError(f"map extents must be integers between {MIN_EXTENT} and {MAX_EXTENT}")


def encode(document):
    data = {"schema_version": SCHEMA_VERSION, **asdict(document)}
    return (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def _unique_fields(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise DocumentError(f"duplicate field: {key}")
        data[key] = value
    return data


def decode(payload):
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("draft exceeds the schema's size limit")
    try:
        data = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_fields)
    except (UnicodeError, json.JSONDecodeError, RecursionError) as error:
        raise DocumentError("invalid UTF-8 JSON draft") from error
    if not isinstance(data, dict) or type(data.get("schema_version")) is not int:
        raise DocumentError("missing or invalid schema_version")
    if data.pop("schema_version") != SCHEMA_VERSION:
        raise DocumentError("unsupported draft version")
    if data.keys() != MapDocument.__dataclass_fields__.keys():
        raise DocumentError("unrecognized or missing draft fields")
    return MapDocument(**data)


def _draft_path(path):
    path = path.absolute()
    if path.suffix.lower() != SUFFIX:
        raise DocumentError("choose a regular .rtcmap file")
    for parent in path.parents:
        if parent.is_symlink() or parent.is_junction():
            raise DocumentError("draft directory must not be a symbolic link or junction")
    _file_state(path)
    return path


def _file_state(path):
    try:
        state = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(state.st_mode) or (
            getattr(state, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise DocumentError("choose a regular file without symbolic links or reparse points")
    return state


@contextmanager
def _save_lock(path):
    # Keep a stable sidecar so concurrent processes always lock the same file,
    # even across replacement of the document. Closing the handle releases it.
    sidecar = path.with_name(f".{path.name}.lock")
    _file_state(sidecar)
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    with os.fdopen(os.open(sidecar, flags, 0o600), "r+b") as stream:
        if _file_state(sidecar) is None or not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise DocumentError("invalid document lock file")
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                raise DocumentConflict("another editor is saving this file") from error
            raise
        yield


def _read(path):
    with path.open("rb") as stream:
        payload = stream.read(MAX_FILE_BYTES + 1)
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("draft exceeds the schema's size limit")
    return payload


def read_document(path):
    payload = _read(_draft_path(path))
    return decode(payload), hashlib.sha256(payload).hexdigest()


def document_revision(path):
    """Snapshot existing bytes before showing an overwrite confirmation."""
    try:
        return hashlib.sha256(_read(_draft_path(path))).hexdigest()
    except FileNotFoundError:
        return None


def write_document(path, document, expected_hash=None):
    """Publish a new file exclusively or replace the previously opened revision."""
    path = _draft_path(path)
    payload = encode(document)
    with _save_lock(path):
        _publish_document(path, payload, expected_hash)
    return hashlib.sha256(payload).hexdigest()


def _publish_document(path, payload, expected_hash):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".rtcmap-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            if expected_hash is None:
                try:
                    if os.name == "nt":
                        temporary.rename(path)  # Windows rename fails if the target exists.
                    else:
                        os.link(temporary, path)
                except FileExistsError as error:
                    raise DocumentConflict("a file already exists at this location") from error
            else:
                state = _file_state(_draft_path(path))
                if state is not None and not state.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                    raise PermissionError(f"document is read-only: {path}")
                actual_hash = document_revision(path)
                if actual_hash != expected_hash:
                    raise DocumentConflict("the file changed on disk")
                os.replace(temporary, path)
        finally:
            stream.close()
            temporary.unlink(missing_ok=True)
