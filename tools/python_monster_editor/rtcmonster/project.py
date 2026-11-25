"""Read-only inspection of a ReturnToCage project folder, without running Godot.

These checks are static: they read files and never load a Godot resource. What
only the engine can answer stays NOT_EVALUATED until check_godot_contract.py
or the future bridge runs.
"""

import hashlib
from pathlib import Path
import re
import stat
import struct

from .schema import MAX_IMAGE_BYTES, MAX_IMAGE_EXTENT
from .spec import ID_PATTERN, DocumentError, safe_relative_path

_ID_LINE = re.compile(rf'^id = &"({ID_PATTERN})"$', re.MULTILINE)
_NAME_LINE = re.compile(r'^display_name = "((?:[^"\\]|\\.)*)"$', re.MULTILINE)
MAX_TEXT_RESOURCE_BYTES = 1024 * 1024
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def _regular(path):
    try:
        info = path.lstat()
    except OSError:
        return False
    return stat.S_ISREG(info.st_mode) and not (getattr(info, "st_file_attributes", 0)
                                               & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def resolve_project_file(project, relative, suffixes, maximum_bytes):
    """Return the file inside ``project`` or raise DocumentError. Links and escapes are refused."""
    name = safe_relative_path(relative, suffixes)
    root = Path(project).resolve()
    path = root / name
    for parent in path.parents:
        if parent == root:
            break
        if parent.is_symlink() or parent.is_junction():
            raise DocumentError(f"linked project path: {name}")
    if not path.resolve().is_relative_to(root):
        raise DocumentError(f"path leaves the project: {name}")
    if not _regular(path):
        raise FileNotFoundError(name)
    if path.stat().st_size > maximum_bytes:
        raise DocumentError(f"file exceeds {maximum_bytes} bytes: {name}")
    return path


def file_sha256(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def png_size(path):
    """``(width, height)`` from the IHDR chunk. Raises DocumentError for anything that is not a PNG."""
    with Path(path).open("rb") as stream:
        header = stream.read(24)
    if len(header) < 24 or header[:8] != PNG_SIGNATURE or header[12:16] != b"IHDR":
        raise DocumentError("not a PNG image")
    width, height = struct.unpack(">II", header[16:24])
    if not 0 < width <= MAX_IMAGE_EXTENT or not 0 < height <= MAX_IMAGE_EXTENT:
        raise DocumentError(f"image is {width}x{height}; the limit is {MAX_IMAGE_EXTENT}")
    return width, height


def inspect_image(project, relative):
    """``(width, height, sha256)`` of a project PNG."""
    path = resolve_project_file(project, relative, (".png",), MAX_IMAGE_BYTES)
    width, height = png_size(path)
    return width, height, file_sha256(path)


def content_ids(project, folder):
    """``{id: project-relative path}`` of the ContentDefinition .tres files in data/content/<folder>."""
    found = {}
    root = Path(project)
    try:
        for path in sorted((root / "data/content" / folder).glob("*.tres")):
            if _regular(path) and path.stat().st_size <= MAX_TEXT_RESOURCE_BYTES:
                match = _ID_LINE.search(path.read_text(encoding="utf-8"))
                if match:
                    found.setdefault(match[1], path.relative_to(root).as_posix())
    except (OSError, UnicodeError):
        return {}
    return found


def published_monsters(project):
    """``{monster_id: {"display_name", "path"}}`` of the EnemyDefinitions the game ships.

    This is the same catalog the Python Map Editor reads for enemy spawns, so a
    monster is "published" exactly when a map can already reference it.
    """
    result = {}
    root = Path(project)
    for monster_id, relative in content_ids(project, "enemies").items():
        text = (root / relative).read_text(encoding="utf-8")
        name = _NAME_LINE.search(text)
        result[monster_id] = {"display_name": name[1] if name else "", "path": relative}
    return result


def bound_definition_id(project, relative):
    """The ``id`` stored in a bound EnemyDefinition, or None when it cannot be read."""
    try:
        path = resolve_project_file(project, relative, (".tres",), MAX_TEXT_RESOURCE_BYTES)
        match = _ID_LINE.search(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, DocumentError):
        return None
    return match[1] if match else None


UNCHANGED, MODIFIED, MISSING = "unchanged", "modified", "missing"


def source_states(document, project):
    """``[(path, state)]`` for every file in ``source_binding.files``."""
    binding = document.data["source_binding"]
    rows = []
    for entry in (binding or {}).get("files", ()):
        try:
            path = resolve_project_file(project, entry["path"], (".tres", ".tscn", ".gd", ".png"), MAX_IMAGE_BYTES)
        except (OSError, DocumentError):
            rows.append((entry["path"], MISSING))
            continue
        rows.append((entry["path"], UNCHANGED if file_sha256(path) == entry["sha256"] else MODIFIED))
    return rows


def bind_sources(document, project, paths):
    """Return the document with ``source_binding.files`` rebuilt from the files on disk."""
    files = []
    for relative in sorted(set(paths)):
        path = resolve_project_file(project, relative, (".tres", ".tscn", ".gd", ".png"), MAX_IMAGE_BYTES)
        files.append({"path": relative, "sha256": file_sha256(path)})
    return document.replace(("source_binding", "files"), files)
