"""One open document: its snapshots, its file and whether it differs from what is on disk.

Two different questions are kept apart on purpose:

* **dirty** – did the *content* change since it was last loaded or saved? Answered by comparing the
  current document's fingerprint with ``saved_fingerprint``. A file that was hand-formatted, or that
  lacks defaults, opens clean: reformatting on the next save is not a user edit.
* **disk_revision** – the hash of the exact bytes last read from or written to the file. It is only used
  to notice that somebody else changed the file before we overwrite it.

No Qt here. The GUI subscribes with ``subscribe`` and wraps the callbacks in signals.
"""

from dataclasses import dataclass
import itertools
from pathlib import Path

from rtcmonster.schema import REFERENCE_SOURCES, format_path
from rtcmonster.spec import Id

from rtcmonster import (DocumentError, EDITOR_EDITABLE_SECTIONS, clone_document, document_revision, new_document,
                        read_document, write_document)

HISTORY_LIMIT = 500
# Reference kinds whose targets this editor edits. A reference of another kind (to a state, to a pattern)
# names an object in a section that has no editor at all and never "follows" anything.
_FOLLOWED_KINDS = tuple(kind for kind, path in REFERENCE_SOURCES.items() if path[0] in EDITOR_EDITABLE_SECTIONS)


def _followable(node):
    return isinstance(node, Id) and node.ref in _FOLLOWED_KINDS


def _ids(data, kind):
    rows = data
    for key in REFERENCE_SOURCES[kind]:
        rows = rows[key]
    return {row["id"] for row in rows}


def _leaves(document):
    """``{section: {path: (node, value)}}`` of every plain value, from one walk of the document."""
    sections = {}
    for path, node, value in document.schema.fields(document.data):
        if path and not isinstance(value, (dict, list, tuple)):
            sections.setdefault(path[0], {})[tuple(path)] = (node, value)
    return sections
_session_ids = itertools.count(1)


@dataclass(frozen=True)
class HistoryEntry:
    document: object
    label: str = ""


class History:
    """Immutable document snapshots and a cursor. The same history serves every editor of the document."""

    def __init__(self, document, limit=HISTORY_LIMIT):
        self._items = [HistoryEntry(document, "")]
        self._cursor = 0
        self._limit = max(2, limit)

    @property
    def current(self):
        return self._items[self._cursor].document

    @property
    def can_undo(self):
        return self._cursor > 0

    @property
    def can_redo(self):
        return self._cursor < len(self._items) - 1

    @property
    def undo_label(self):
        return self._items[self._cursor].label if self.can_undo else ""

    @property
    def redo_label(self):
        return self._items[self._cursor + 1].label if self.can_redo else ""

    def __len__(self):
        return len(self._items)

    def push(self, document, label=""):
        """Record a new snapshot. A new edit after an undo discards the redo branch."""
        del self._items[self._cursor + 1:]
        self._items.append(HistoryEntry(document, label))
        # The oldest snapshots are dropped first; snapshots share unchanged parts, so this bounds the
        # number of steps rather than rescuing memory.
        overflow = len(self._items) - self._limit
        if overflow > 0:
            del self._items[:overflow]
        self._cursor = len(self._items) - 1

    def undo(self):
        if not self.can_undo:
            return False
        self._cursor -= 1
        return True

    def redo(self):
        if not self.can_redo:
            return False
        self._cursor += 1
        return True


class DocumentSession:
    """The single owner of the current document. Every editor reads and edits through it."""

    def __init__(self, document, path=None, disk_revision=None, saved_fingerprint=None):
        self.session_id = next(_session_ids)
        self.history = History(document)
        self.path = None if path is None else Path(path)
        self.disk_revision = disk_revision
        self.saved_fingerprint = saved_fingerprint
        self.generation = 0            # grows with every change of the current document
        self._listeners = []

    # ------------------------------------------------------------------ construction
    @classmethod
    def create(cls, monster_id, display_name, **fields):
        """A new, never saved document. ``fields`` are ``section.key`` values set on top of the defaults."""
        document = new_document(monster_id, display_name)
        if fields:
            from rtcmonster import parse_path, set_value
            document = document.apply(*(set_value(parse_path(path), value) for path, value in fields.items()))
        return cls(document)

    @classmethod
    def open(cls, path):
        document, revision = read_document(path)
        return cls(document, path, revision, document.fingerprint)

    @classmethod
    def clone_of(cls, document, monster_id, display_name=None, loot_table_id=None):
        """A draft copy under a new ID. Never bound to the original's resources."""
        copy = clone_document(document, monster_id, display_name)
        if loot_table_id is not None and copy.data["loot"]["entries"] is not None:
            copy = copy.replace(("loot", "loot_table_id"), loot_table_id)
        return cls(copy)

    # ------------------------------------------------------------------------ state
    @property
    def document(self):
        return self.history.current

    @property
    def dirty(self):
        return self.document.fingerprint != self.saved_fingerprint

    @property
    def can_undo(self):
        return self.history.can_undo

    @property
    def can_redo(self):
        return self.history.can_redo

    @property
    def binding(self):
        return self.document.data["source_binding"]

    @property
    def is_draft_of_new_content(self):
        return self.binding is None

    def _declared(self, section):
        """What the document's binding says about a section. A draft of new content has no binding and
        everything in it is its own. An imported document owns only what its binding names ``editable``:
        a section the binding does not mention at all is the game's, not the editor's."""
        if self.binding is None:
            return "editable"
        return self.binding.get("editability", {}).get(section, "read_only")

    def editability(self, section):
        """``editable``, ``read_only`` or ``unsupported`` for a top-level section."""
        if section not in EDITOR_EDITABLE_SECTIONS:
            return "read_only"
        return self._declared(section)

    def is_editable(self, path):
        return bool(path) and self.editability(path[0]) == "editable"

    def _follows_a_reference(self, path):
        """True for a reference field in a section that merely has no editor yet.

        Attack patterns and behaviour states are not editable in this editor, but they name clips and
        hitboxes that are. When such an object is replaced, the field that names it has to follow, or the
        document would be left pointing at nothing. Only ``Id(ref=...)`` fields qualify, and never in a
        section an imported document declares read-only: those belong to the game's own scripts.
        """
        section = path[0]
        if section in EDITOR_EDITABLE_SECTIONS or self._declared(section) != "editable":
            return False
        try:
            node = self.document.schema.field(self.document.data, tuple(path))[0]
        except (DocumentError, KeyError, IndexError, TypeError):
            return False
        return _followable(node)

    def _protected_change(self, old, new):
        """Why ``new`` may not replace ``old``, or "" when it may.

        The per-edit check above looks at paths. This looks at the *result*, which is what matters: a
        rename has no path and rewrites every field that names the object, and several edits together can
        add up to something none of them is alone. After the edits,

        * a section this session may not edit is unchanged - except, in a draft's sections that merely
          have no editor yet, reference fields that now name another existing clip, image or hitbox;
        * no reference from such a section points at an object the edits removed. The user could not
          repair it there, so the edit that would strand it is refused instead.
        """
        targets_changed = any(_ids(old.data, kind) != _ids(new.data, kind) for kind in _FOLLOWED_KINDS)
        walked = []                                   # both documents are walked once, and only when needed
        for section in new.data:
            protected = self.editability(section) != "editable"
            if not protected:
                continue
            same = old.data[section] == new.data[section]
            if same and not targets_changed:
                continue
            if not walked:
                walked += [_leaves(old), _leaves(new)]
            before, after = walked[0].get(section, {}), walked[1].get(section, {})
            if not same:
                if set(before) != set(after):
                    return f"{section} is {self.editability(section)} in this document"
                may_follow = section not in EDITOR_EDITABLE_SECTIONS and self._declared(section) == "editable"
                for path, (node, value) in after.items():
                    if before[path][1] == value:
                        continue
                    if not may_follow or not _followable(node):
                        return f"{format_path(path)}: {section} is {self.editability(section)} in this document"
                    if value not in _ids(new.data, node.ref):
                        return (f"{format_path(path)}: a reference in {section} can follow its target to another "
                                f"{node.ref}, not be cleared or point at {value!r}")
            for path, (node, value) in after.items():
                if _followable(node) and value and value not in _ids(new.data, node.ref) \
                        and value in _ids(old.data, node.ref):
                    return (f"{format_path(path)} in {section} still names {node.ref} {value!r}; {section} cannot be "
                            "edited here, so the object it names cannot be removed or renamed away")
        return ""

    def subscribe(self, listener):
        """``listener(session, reason)`` with reason in edit / undo / redo / saved / replaced."""
        self._listeners.append(listener)

    def _changed(self, reason):
        self.generation += 1
        for listener in list(self._listeners):
            listener(self, reason)

    # ---------------------------------------------------------------------- editing
    def apply(self, *edits, label=""):
        """Apply edits as one undo step. Returns False for a no-op; raises DocumentError and changes nothing
        when an edit is not allowed or structurally invalid."""
        for edit in edits:
            path = getattr(edit, "path", ())
            if path and not self.is_editable(path) and not self._follows_a_reference(path):
                raise DocumentError(f"{path[0]} is {self.editability(path[0])} in this document")
            kind = getattr(edit, "reference", "")
            if not path and kind in REFERENCE_SOURCES and not self.is_editable(REFERENCE_SOURCES[kind]):
                # A rename has no path of its own; it is an edit of the section that defines the object.
                section = REFERENCE_SOURCES[kind][0]
                raise DocumentError(f"{section} is {self.editability(section)} in this document")
        changed = self.document.apply(*edits)
        if changed.fingerprint == self.document.fingerprint:
            return False
        refusal = self._protected_change(self.document, changed)
        if refusal:
            raise DocumentError(refusal)
        self.history.push(changed, label)
        self._changed("edit")
        return True

    def undo(self):
        if self.history.undo():
            self._changed("undo")
            return True
        return False

    def redo(self):
        if self.history.redo():
            self._changed("redo")
            return True
        return False

    # ----------------------------------------------------------------------- saving
    def save(self):
        """Write to the current path. Raises DocumentConflict / OSError and leaves every field untouched."""
        if self.path is None:
            raise DocumentError("the document has no file yet; use save_as")
        document = self.document
        revision = write_document(self.path, document, self.disk_revision)
        self._saved(self.path, document, revision)

    def save_as(self, path, replace_revision=None):
        """Write to another file.

        A file that already exists is only replaced when ``replace_revision`` is the revision the user
        saw when confirming; if the file changed since, ``DocumentConflict`` is raised.
        """
        document = self.document
        revision = write_document(path, document, replace_revision)
        self._saved(Path(path), document, revision)

    def _saved(self, path, document, revision):
        self.path = Path(path)
        self.disk_revision = revision
        self.saved_fingerprint = document.fingerprint
        self._changed("saved")

    def disk_changed(self):
        """True when the file is no longer the revision this session last read or wrote."""
        if self.path is None:
            return False
        try:
            return document_revision(self.path) != self.disk_revision
        except (OSError, DocumentError):
            return True

    def reload(self):
        """Replace the document with what is on disk. The history starts over."""
        document, revision = read_document(self.path)
        self.history = History(document)
        self.disk_revision = revision
        self.saved_fingerprint = document.fingerprint
        self._changed("replaced")
