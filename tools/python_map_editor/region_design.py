"""Offline editing data for the RegionDefinition, marker and settlement link contracts."""

from dataclasses import dataclass
import re

from objects import MAX_GEOMETRY, DocumentError, validate_id, validate_text, validate_vector
from source_region import relative_path

SPAWN_SLOTS = 4
POINT_KINDS = ("ENTRY", "ESCAPE")
MAX_MARKERS = 4096


@dataclass(frozen=True, slots=True)
class RegionPoint:
    id: str
    kind: str
    point_id: str
    position: tuple
    requires_landing: bool = False

    def __post_init__(self):
        validate_id(self.id)
        validate_id(self.point_id)
        if self.kind not in POINT_KINDS or type(self.requires_landing) is not bool:
            raise DocumentError("invalid region point kind or landing flag")
        object.__setattr__(self, "position", validate_vector(self.position, -MAX_GEOMETRY))


@dataclass(frozen=True, slots=True)
class Connection:
    exit_id: str
    region_id: str
    entry_id: str

    def __post_init__(self):
        for value in (self.exit_id, self.region_id, self.entry_id):
            validate_id(value)


@dataclass(frozen=True, slots=True)
class SpawnPoint:
    id: str
    spawn_index: int
    position: tuple

    def __post_init__(self):
        validate_id(self.id)
        if type(self.spawn_index) is not int or not 0 <= self.spawn_index < SPAWN_SLOTS:
            raise DocumentError("spawn_index must be an integer from 0 to 3")
        object.__setattr__(self, "position", validate_vector(self.position, -MAX_GEOMETRY))


@dataclass(frozen=True, slots=True)
class RegionEnvironment:
    path: str = ""
    uid: str = ""
    loading_color: str = "#091a24"

    def __post_init__(self):
        validate_text(self.path, 1024)
        validate_text(self.uid, 32)
        if self.path:
            if not self.path.startswith("res://"):
                raise DocumentError("environment must reference a res:// resource")
            relative = self.path.removeprefix("res://")
            relative_path(relative, ".tres")
            if any(c in relative for c in '*?"<>|') or any(p.endswith((".", " ")) for p in relative.split("/")):
                raise DocumentError("invalid environment path")
        if self.uid and (not self.path or not re.fullmatch(r"uid://[a-z0-9]{1,20}", self.uid)):
            raise DocumentError("environment UID requires a valid resource path and UID")
        if not isinstance(self.loading_color, str) or not re.fullmatch(r"#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?", self.loading_color):
            raise DocumentError("loading color must be #RRGGBB or #RRGGBBAA")
        object.__setattr__(self, "loading_color", self.loading_color.lower())


@dataclass(frozen=True, slots=True)
class RegionDesign:
    region_points: tuple[RegionPoint, ...] = ()
    connections: tuple[Connection, ...] = ()
    spawn_points: tuple[SpawnPoint, ...] = ()
    environment: RegionEnvironment = RegionEnvironment()
    template_ladder: tuple | None = None

    def __post_init__(self):
        for values, cls in ((self.region_points, RegionPoint), (self.connections, Connection),
                            (self.spawn_points, SpawnPoint)):
            if (not isinstance(values, tuple) or len(values) > MAX_MARKERS
                    or not all(isinstance(item, cls) for item in values)):
                raise DocumentError("invalid region design data or count")
        ids = [item.id for item in (*self.region_points, *self.spawn_points)]
        if len(ids) != len(set(ids)):
            raise DocumentError("duplicate stable marker ID")
        if not isinstance(self.environment, RegionEnvironment):
            raise DocumentError("invalid region environment")
        if self.template_ladder is not None:
            object.__setattr__(self, "template_ladder", validate_vector(self.template_ladder, -MAX_GEOMETRY))

    @classmethod
    def from_data(cls, data):
        if not isinstance(data, dict) or data.keys() != cls.__dataclass_fields__.keys():
            raise DocumentError("invalid region design fields")
        fields = {}
        try:
            for name, item_cls in (("region_points", RegionPoint), ("connections", Connection),
                                   ("spawn_points", SpawnPoint)):
                values = data[name]
                if not isinstance(values, list) or len(values) > MAX_MARKERS:
                    raise DocumentError(f"invalid {name} count")
                fields[name] = tuple(item_cls(**row) for row in values)
            return cls(**fields, environment=RegionEnvironment(**data["environment"]),
                       template_ladder=data["template_ladder"])
        except TypeError as error:
            raise DocumentError("invalid region design record") from error
