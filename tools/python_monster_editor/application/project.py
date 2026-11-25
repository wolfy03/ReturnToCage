"""The project the editor is connected to, and everything that depends on which project that is.

``generation`` grows whenever the project, the Godot executable or the drafts folder changes. Results of
background work carry the generation they were started with, so an answer about project A can never be
applied after the user switched to project B.
"""

from dataclasses import dataclass
from pathlib import Path
import stat

from bridge.client import engine_binary
from rtcmonster import DocumentError, document_revision, find_drafts, monster_catalog, scan_content
from rtcmonster.catalog import AVAILABLE, CONFLICT, IdCheck
from rtcmonster.schema import SUFFIX

PROJECT_MARKERS = ("project.godot", "autoload/content_registry.gd", "data/definitions/enemy_definition.gd")


class ProjectError(ValueError):
    """The chosen folder or executable cannot be used. ``code`` is a stable identifier."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def check_project_root(path):
    """Return the resolved project folder or raise ProjectError."""
    try:
        root = Path(path).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ProjectError("project_missing", str(error)) from error
    if not root.is_dir():
        raise ProjectError("project_missing", f"not a folder: {root}")
    for name in PROJECT_MARKERS:
        if not (root / name).is_file():
            raise ProjectError("not_a_returntocage_project", f"missing {name}")
    return root


def check_godot_path(path):
    """Return the engine binary to run. The Windows console launcher is replaced by its engine binary,
    because the launcher starts another process that would escape cancellation."""
    try:
        godot = Path(path).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ProjectError("godot_missing", str(error)) from error
    if not godot.is_file():
        raise ProjectError("godot_missing", f"not a file: {godot}")
    return engine_binary(godot)


@dataclass(frozen=True)
class RegistryResult:
    """Monster IDs a real Godot run reported, tied to the files that existed at that moment."""
    ids: frozenset
    scan_fingerprint: str
    generation: int
    engine_version: str = ""


class ProjectSession:
    def __init__(self):
        self.root = None
        self.godot = None
        self.drafts_folder = None
        self.generation = 0
        self._registry = None

    # ------------------------------------------------------------------ configuration
    def configure(self, root=None, godot=None, drafts_folder=None):
        """Set all three at once. Raises ProjectError and changes nothing when one of them is unusable."""
        new_root = None if not root else check_project_root(root)
        new_godot = None if not godot else check_godot_path(godot)
        new_drafts = None if not drafts_folder else Path(drafts_folder)
        if new_drafts is not None and not new_drafts.is_dir():
            raise ProjectError("drafts_folder_missing", f"not a folder: {new_drafts}")
        if (new_root, new_godot, new_drafts) != (self.root, self.godot, self.drafts_folder):
            self.root, self.godot, self.drafts_folder = new_root, new_godot, new_drafts
            self.generation += 1
            self._registry = None

    @property
    def connected(self):
        return self.root is not None

    # ------------------------------------------------------------------------ catalog
    def registry(self):
        """The Godot registry result, or None when there is none or it no longer describes the files."""
        result = self._registry
        if result is None or result.generation != self.generation or self.root is None:
            return None
        if scan_content(self.root, "enemies").fingerprint != result.scan_fingerprint:
            return None
        return result

    def accept_registry(self, ids, generation, engine_version=""):
        """Store a registry answer. Refused (False) when it was produced for an earlier project state."""
        if generation != self.generation or self.root is None:
            return False
        self._registry = RegistryResult(frozenset(ids), scan_content(self.root, "enemies").fingerprint,
                                        generation, engine_version)
        return True

    def catalog(self):
        drafts = find_drafts(self.drafts_folder) if self.drafts_folder else []
        registry = self.registry()
        return monster_catalog(self.root, drafts, None if registry is None else registry.ids)

    def id_status(self, monster_id, ignore_path=None, open_document=None, open_path=None):
        """ID check that also knows the document being edited but not yet saved.

        Pass ``open_document`` when the question is about *another* document (a new monster, a clone):
        it conflicts when it is new content with the same ID. A document asking about its own ID passes
        its path as ``ignore_path`` and no ``open_document``.
        """
        result = self.catalog().id_status(monster_id, ignore_path)
        same_file = ignore_path is not None and open_path is not None and Path(open_path) == Path(ignore_path)
        if result.status != CONFLICT and open_document is not None and not same_file \
                and open_document.monster_id == monster_id and open_document.data["source_binding"] is None:
            return IdCheck(CONFLICT, (str(open_path) if open_path else "(unsaved document)",),
                           "the document being edited uses this ID")
        return result

    def content_ids(self, folder):
        """IDs of ``data/content/<folder>`` or None when there is no readable project."""
        if self.root is None:
            return None
        scan = scan_content(self.root, folder)
        return sorted(scan.entries) if scan.available else None

    def loot_table_status(self, loot_table_id):
        """AVAILABLE / CONFLICT / UNKNOWN for a loot table a *new* monster would own."""
        ids = self.content_ids("loot")
        if ids is None:
            return "unknown"
        return CONFLICT if loot_table_id in ids else AVAILABLE


def delete_draft(path, expected_revision):
    """Delete a draft file. Only ``.rtcmonster`` files, only regular files, only the revision that was shown.

    Game content can never be deleted through this function: nothing the game loads has this suffix.
    """
    path = Path(path)
    if path.suffix.lower() != SUFFIX:
        raise DocumentError("only .rtcmonster drafts can be deleted")
    state = path.lstat()
    if not stat.S_ISREG(state.st_mode) or (getattr(state, "st_file_attributes", 0)
                                          & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise DocumentError("not a regular draft file")
    if document_revision(path) != expected_revision:
        raise DocumentError("the draft changed on disk since it was listed; it was not deleted")
    path.unlink()
    lock = path.with_name(f".{path.name}.lock")
    if lock.is_file():
        try:
            lock.unlink()
        except OSError:
            pass
