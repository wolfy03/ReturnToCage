"""The in-memory monster document and its canonical JSON form. No Qt, no Godot.

Immutability
------------
A ``MonsterDocument`` never changes after construction. Its data is stored in
``FrozenDict`` / ``FrozenList``: real ``dict`` / ``list`` subclasses (so JSON
encoding, equality and every reader keep working, and nothing is copied on
read) whose mutating methods raise ``TypeError``. Every change goes through
``replace`` / ``apply``, which rebuild the document through normalization, so a
value of the wrong shape can never be stored.

This was chosen over defensive deep copies (every read would copy the whole
tree) and over persistent data structures (complexity without a measured
need). See docs/monster_editor_step1_stabilization.md for the measurements.
The guard is against accidents, not against an attacker: ``dict.__setitem__``
called on the base class still bypasses it, as with any Python object.
"""

import copy
import hashlib
import json

from .schema import DEFAULT_SCHEMA, DOCUMENT_TYPE, SCHEMA_VERSION
from .spec import DocumentError

MAX_FILE_BYTES = 8 * 1024 * 1024


def _blocked(self, *args, **kwargs):
    raise TypeError("MonsterDocument data is read-only; use document.replace() or document.apply()")


class FrozenDict(dict):
    """A dict that cannot be changed through its own methods."""
    __slots__ = ()
    __setitem__ = __delitem__ = clear = pop = popitem = setdefault = update = __ior__ = _blocked

    def __copy__(self):
        return dict(self)

    def __deepcopy__(self, memo):
        return {key: copy.deepcopy(value, memo) for key, value in self.items()}

    def __reduce__(self):
        return (dict, (dict(self),))


class FrozenList(list):
    """A list that cannot be changed through its own methods."""
    __slots__ = ()
    __setitem__ = __delitem__ = __iadd__ = __imul__ = _blocked
    append = extend = insert = pop = remove = clear = sort = reverse = _blocked

    def __copy__(self):
        return list(self)

    def __deepcopy__(self, memo):
        return [copy.deepcopy(value, memo) for value in self]

    def __reduce__(self):
        return (list, (list(self),))


def _same(item, old):
    """Identical object, or an equal scalar of the same type (1, 1.0 and True are different values here)."""
    return item is old or (not isinstance(item, (dict, list)) and type(item) is type(old) and item == old)


def freeze(value, previous=None):
    """Freeze ``value``. Parts equal to the frozen ``previous`` tree are reused instead of copied.

    Reuse is safe because frozen data cannot change, and it is what keeps an
    undo history small: a snapshot only owns the path that was edited.
    """
    if isinstance(value, dict):
        shared = type(previous) is FrozenDict
        frozen = FrozenDict((key, freeze(item, previous.get(key) if shared else None))
                            for key, item in value.items())
        if shared and list(frozen) == list(previous) and all(_same(item, previous[key])
                                                             for key, item in frozen.items()):
            return previous
        return frozen
    if isinstance(value, (list, tuple)):
        shared = type(previous) is FrozenList
        frozen = FrozenList(freeze(item, previous[index] if shared and index < len(previous) else None)
                            for index, item in enumerate(value))
        if shared and len(frozen) == len(previous) and all(_same(item, old) for item, old in zip(frozen, previous)):
            return previous
        return frozen
    return value


def thaw(value):
    """A plain, independent, mutable copy of frozen data."""
    if isinstance(value, dict):
        return {key: thaw(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [thaw(item) for item in value]
    return value


class MonsterDocument:
    """An immutable, shape-checked document. Edits return a new document, which is what Undo/Redo stores.

    Public surface: ``data`` (read-only view), ``to_dict()`` (mutable copy), ``get(*path)`` (mutable copy of one
    value), ``replace(path, value)``, ``apply(*edits)``, ``monster_id``, ``schema``, ``fingerprint``.
    """

    __slots__ = ("_data", "_schema", "_fingerprint")

    def __init__(self, data, schema=DEFAULT_SCHEMA, _previous=None):
        if not isinstance(data, dict):
            raise DocumentError("$: expected an object")
        # thaw() copies the caller's objects, so later changes to them cannot reach the document.
        object.__setattr__(self, "_data", freeze(schema.normalize(thaw(data)),
                                                 None if _previous is None else _previous._data))
        object.__setattr__(self, "_schema", schema)
        object.__setattr__(self, "_fingerprint", None)

    def __setattr__(self, name, value):
        raise AttributeError("MonsterDocument is immutable; use replace() or apply()")

    def __delattr__(self, name):
        raise AttributeError("MonsterDocument is immutable; use replace() or apply()")

    def __eq__(self, other):
        return isinstance(other, MonsterDocument) and self._data == other._data

    __hash__ = None

    def __repr__(self):
        return f"MonsterDocument({self.monster_id!r})"

    @property
    def data(self):
        """The normalized body as a read-only view. Nothing is copied; attempts to change it raise TypeError."""
        return self._data

    @property
    def schema(self):
        return self._schema

    @property
    def monster_id(self):
        return self._data["monster_id"]

    @property
    def fingerprint(self):
        """SHA-256 of the canonical bytes. Two documents with equal content share it; any edit changes it.

        It is the same value ``write_document`` returns as the file revision, so a clean document has
        ``document.fingerprint == revision``.
        """
        if self._fingerprint is None:
            object.__setattr__(self, "_fingerprint", hashlib.sha256(encode(self)).hexdigest())
        return self._fingerprint

    def to_dict(self):
        """A plain mutable copy of the whole body. Changing it never affects this document."""
        return thaw(self._data)

    def get(self, *path):
        """A plain mutable copy of the value at ``path``."""
        value = self._data
        try:
            for key in path:
                value = value[key]
        except (KeyError, IndexError, TypeError) as error:
            raise DocumentError(f"no such field: {'/'.join(map(str, path))}") from error
        return thaw(value)

    def replace(self, path, value):
        """Return a copy with the value at ``path`` (a sequence of keys and list indexes) replaced."""
        from .editing import set_value

        return self.apply(set_value(path, value))

    def apply(self, *edits):
        """Return a copy with every edit applied, or raise DocumentError and change nothing.

        The edits are applied to a private copy in order and the result is
        normalized once, so intermediate states never have to be valid and
        never become a document.
        """
        from .editing import apply_edits

        return MonsterDocument(apply_edits(self.to_dict(), edits, self._schema), self._schema, self)


def new_document(monster_id, display_name, schema=DEFAULT_SCHEMA):
    """Smallest document that passes structural validation: it stands still, can be hit and can die."""
    def on_done(state):
        return [{"to": state, "priority": 0, "condition": {"type": "ActionCompleted"}}]

    return MonsterDocument({
        "monster_id": monster_id,
        "metadata": {"display_name": display_name},
        "collision": {
            "body": {"shape": {"type": "rectangle", "center": [0, 0], "size": [32, 22]}},
            "hurtboxes": [{"id": "body", "shape": {"type": "rectangle", "center": [0, 0], "size": [38, 28]}}],
        },
        "behavior": {
            "initial_state": "idle",
            "states": [
                {"id": "idle", "module": "Wait", "transitions": on_done("idle")},
                {"id": "hurt", "module": "HurtReaction", "transitions": on_done("idle")},
                {"id": "dead", "module": "Death"},
            ],
        },
    }, schema)


def clone_document(document, monster_id, display_name=None):
    """A draft copy under a new ID.

    The copy is never bound to Godot resources: ``source_binding`` is cleared,
    because the files it listed belong to the original monster. The loot table
    ID is cleared for the same reason when the rows are managed by the document
    (two monsters must not write the same table); a reference to a table the
    document does not manage is kept.
    """
    if monster_id == document.monster_id:
        raise DocumentError("a copy needs a monster_id of its own")
    data = document.to_dict()
    data["monster_id"] = monster_id
    if display_name is not None:
        data["metadata"]["display_name"] = display_name
    data["source_binding"] = None
    if data["loot"]["entries"] is not None:
        data["loot"]["loot_table_id"] = f"{monster_id}_loot"[:64]
    return MonsterDocument(data, document.schema)


def _dump(value, depth=0):
    pad, inner = "  " * depth, "  " * (depth + 1)
    if isinstance(value, dict):
        if not value:
            return "{}"
        rows = [f"{inner}{json.dumps(key, ensure_ascii=False)}: {_dump(item, depth + 1)}"
                for key, item in value.items()]
        return "{\n" + ",\n".join(rows) + f"\n{pad}}}"
    if isinstance(value, list):
        if not value:
            return "[]"
        if all(type(item) in (int, float) for item in value):
            return "[" + ", ".join(_dump(item) for item in value) + "]"  # vectors and rectangles stay on one line
        return "[\n" + ",\n".join(f"{inner}{_dump(item, depth + 1)}" for item in value) + f"\n{pad}]"
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def encode(document):
    """Canonical bytes: fixed key order, two-space indent, UTF-8, LF, one trailing newline.

    Two documents that compare equal always encode to the same bytes, so a
    saved file changes only where its meaning changed.
    """
    body = document.data
    data = {"schema_version": SCHEMA_VERSION, "document_type": DOCUMENT_TYPE}
    data.update((key, body[key]) for key in document.schema.top_level_order[2:])
    payload = (_dump(data) + "\n").encode("utf-8")
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("document exceeds the size limit")
    return payload


def _unique_fields(pairs):
    data = {}
    for key, value in pairs:
        if key in data:
            raise DocumentError(f"duplicate field: {key}")
        data[key] = value
    return data


def _invalid_constant(value):
    raise DocumentError(f"invalid JSON constant: {value}")


def _v1(data):
    return data


# version -> function that turns that version's body into the current body.
_MIGRATIONS = {1: _v1}


def decode(payload, schema=DEFAULT_SCHEMA):
    """Parse bytes into a document. Raises DocumentError for anything unreadable."""
    document, _ = decode_versioned(payload, schema)
    return document


def decode_versioned(payload, schema=DEFAULT_SCHEMA):
    if not isinstance(payload, (bytes, bytearray)):
        raise DocumentError("expected bytes")
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("document exceeds the size limit")
    try:
        data = json.loads(bytes(payload).decode("utf-8"), object_pairs_hook=_unique_fields,
                          parse_constant=_invalid_constant)
    except DocumentError:
        raise
    except (UnicodeError, ValueError, RecursionError) as error:
        raise DocumentError("not a UTF-8 JSON document") from error
    if not isinstance(data, dict):
        raise DocumentError("$: expected an object")
    if data.get("document_type") != DOCUMENT_TYPE:
        raise DocumentError(f"document_type must be '{DOCUMENT_TYPE}'")
    version = data.get("schema_version")
    if type(version) is not int:
        raise DocumentError("missing or invalid schema_version")
    if version not in _MIGRATIONS:
        newer = " (written by a newer editor)" if version > SCHEMA_VERSION else ""
        raise DocumentError(f"unsupported schema_version {version}{newer}; this editor reads {sorted(_MIGRATIONS)}")
    body = {key: value for key, value in data.items() if key not in ("schema_version", "document_type")}
    return MonsterDocument(_MIGRATIONS[version](body), schema), version
