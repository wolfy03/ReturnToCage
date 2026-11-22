"""Immutable object data in the Godot 2D coordinate system."""

from dataclasses import dataclass
import math
import re

MIN_SIZE = 4
MAX_GEOMETRY = 1_000_000
MAX_OBJECTS = 50_000
OBJECT_TYPES = ("platform", "decoration")


class DocumentError(ValueError):
    pass


def validate_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", value):
        raise DocumentError("invalid object or layer ID")


def validate_text(value, maximum):
    if (not isinstance(value, str) or len(value) > maximum
            or any(ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF for char in value)):
        raise DocumentError("invalid text")


def validate_texture(value):
    validate_text(value, 512)
    if value and (not value.lower().endswith(".png")
                  or any(char in value for char in '\\:*?"<>|')
                  or any(part in ("", ".", "..") or part.endswith((" ", "."))
                         for part in value.split("/"))):
        raise DocumentError("texture must be a project-relative PNG path")


def validate_number(value, low=-MAX_GEOMETRY, high=MAX_GEOMETRY):
    if type(value) not in (int, float) or not low <= value <= high:
        raise DocumentError(f"expected a finite number between {low} and {high}")


def validate_vector(values, low):
    if not isinstance(values, (tuple, list)) or len(values) != 2:
        raise DocumentError("expected a two-component vector")
    for value in values:
        validate_number(value, low)
    return tuple(values)


@dataclass(frozen=True, slots=True)
class MapLayer:
    id: str
    name: str
    visible: bool = True
    locked: bool = False

    def __post_init__(self):
        validate_id(self.id)
        validate_text(self.name, 120)
        if not self.name or type(self.visible) is not bool or type(self.locked) is not bool:
            raise DocumentError("invalid layer")


DEFAULT_LAYERS = (MapLayer("terrain", "지형"), MapLayer("decorations", "장식"))


@dataclass(frozen=True, slots=True)
class ObjectProperties:
    one_way: bool = False
    texture_path: str = ""

    def __post_init__(self):
        if type(self.one_way) is not bool:
            raise DocumentError("one_way must be a boolean")
        validate_texture(self.texture_path)


@dataclass(frozen=True, slots=True)
class MapObject:
    id: str
    type: str
    layer_id: str
    position: tuple
    size: tuple
    rotation: float = 0
    properties: ObjectProperties = ObjectProperties()

    def __post_init__(self):
        validate_id(self.id)
        validate_id(self.layer_id)
        if self.type not in OBJECT_TYPES or not isinstance(self.properties, ObjectProperties):
            raise DocumentError("unsupported object type or properties")
        if (self.type == "platform" and self.properties.texture_path
                or self.type == "decoration" and self.properties.one_way):
            raise DocumentError("properties do not match object type")
        object.__setattr__(self, "position", validate_vector(self.position, -MAX_GEOMETRY))
        object.__setattr__(self, "size", validate_vector(self.size, MIN_SIZE))
        validate_number(self.rotation)

    @classmethod
    def from_data(cls, data):
        if not isinstance(data, dict) or data.keys() != cls.__dataclass_fields__.keys():
            raise DocumentError("unrecognized or missing object fields")
        properties = data["properties"]
        if not isinstance(properties, dict):
            raise DocumentError("invalid object properties")
        return cls(**{**data, "properties": ObjectProperties(**properties)})


HANDLES = ((-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0))


def snap(value, stride):
    return math.floor(value / stride + 0.5) * stride if stride else value


def rotate(point, degrees):
    angle = math.radians(degrees)
    x, y = point
    return x * math.cos(angle) - y * math.sin(angle), x * math.sin(angle) + y * math.cos(angle)

