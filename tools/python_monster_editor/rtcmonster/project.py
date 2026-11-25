"""Read-only inspection of files in a ReturnToCage project folder, without running Godot.

These checks are static: they read files and never load a Godot resource. What
only the engine can answer stays NOT_EVALUATED until check_godot_contract.py
or the future bridge runs. The content catalog itself lives in catalog.py.
"""

import hashlib
from pathlib import Path
import stat

from . import png
from .catalog import MAX_TEXT_RESOURCE_BYTES, _ID_LINE, scan_content
from .schema import MAX_IMAGE_BYTES, MAX_IMAGE_EXTENT
from .spec import DocumentError, safe_relative_path

SOURCE_SUFFIXES = (".tres", ".tscn", ".gd", ".png")


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
    """``(width, height)`` from the header only. Says nothing about whether the pixel data is intact."""
    with Path(path).open("rb") as stream:
        header = stream.read(33)
    try:
        info = png.read_header(header, MAX_IMAGE_EXTENT)
    except png.PngError as error:
        raise DocumentError(str(error)) from error
    return info.width, info.height


def inspect_image(project, relative):
    """``(width, height, sha256)`` of a project PNG that passed the path, header and integrity checks.

    Raises FileNotFoundError, DocumentError (path) or png.PngError (header or integrity).
    Whether Godot can import the image is not checked here.
    """
    path = resolve_project_file(project, relative, (".png",), MAX_IMAGE_BYTES)
    payload = path.read_bytes()
    info = png.read_header(payload, MAX_IMAGE_EXTENT)
    png.verify(payload, info)
    return info.width, info.height, hashlib.sha256(payload).hexdigest()


def content_ids(project, folder):
    """``{id: project-relative path}`` for IDs defined by exactly one file.

    Compatibility view of ``catalog.scan_content``: duplicated IDs and
    unreadable files are left out here and reported by the scan's ``problems``.
    """
    return {content_id: entry.path for content_id, entry in scan_content(project, folder).entries.items()}


def published_monsters(project):
    """``{monster_id: {"display_name", "path"}}`` of the EnemyDefinitions found on disk, one file per ID.

    This is the list the Python Map Editor offers for enemy spawns. It means
    "found", not "registered by the game"; see ``catalog.monster_catalog``.
    """
    return {monster_id: {"display_name": entry.display_name, "path": entry.path}
            for monster_id, entry in scan_content(project, "enemies").entries.items()}


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
            path = resolve_project_file(project, entry["path"], SOURCE_SUFFIXES, MAX_IMAGE_BYTES)
        except (OSError, DocumentError):
            rows.append((entry["path"], MISSING))
            continue
        rows.append((entry["path"], UNCHANGED if file_sha256(path) == entry["sha256"] else MODIFIED))
    return rows


def bind_sources(document, project, paths):
    """Return the document with ``source_binding.files`` rebuilt from the files on disk."""
    files = []
    for relative in sorted(set(paths)):
        path = resolve_project_file(project, relative, SOURCE_SUFFIXES, MAX_IMAGE_BYTES)
        files.append({"path": relative, "sha256": file_sha256(path)})
    return document.replace(("source_binding", "files"), files)
