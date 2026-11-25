"""Declarative field specifications shared by decoding, validation and documentation.

A node answers three questions about one JSON value:

* ``normalize`` – is the *shape* readable (type, known keys, identifiers)? A
  failure raises :class:`DocumentError` and the document cannot be opened.
* ``check`` – is the value inside its allowed range? A failure is reported as
  a finding, so an editor can open the document and show what is wrong.
* ``describe`` – type, default, range, unit and support level, used to build
  inspectors and the schema reference without a second source of truth.
"""

from dataclasses import dataclass, field
import json
import math
import re

ID_PATTERN = r"[a-z][a-z0-9_]{0,63}"
MAX_SAFE_INTEGER = 2 ** 53

# Support levels. They describe what the game does with a stored value today.
APPLIED = "applied"      # read by the existing Godot runtime (EnemyDefinition, actor scene or profile)
CONTRACT = "contract"    # defined for the data-driven runtime and mirrors legacy behaviour; not executed from data yet
PLANNED = "planned"      # stored and validated only; no runtime reads it
EDITOR = "editor"        # editor bookkeeping, never part of the game

# What "support" means stage by stage. A stage that is False has not been built
# or not been verified; nothing here is aspirational.
CAPABILITY_STAGES = ("contract_defined", "static_validation", "editor_editable", "godot_resource_export",
                     "legacy_equivalent", "data_runtime", "multiplayer_verified")
CAPABILITIES = {
    APPLIED: {"contract_defined": True, "static_validation": True, "editor_editable": False,
              "godot_resource_export": False, "legacy_equivalent": True, "data_runtime": False,
              "multiplayer_verified": False},
    CONTRACT: {"contract_defined": True, "static_validation": True, "editor_editable": False,
               "godot_resource_export": False, "legacy_equivalent": True, "data_runtime": False,
               "multiplayer_verified": False},
    PLANNED: {"contract_defined": True, "static_validation": True, "editor_editable": False,
              "godot_resource_export": False, "legacy_equivalent": False, "data_runtime": False,
              "multiplayer_verified": False},
    EDITOR: {"contract_defined": True, "static_validation": True, "editor_editable": False,
             "godot_resource_export": False, "legacy_equivalent": False, "data_runtime": False,
             "multiplayer_verified": False},
}


def capabilities(support):
    """Stage-by-stage answer to "what can be done with a value of this support level today?"."""
    return dict(CAPABILITIES[support])


# Document sections the desktop editor can edit since MONSTER-STEP 2. The other
# sections are shown read-only until their editors exist (STEP 3 to 5).
EDITOR_EDITABLE_SECTIONS = ("metadata", "stats", "movement", "sensors", "loot")


def field_capabilities(path, support):
    """Capabilities of one field: its support level, refined by whether the editor can edit its section.

    ``path`` is a tuple path or its first element. Being editable in the
    editor says nothing about the game: ``data_runtime`` and
    ``multiplayer_verified`` stay as the support level says.
    """
    section = path if isinstance(path, str) else (path[0] if path else "")
    stages = capabilities(support)
    stages["editor_editable"] = section in EDITOR_EDITABLE_SECTIONS
    return stages


class DocumentError(ValueError):
    """The bytes or values cannot be read as a monster document."""


def _fail(path, message):
    raise DocumentError(f"{path or '$'}: {message}")


def _text(value, path, maximum, multiline=False):
    if not isinstance(value, str) or len(value) > maximum:
        _fail(path, f"expected text of at most {maximum} characters")
    for char in value:
        code = ord(char)
        if 0xD800 <= code <= 0xDFFF or (code < 32 and not (multiline and char in "\n\t")):
            _fail(path, "text contains control characters")
    return value


class Node:
    support = CONTRACT
    doc = ""
    required = False
    hint = ""        # UI-neutral editing hint, e.g. "multiline", "color", "slider"; never a widget class
    deprecated = ""  # non-empty = still read, no longer written by new editors; the text says what replaces it
    ref = ""         # for identifiers: the kind of object this field points at (see schema.REFERENCE_SOURCES)

    def default(self):
        raise NotImplementedError

    def normalize(self, value, path):
        raise NotImplementedError

    def check(self, value, path, report):
        """Report range problems as ``report(path, code, detail)``."""

    def describe(self):
        return {"type": type(self).__name__.lower()}

    def info(self):
        """Everything an inspector needs to build one form row, independent of any UI toolkit."""
        described = self.describe()
        return {
            "type": described["type"],
            "default": described.get("default"),
            "required": self.required,
            "minimum": getattr(self, "low", None) if "range" in described and hasattr(self, "low") else None,
            "maximum": getattr(self, "high", None) if "range" in described and hasattr(self, "high") else None,
            "exclusive_minimum": bool(getattr(self, "exclusive_low", False)),
            "range": described.get("range", ""),
            "unit": described.get("unit", ""),
            "choices": tuple(getattr(self, "options", ())),
            "reference": self.ref,
            "description": self.doc,
            "support": self.support,
            "deprecated": self.deprecated,
            "hint": self.hint,
            "editable": not self.deprecated,
        }


@dataclass(frozen=True)
class Num(Node):
    value: float | int | None = None
    low: float = -1_000_000
    high: float = 1_000_000
    unit: str = ""
    integer: bool = False
    exclusive_low: bool = False
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return self.value

    def normalize(self, value, path):
        if type(value) not in (int, float):
            _fail(path, "expected a number")
        if isinstance(value, float):
            if not math.isfinite(value):
                _fail(path, "number must be finite")
            if self.integer:
                _fail(path, "expected an integer")
            # 24.0 and 24 are the same authored value; store one spelling.
            if value.is_integer() and abs(value) < MAX_SAFE_INTEGER:
                value = int(value)
        elif abs(value) >= MAX_SAFE_INTEGER:
            _fail(path, "integer is outside the exactly representable range")
        return value

    def check(self, value, path, report):
        below = value <= self.low if self.exclusive_low else value < self.low
        if below or value > self.high:
            bracket = "(" if self.exclusive_low else "["
            report(path, "out_of_range", f"{value} is outside {bracket}{self.low}, {self.high}]")

    def describe(self):
        return {"type": "integer" if self.integer else "number", "default": self.value,
                "range": f"{'(' if self.exclusive_low else '['}{self.low}, {self.high}]", "unit": self.unit}


@dataclass(frozen=True)
class Bool(Node):
    value: bool = False
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return self.value

    def normalize(self, value, path):
        if type(value) is not bool:
            _fail(path, "expected true or false")
        return value

    def describe(self):
        return {"type": "boolean", "default": self.value}


@dataclass(frozen=True)
class Str(Node):
    value: str = ""
    maximum: int = 120
    multiline: bool = False
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return self.value

    def normalize(self, value, path):
        return _text(value, path, self.maximum, self.multiline)

    def describe(self):
        return {"type": "text", "default": self.value, "range": f"<= {self.maximum} characters"}


@dataclass(frozen=True)
class Id(Node):
    """Stable snake_case identifier. ``empty`` allows "" to mean "none"."""
    value: str = ""
    empty: bool = False
    ref: str = ""
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return self.value

    def normalize(self, value, path):
        if not isinstance(value, str) or not ((self.empty and value == "") or re.fullmatch(ID_PATTERN, value)):
            _fail(path, "expected a snake_case identifier (a-z, 0-9, _; at most 64 characters)"
                        + (' or ""' if self.empty else ""))
        return value

    def describe(self):
        return {"type": "id" + (' or ""' if self.empty else ""), "default": self.value}


@dataclass(frozen=True)
class Choice(Node):
    options: tuple = ()
    value: str = ""
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return self.value

    def normalize(self, value, path):
        if not isinstance(value, str) or value not in self.options:
            _fail(path, f"expected one of {', '.join(self.options)}")
        return value

    def describe(self):
        return {"type": "choice", "default": self.value, "range": " | ".join(self.options)}


@dataclass(frozen=True)
class ProjectPath(Node):
    """Project-relative POSIX path without ``res://``. "" means "none" when ``empty``."""
    suffixes: tuple = (".png",)
    empty: bool = True
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return ""

    def normalize(self, value, path):
        if self.empty and value == "":
            return value
        try:
            return safe_relative_path(value, self.suffixes)
        except DocumentError as error:
            _fail(path, str(error))

    def describe(self):
        return {"type": "project path", "default": "", "range": " | ".join(self.suffixes)}


def safe_relative_path(value, suffixes):
    """Reject anything that could leave the project: absolute, drive, ``..``, backslash."""
    if not isinstance(value, str) or not 0 < len(value) <= 512:
        raise DocumentError("expected a project-relative path")
    if (any(ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF or char in '\\:*?"<>|' for char in value)
            or value.startswith("/")
            or any(part in ("", ".", "..") or part.endswith((" ", ".")) for part in value.split("/"))):
        raise DocumentError(f"unsafe or non-relative path: {value!r}")
    if not value.lower().endswith(tuple(suffixes)):
        raise DocumentError(f"path must end with {' or '.join(suffixes)}: {value!r}")
    return value


@dataclass(frozen=True)
class Vec(Node):
    """Fixed-length list of numbers, for example a 2D vector or an [x, y, w, h] rectangle."""
    value: tuple | None = (0, 0)
    size: int = 2
    low: float = -1_000_000
    high: float = 1_000_000
    unit: str = "px"
    integer: bool = False
    exclusive_low: bool = False
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return None if self.value is None else list(self.value)

    def normalize(self, value, path):
        if not isinstance(value, (list, tuple)) or len(value) != self.size:
            _fail(path, f"expected a list of {self.size} numbers")
        item = Num(integer=self.integer)
        return [item.normalize(part, f"{path}[{index}]") for index, part in enumerate(value)]

    def check(self, value, path, report):
        item = Num(low=self.low, high=self.high, exclusive_low=self.exclusive_low)
        for index, part in enumerate(value):
            item.check(part, f"{path}[{index}]", report)

    def describe(self):
        return {"type": f"[{', '.join(['integer' if self.integer else 'number'] * self.size)}]",
                "default": self.default(),
                "range": f"each {'(' if self.exclusive_low else '['}{self.low}, {self.high}]", "unit": self.unit}


@dataclass(frozen=True)
class Opt(Node):
    """``null`` or the wrapped node. ``null`` always means "not set", never zero."""
    node: Node = None
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return None

    def normalize(self, value, path):
        return None if value is None else self.node.normalize(value, path)

    def check(self, value, path, report):
        if value is not None:
            self.node.check(value, path, report)

    def describe(self):
        inner = self.node.describe()
        return {**inner, "type": f"{inner['type']} or null", "default": None}

    def info(self):
        return {**self.node.info(), **{key: value for key, value in super().info().items()
                                       if key in ("type", "default", "required", "description", "support",
                                                  "deprecated", "hint", "editable")},
                "description": self.doc or self.node.doc}


@dataclass(frozen=True)
class Arr(Node):
    item: Node = None
    maximum: int = 256
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return []

    def normalize(self, value, path):
        if not isinstance(value, (list, tuple)) or len(value) > self.maximum:
            _fail(path, f"expected a list of at most {self.maximum} items")
        return [self.item.normalize(part, f"{path}[{index}]") for index, part in enumerate(value)]

    def check(self, value, path, report):
        for index, part in enumerate(value):
            self.item.check(part, f"{path}[{index}]", report)

    def describe(self):
        return {"type": f"list of {self.item.describe()['type']}", "default": [], "range": f"<= {self.maximum} items"}


@dataclass(frozen=True)
class Map(Node):
    """Object whose keys are identifiers, stored with sorted keys."""
    item: Node = None
    maximum: int = 64
    key_ref: str = ""
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return {}

    def normalize(self, value, path):
        if not isinstance(value, dict) or len(value) > self.maximum:
            _fail(path, f"expected an object of at most {self.maximum} entries")
        key_node = Id()
        return {key_node.normalize(key, f"{path}.{key}"): self.item.normalize(value[key], f"{path}.{key}")
                for key in sorted(value, key=str)}

    def check(self, value, path, report):
        for key, part in value.items():
            self.item.check(part, f"{path}.{key}", report)

    def describe(self):
        return {"type": f"map of id to {self.item.describe()['type']}", "default": {}}


@dataclass(frozen=True)
class Obj(Node):
    fields: dict = field(default_factory=dict)
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return self.normalize({}, "")

    def normalize(self, value, path):
        if not isinstance(value, dict):
            _fail(path, "expected an object")
        unknown = [key for key in value if key not in self.fields]
        if unknown:
            _fail(path, f"unknown field: {unknown[0]}")
        result = {}
        for key, node in self.fields.items():
            child = f"{path}.{key}" if path else key
            if key in value:
                result[key] = node.normalize(value[key], child)
            elif node.required:
                _fail(child, "required field is missing")
            else:
                result[key] = node.default()
        return result

    def check(self, value, path, report):
        for key, node in self.fields.items():
            node.check(value[key], f"{path}.{key}" if path else key, report)

    def describe(self):
        return {"type": "object"}


@dataclass(frozen=True)
class Union(Node):
    """Object selected by a tag field. Every variant shares the ``common`` fields."""
    tag: str = "type"
    variants: dict = field(default_factory=dict)
    common: dict = field(default_factory=dict)
    support: str = CONTRACT
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        raise DocumentError("a tagged object has no default")

    def variant(self, name):
        return Obj({self.tag: Choice(tuple(self.variants), required=True), **self.common, **self.variants[name]})

    def normalize(self, value, path):
        if not isinstance(value, dict) or not isinstance(value.get(self.tag), str):
            _fail(path, f"expected an object with a '{self.tag}' field")
        name = value[self.tag]
        if name not in self.variants:
            _fail(f"{path}.{self.tag}", f"unknown {self.tag} '{name}' (known: {', '.join(self.variants)})")
        return self.variant(name).normalize(value, path)

    def check(self, value, path, report):
        self.variant(value[self.tag]).check(value, path, report)

    def describe(self):
        return {"type": f"object by '{self.tag}'", "range": " | ".join(self.variants)}


@dataclass(frozen=True)
class AnyJson(Node):
    """Opaque JSON object the core preserves but never interprets."""
    maximum_bytes: int = 256 * 1024
    support: str = EDITOR
    doc: str = ""
    required: bool = False
    hint: str = ""
    deprecated: str = ""

    def default(self):
        return {}

    def normalize(self, value, path):
        if not isinstance(value, dict):
            _fail(path, "expected an object")
        try:
            text = json.dumps(value, ensure_ascii=False, allow_nan=False, sort_keys=True)
        except (TypeError, ValueError, RecursionError) as error:
            _fail(path, f"not plain finite JSON: {error}")
        if len(text.encode("utf-8")) > self.maximum_bytes:
            _fail(path, "opaque data exceeds its size limit")
        return json.loads(text)

    def describe(self):
        return {"type": "opaque object", "default": {}}
