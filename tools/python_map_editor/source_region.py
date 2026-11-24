"""Version 3 Godot source bindings. These values are evidence, not edit commands."""

from dataclasses import dataclass
from pathlib import PurePosixPath
import re

from objects import DocumentError, validate_id, validate_number, validate_text


def relative_path(value, suffix):
    validate_text(value, 1024)
    if (not value or not value.endswith(suffix) or "\\" in value or ":" in value
            or any(part in ("", ".", "..") for part in value.split("/"))):
        raise DocumentError(f"expected a project-relative {suffix} path")
    return PurePosixPath(value).as_posix()


def sha256_text(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise DocumentError("invalid SHA-256 digest")
    return value


def node_path(value):
    validate_text(value, 2048)
    if value != "." and (":" in value or "\\" in value
                         or any(part in ("", "..", ".") for part in value.split("/"))):
        raise DocumentError("invalid relative Godot node path")


@dataclass(frozen=True, slots=True)
class NodeBinding:
    id: str
    path: str
    parent: str
    local_transform: tuple
    world_transform: tuple
    collision_layer: int | None = None
    collision_mask: int | None = None

    def __post_init__(self):
        validate_id(self.id)
        node_path(self.path)
        node_path(self.parent)
        if not self.path or not self.parent or self.path == "." or self.parent != (self.path.rpartition("/")[0] or "."):
            raise DocumentError("invalid owner path for bound node")
        for key in ("local_transform", "world_transform"):
            values = getattr(self, key)
            if not isinstance(values, (list, tuple)) or len(values) != 6:
                raise DocumentError("expected the six components of Transform2D")
            for value in values:
                validate_number(value, -1e20, 1e20)
            object.__setattr__(self, key, tuple(values))
        collision = (self.collision_layer, self.collision_mask)
        if collision != (None, None) and any(type(value) is not int or not 0 <= value < 2**32
                                              for value in collision):
            raise DocumentError("invalid collision metadata")

    def as_bridge_data(self):
        collision = ({} if self.collision_layer is None else
                     {"layer": self.collision_layer, "mask": self.collision_mask})
        return {"path": self.path, "parent": self.parent, "local_transform": self.local_transform,
                "world_transform": self.world_transform, "collision": collision}


@dataclass(frozen=True, slots=True)
class GodotSource:
    project_id: str
    fingerprint: str
    scene_path: str
    region_path: str
    scene_hash: str
    region_hash: str
    scene_uid: str
    region_uid: str
    bindings: tuple[NodeBinding, ...]

    def __post_init__(self):
        for digest in (self.project_id, self.fingerprint, self.scene_hash, self.region_hash):
            sha256_text(digest)
        relative_path(self.scene_path, ".tscn")
        relative_path(self.region_path, ".tres")
        if not self.region_path.startswith("data/content/"):
            raise DocumentError("expected a registered RegionDefinition path")
        for uid in (self.scene_uid, self.region_uid):
            if uid != "" and (not isinstance(uid, str) or not re.fullmatch(r"uid://[a-z0-9]{1,20}", uid)):
                raise DocumentError("invalid Godot UID")
        if (not isinstance(self.bindings, tuple) or len(self.bindings) > 50000
                or not all(isinstance(item, NodeBinding) for item in self.bindings)
                or len({item.id for item in self.bindings}) != len(self.bindings)
                or len({item.path for item in self.bindings}) != len(self.bindings)):
            raise DocumentError("invalid or duplicate source bindings")

    @classmethod
    def from_data(cls, data):
        if (not isinstance(data, dict) or data.keys() != cls.__dataclass_fields__.keys()
                or not isinstance(data["bindings"], list) or len(data["bindings"]) > 50000):
            raise DocumentError("invalid Godot source data")
        try:
            return cls(**{**data, "bindings": tuple(NodeBinding(**item) for item in data["bindings"])})
        except TypeError as error:
            raise DocumentError("invalid Godot node binding") from error
