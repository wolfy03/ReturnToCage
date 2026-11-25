"""What content exists in a project folder, found without running Godot.

A scan never hides a problem behind a usable answer:

* two files that define the same ID are *both* reported and neither wins,
* one unreadable file is a recorded problem, not an empty catalog,
* "found on disk" is not "registered in ContentRegistry" - only a Godot run
  can say the latter, and until then the status says ``discovered``.

Status ladder of a game monster:

    discovered  ->  registry_verified   (a Godot probe listed the ID)
                \\-> not_in_registry     (a Godot probe ran and did not list it)

A ``.rtcmonster`` file that was never published is ``draft``.
"""

from dataclasses import dataclass
import hashlib
from pathlib import Path
import re
import stat

from .spec import ID_PATTERN

MAX_TEXT_RESOURCE_BYTES = 1024 * 1024
# Godot writes LF, but a checkout may have converted the files; accept both line endings.
_ID_LINE = re.compile(r'^id = &"([^"\r\n]*)"\r?$', re.MULTILINE)
_NAME_LINE = re.compile(r'^display_name = "((?:[^"\\\r\n]|\\.)*)"\r?$', re.MULTILINE)
_UID = re.compile(r'uid="(uid://[a-z0-9]+)"')

# Problem codes. Stable identifiers; the text next to them is for people.
DUPLICATE_ID = "duplicate_id"
UNREADABLE = "unreadable"
INVALID_ENCODING = "invalid_encoding"
MISSING_ID = "missing_id"
INVALID_ID = "invalid_id"
NOT_A_REGULAR_FILE = "not_a_regular_file"
TOO_LARGE = "too_large"
FOLDER_UNAVAILABLE = "folder_unavailable"
DRAFT_UNREADABLE = "draft_unreadable"
DRAFT_SHADOWS_PUBLISHED = "draft_shadows_published"

DISCOVERED, REGISTRY_VERIFIED, NOT_IN_REGISTRY, DRAFT = "discovered", "registry_verified", "not_in_registry", "draft"


@dataclass(frozen=True)
class ContentEntry:
    id: str
    path: str            # project-relative, POSIX
    sha256: str
    uid: str = ""        # Godot resource UID when the file states one
    display_name: str = ""


@dataclass(frozen=True)
class CatalogProblem:
    code: str
    path: str
    detail: str = ""
    id: str = ""


@dataclass(frozen=True)
class ContentScan:
    folder: str
    available: bool            # False = the folder itself could not be listed
    entries: dict              # id -> ContentEntry, only IDs defined exactly once
    duplicates: dict           # id -> tuple of every path that defines it
    problems: tuple
    files: tuple               # ((path, sha256 or ""), ...) for every file looked at

    @property
    def fingerprint(self):
        """Changes whenever a file in the folder is added, removed or modified."""
        return hashlib.sha256(repr(self.files).encode("utf-8")).hexdigest()

    def changes_since(self, earlier):
        """``(added, removed, modified)`` paths relative to an earlier scan of the same folder."""
        now, then = dict(self.files), dict(earlier.files)
        return (tuple(sorted(set(now) - set(then))), tuple(sorted(set(then) - set(now))),
                tuple(sorted(path for path in set(now) & set(then) if now[path] != then[path])))


def _regular(path):
    info = path.lstat()
    return stat.S_ISREG(info.st_mode) and not (getattr(info, "st_file_attributes", 0)
                                               & stat.FILE_ATTRIBUTE_REPARSE_POINT)


def scan_content(project, folder):
    """Scan ``data/content/<folder>/*.tres``. Never raises for a problem inside the folder."""
    root = Path(project)
    directory = root / "data/content" / folder
    name = f"data/content/{folder}"
    try:
        paths = sorted(path for path in directory.iterdir() if path.suffix == ".tres")
    except OSError as error:
        return ContentScan(folder, False, {}, {}, (CatalogProblem(FOLDER_UNAVAILABLE, name, str(error)),), ())
    found, problems, files = {}, [], []
    for path in paths:
        relative = path.relative_to(root).as_posix()
        try:
            if not _regular(path):
                problems.append(CatalogProblem(NOT_A_REGULAR_FILE, relative, "links and junctions are not followed"))
                files.append((relative, ""))
                continue
            if path.stat().st_size > MAX_TEXT_RESOURCE_BYTES:
                problems.append(CatalogProblem(TOO_LARGE, relative, f"over {MAX_TEXT_RESOURCE_BYTES} bytes"))
                files.append((relative, ""))
                continue
            payload = path.read_bytes()
        except OSError as error:
            problems.append(CatalogProblem(UNREADABLE, relative, str(error)))
            files.append((relative, ""))
            continue
        digest = hashlib.sha256(payload).hexdigest()
        files.append((relative, digest))
        try:
            text = payload.decode("utf-8")
        except UnicodeError as error:
            problems.append(CatalogProblem(INVALID_ENCODING, relative, str(error)))
            continue
        match = _ID_LINE.search(text)
        if match is None:
            problems.append(CatalogProblem(MISSING_ID, relative, "no `id = &\"...\"` line; not a ContentDefinition?"))
            continue
        if not re.fullmatch(ID_PATTERN, match[1]):
            problems.append(CatalogProblem(INVALID_ID, relative, match[1], match[1]))
            continue
        label, uid = _NAME_LINE.search(text), _UID.search(text.partition("\n")[0])
        found.setdefault(match[1], []).append(
            ContentEntry(match[1], relative, digest, uid[1] if uid else "", label[1] if label else ""))
    entries, duplicates = {}, {}
    for content_id, rows in found.items():
        if len(rows) == 1:
            entries[content_id] = rows[0]
        else:
            duplicates[content_id] = tuple(row.path for row in rows)
            problems.extend(CatalogProblem(DUPLICATE_ID, row.path,
                                           "also defined by " + ", ".join(p for p in duplicates[content_id]
                                                                          if p != row.path), content_id)
                            for row in rows)
    return ContentScan(folder, True, entries, duplicates, tuple(problems), tuple(files))


@dataclass(frozen=True)
class MonsterEntry:
    monster_id: str
    display_name: str
    path: str                 # project-relative for game content, as given for drafts
    source: str               # "game" or "draft"
    registration: str         # discovered / registry_verified / not_in_registry / draft
    sha256: str = ""
    uid: str = ""


@dataclass(frozen=True)
class MonsterCatalog:
    available: bool
    entries: tuple
    problems: tuple
    registry_checked: bool    # True only when IDs from a real Godot run were supplied

    def find(self, monster_id):
        return [entry for entry in self.entries if entry.monster_id == monster_id]

    def is_id_free(self, monster_id):
        """True when a new monster may take this ID: nothing uses it and no duplicate claims it."""
        return not self.find(monster_id) and not any(problem.id == monster_id for problem in self.problems)


def monster_catalog(project, drafts=(), registry_ids=None):
    """Game monsters found on disk plus draft documents.

    ``registry_ids`` are the IDs a Godot probe reported from ContentRegistry.
    Without them every game monster stays ``discovered``: a file on disk does
    not prove the game registered it.
    """
    from .storage import read_document
    from .spec import DocumentError

    scan = scan_content(project, "enemies")
    checked = registry_ids is not None
    entries = [MonsterEntry(entry.id, entry.display_name, entry.path, "game",
                            DISCOVERED if not checked else
                            (REGISTRY_VERIFIED if entry.id in registry_ids else NOT_IN_REGISTRY),
                            entry.sha256, entry.uid)
               for entry in scan.entries.values()]
    problems = list(scan.problems)
    taken = set(scan.entries) | set(scan.duplicates)
    for path in drafts:
        try:
            document, revision = read_document(path)
        except (OSError, DocumentError) as error:
            problems.append(CatalogProblem(DRAFT_UNREADABLE, str(path), str(error)))
            continue
        if document.data["source_binding"] is None and document.monster_id in taken:
            problems.append(CatalogProblem(DRAFT_SHADOWS_PUBLISHED, str(path),
                                           "a published monster already uses this ID", document.monster_id))
        entries.append(MonsterEntry(document.monster_id, document.data["metadata"]["display_name"], str(path),
                                    "draft", DRAFT, revision))
    return MonsterCatalog(scan.available, tuple(entries), tuple(problems), checked)
