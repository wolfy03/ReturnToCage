"""Atomic, conflict-aware document files.

The algorithm is the one proven in tools/python_map_editor/document.py: a
sidecar lock, a temporary file in the same directory, an exclusive create for
new files and a hash-guarded replace for existing ones. It is repeated here
instead of imported because the map editor ships as flat modules inside a
frozen EXE; extracting a shared package is planned for MONSTER-STEP 2.
"""

from contextlib import contextmanager
import errno
import hashlib
import os
from pathlib import Path
import stat
import tempfile

from .document import MAX_FILE_BYTES, decode_versioned, encode
from .schema import SUFFIX
from .spec import DocumentError


class DocumentConflict(DocumentError):
    """The file on disk is not the revision the caller last read."""


def _file_state(path):
    try:
        state = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(state.st_mode) or (
            getattr(state, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise DocumentError("choose a regular file without symbolic links or reparse points")
    return state


def _document_path(path):
    path = Path(path).absolute()
    if path.suffix.lower() != SUFFIX:
        raise DocumentError(f"choose a regular {SUFFIX} file")
    for parent in path.parents:
        if parent.is_symlink() or parent.is_junction():
            raise DocumentError("document directory must not be a symbolic link or junction")
    _file_state(path)
    return path


@contextmanager
def _save_lock(path):
    # A stable sidecar, so concurrent processes lock the same file even while
    # the document itself is being replaced. Closing the handle releases it.
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
        raise DocumentError("document exceeds the size limit")
    return payload


def read_document(path):
    """Return ``(document, revision)``. The revision is the SHA-256 of the exact bytes read."""
    payload = _read(_document_path(path))
    document, _ = decode_versioned(payload)
    return document, hashlib.sha256(payload).hexdigest()


def document_revision(path):
    """Hash of the bytes on disk, or None when there is no file."""
    try:
        return hashlib.sha256(_read(_document_path(path))).hexdigest()
    except FileNotFoundError:
        return None


def write_document(path, document, expected_revision=None):
    """Create a new file, or replace the revision that was read.

    ``expected_revision=None`` only ever creates: an existing file is a
    conflict. Otherwise the file must still hash to ``expected_revision``; if
    someone else changed it, nothing is written. Either way the previous bytes
    stay intact until the new file is complete and flushed.
    """
    path = _document_path(path)
    payload = encode(document)
    with _save_lock(path):
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=TEMPORARY_PREFIX, delete=False) as stream:
            temporary = Path(stream.name)
            try:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
                stream.close()
                if expected_revision is None:
                    try:
                        if os.name == "nt":
                            temporary.rename(path)  # Windows rename fails if the target exists.
                        else:
                            os.link(temporary, path)
                    except FileExistsError as error:
                        raise DocumentConflict("a file already exists at this location") from error
                else:
                    state = _file_state(path)
                    if state is not None and not state.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                        raise PermissionError(f"document is read-only: {path}")
                    if document_revision(path) != expected_revision:
                        raise DocumentConflict("the file changed on disk")
                    os.replace(temporary, path)
            finally:
                stream.close()
                temporary.unlink(missing_ok=True)
    return hashlib.sha256(payload).hexdigest()


TEMPORARY_PREFIX = ".rtcmonster-"


def stale_temporaries(folder, older_than_seconds=3600):
    """Temporary files a killed save left behind in ``folder``.

    A save that runs to its end always removes its temporary file, also when
    it fails. Only a process that is killed between creating the file and
    renaming it can leave one. Such a file is never a document (its name has no
    ``.rtcmonster`` suffix) and is never read back. The age limit keeps a save
    that is in progress right now from being listed.
    """
    import time

    limit = time.time() - older_than_seconds
    found = []
    for path in Path(folder).iterdir():
        try:
            state = path.lstat()
        except OSError:
            continue
        if path.name.startswith(TEMPORARY_PREFIX) and stat.S_ISREG(state.st_mode) and state.st_mtime <= limit:
            found.append(path)
    return sorted(found)


def remove_stale_temporaries(folder, older_than_seconds=3600):
    """Delete what ``stale_temporaries`` lists and return the paths that were removed."""
    removed = []
    for path in stale_temporaries(folder, older_than_seconds):
        try:
            path.unlink()
        except OSError:
            continue
        removed.append(path)
    return removed
