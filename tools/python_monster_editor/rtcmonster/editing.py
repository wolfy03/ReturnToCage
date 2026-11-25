"""Edits: the only way a document changes.

An edit is a small value describing one change. ``document.apply(*edits)``
applies a list of them to a private copy and normalizes the result once, so

* several changes that only make sense together are one step (one Undo entry),
* a failure anywhere leaves the original document untouched,
* nothing can be stored without passing the schema's shape check.

Paths are tuples of keys and list indexes, e.g. ``("behavior", "states", 2, "params", "seconds")``.
``schema.parse_path`` turns the dotted path of a validation finding into one.

This is deliberately not a command framework: there are five edit kinds and
they cover what the planned editors need (field edits, list insert / remove /
reorder, and ID renames that keep references intact).
"""

from dataclasses import dataclass
import re

from .schema import REFERENCE_SOURCES, format_path
from .spec import ID_PATTERN, DocumentError, Id, Map

SET, INSERT, REMOVE, MOVE, RENAME = "set", "insert", "remove", "move", "rename"


@dataclass(frozen=True)
class Edit:
    kind: str
    path: tuple = ()
    value: object = None
    index: int | None = None
    reference: str = ""
    old: str = ""
    new: str = ""


def set_value(path, value):
    """Replace the value at ``path``."""
    return Edit(SET, tuple(path), value)


def insert_item(path, value, index=None):
    """Insert ``value`` into the list at ``path``. ``index=None`` appends."""
    return Edit(INSERT, tuple(path), value, index)


def remove_item(path):
    """Remove the list item or map entry at ``path``."""
    return Edit(REMOVE, tuple(path))


def move_item(path, index):
    """Move the list item at ``path`` to position ``index`` of the same list."""
    return Edit(MOVE, tuple(path), None, index)


def rename_id(reference, old, new):
    """Rename an image, animation, hitbox, pattern or state and every field that refers to it."""
    return Edit(RENAME, reference=reference, old=old, new=new)


def _container(data, path):
    target = data
    for key in path:
        target = target[key]
    return target


def _copy(value):
    # The caller keeps ownership of what it passed in; later changes to it must not reach the document.
    from .document import thaw
    return thaw(value)


def _apply(data, edit, schema):
    if not edit.path:
        raise DocumentError("an edit needs a path")
    parent, key = _container(data, edit.path[:-1]), edit.path[-1]
    if edit.kind == SET:
        if isinstance(parent, dict) and key not in parent:
            raise KeyError(key)
        parent[key] = _copy(edit.value)
    elif edit.kind == INSERT:
        target = parent[key]
        if not isinstance(target, list):
            raise TypeError("not a list")
        position = len(target) if edit.index is None else edit.index
        if type(position) is not int or not 0 <= position <= len(target):
            raise IndexError(position)
        target.insert(position, _copy(edit.value))
    elif edit.kind == REMOVE:
        if isinstance(parent, list) and type(key) is not int:
            raise TypeError("list index expected")
        del parent[key]
    elif edit.kind == MOVE:
        if not isinstance(parent, list) or type(edit.index) is not int or not 0 <= edit.index < len(parent):
            raise IndexError(edit.index)
        parent.insert(edit.index, parent.pop(key))
    else:
        raise DocumentError(f"unknown edit kind: {edit.kind}")


def _rename(data, edit, schema):
    if edit.reference not in REFERENCE_SOURCES:
        raise DocumentError(f"unknown reference kind: {edit.reference}")
    if not re.fullmatch(ID_PATTERN, edit.new or ""):
        raise DocumentError(f"'{edit.new}' is not a valid identifier")
    rows = _container(data, REFERENCE_SOURCES[edit.reference])
    matches = [row for row in rows if row["id"] == edit.old]
    if len(matches) != 1:
        raise DocumentError(f"{edit.reference} '{edit.old}' " + ("does not exist" if not matches else "is ambiguous"))
    if edit.new != edit.old and any(row["id"] == edit.new for row in rows):
        raise DocumentError(f"{edit.reference} '{edit.new}' already exists")
    # Collect first, then write: the walk must not see a half-renamed document.
    fields = [(path, node) for path, node, value in schema.fields(data)
              if (isinstance(node, Id) and node.ref == edit.reference and value == edit.old)
              or (isinstance(node, Map) and node.key_ref == edit.reference and edit.old in value)]
    matches[0]["id"] = edit.new
    for path, node in fields:
        if isinstance(node, Map):
            target = _container(data, path)
            # Keep the entry's position among the keys; normalization sorts maps anyway.
            renamed = {(edit.new if key == edit.old else key): value for key, value in target.items()}
            target.clear()
            target.update(renamed)
        else:
            _container(data, path[:-1])[path[-1]] = edit.new


def apply_edits(data, edits, schema):
    """Apply edits to ``data`` (a plain private copy) in order and return it. Raises DocumentError."""
    for position, edit in enumerate(edits):
        if not isinstance(edit, Edit):
            raise DocumentError(f"edit {position} is not an Edit")
        try:
            if edit.kind == RENAME:
                # Earlier edits may have left defaults unfilled; the reference walk needs the full shape.
                data = schema.normalize(data)
                _rename(data, edit, schema)
            else:
                _apply(data, edit, schema)
        except DocumentError:
            raise
        except (KeyError, IndexError, TypeError) as error:
            where = format_path(edit.path) if edit.path else f"{edit.reference} {edit.old}"
            raise DocumentError(f"edit {position} ({edit.kind}) cannot be applied at {where}: no such field") from error
    return data
