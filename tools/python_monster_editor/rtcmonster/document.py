"""The in-memory monster document and its canonical JSON form. No Qt, no Godot."""

import copy
import json

from .schema import DOCUMENT_TYPE, SCHEMA_VERSION, TOP_LEVEL_ORDER, normalize
from .spec import DocumentError

MAX_FILE_BYTES = 8 * 1024 * 1024


class MonsterDocument:
    """An immutable, shape-checked document. Edits return a new document, which is what Undo/Redo stores."""

    __slots__ = ("_data",)

    def __init__(self, data):
        if not isinstance(data, dict):
            raise DocumentError("$: expected an object")
        object.__setattr__(self, "_data", normalize(copy.deepcopy(data)))

    def __setattr__(self, name, value):
        raise AttributeError("MonsterDocument is immutable; use replace()")

    def __eq__(self, other):
        return isinstance(other, MonsterDocument) and self._data == other._data

    __hash__ = None

    def __repr__(self):
        return f"MonsterDocument({self.monster_id!r})"

    @property
    def data(self):
        """The normalized body. Treat it as read-only; ``to_dict`` returns a private copy."""
        return self._data

    @property
    def monster_id(self):
        return self._data["monster_id"]

    def to_dict(self):
        return copy.deepcopy(self._data)

    def get(self, *path):
        value = self._data
        for key in path:
            value = value[key]
        return copy.deepcopy(value)

    def replace(self, path, value):
        """Return a copy with the value at ``path`` (a sequence of keys and list indexes) replaced."""
        data = self.to_dict()
        target = data
        try:
            for key in path[:-1]:
                target = target[key]
            if isinstance(target, dict) and path[-1] not in target:
                raise KeyError(path[-1])
            target[path[-1]] = value
        except (KeyError, IndexError, TypeError) as error:
            raise DocumentError(f"no such field: {'/'.join(map(str, path))}") from error
        return MonsterDocument(data)


def new_document(monster_id, display_name):
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
    })


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
    data.update((key, body[key]) for key in TOP_LEVEL_ORDER[2:])
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


def decode(payload):
    """Parse bytes into a document. Raises DocumentError for anything unreadable."""
    document, _ = decode_versioned(payload)
    return document


def decode_versioned(payload):
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
    return MonsterDocument(_MIGRATIONS[version](body)), version
