"""Versioned editing data and atomic draft I/O, independent of Qt and Godot."""

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import tempfile

from objects import DEFAULT_LAYERS, MAX_OBJECTS, DocumentError, MapLayer, MapObject
from region_design import RegionDesign
from source_region import GodotSource

SUFFIX = ".rtcmap"
SCHEMA_VERSION = 6
TERRAIN_VERSION = 5
MAX_FILE_BYTES = 32 * 1024 * 1024
MIN_EXTENT = 64
MAX_EXTENT = 32768


class DocumentConflict(DocumentError):
    pass


@dataclass(frozen=True)
class MapDocument:
    region_id: str = "new_region"
    display_name: str = ""
    width: int = 1600
    height: int = 900
    layers: tuple[MapLayer, ...] = DEFAULT_LAYERS
    objects: tuple[MapObject, ...] = ()
    source: GodotSource | None = None
    design: RegionDesign | None = None

    def __post_init__(self):
        if (not isinstance(self.region_id, str) or len(self.region_id) > 64
                or not re.fullmatch(r"[a-z][a-z0-9]*(?:_[a-z0-9]+)*", self.region_id)):
            raise DocumentError("region_id must be snake_case ASCII (1–64 characters)")
        if (not isinstance(self.display_name, str) or len(self.display_name) > 120
                or any(ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF for char in self.display_name)):
            raise DocumentError("display_name must be a single line of at most 120 characters")
        if any(type(value) is not int or not MIN_EXTENT <= value <= MAX_EXTENT
               for value in (self.width, self.height)):
            raise DocumentError(f"map extents must be integers between {MIN_EXTENT} and {MAX_EXTENT}")

        if (not isinstance(self.layers, tuple) or not 1 <= len(self.layers) <= 128
                or not all(isinstance(layer, MapLayer) for layer in self.layers)):
            raise DocumentError("invalid layers")
        layer_ids = {layer.id for layer in self.layers}
        if len(layer_ids) != len(self.layers):
            raise DocumentError("duplicate layer ID")
        if (not isinstance(self.objects, tuple) or len(self.objects) > MAX_OBJECTS
                or not all(isinstance(item, MapObject) for item in self.objects)):
            raise DocumentError("invalid objects or object count")
        if len({item.id for item in self.objects}) != len(self.objects):
            raise DocumentError("duplicate object ID")
        if any(item.layer_id not in layer_ids for item in self.objects):
            raise DocumentError("object references an unknown layer")
        if self.source is not None and not isinstance(self.source, GodotSource):
            raise DocumentError("invalid Godot source")
        if self.design is not None and not isinstance(self.design, RegionDesign):
            raise DocumentError("invalid region design")


def encode(document):
    data = {"schema_version": 2, **asdict(document)}
    data["objects"] = [item.to_data() for item in document.objects]
    if document.design is not None:
        data["schema_version"] = 4
    else:
        del data["design"]
        if document.source is not None:
            data["schema_version"] = 3
        else:
            del data["source"]
    if any(item.properties.terrain is not None for item in document.objects):
        data.update(schema_version=TERRAIN_VERSION, source=data.get("source"), design=data.get("design"))
    if document.design is not None:
        if document.design.enemy_spawns is None:
            # A draft that does not manage enemy spawns keeps its earlier schema byte for byte.
            del data["design"]["enemy_spawns"]
        else:
            data.update(schema_version=SCHEMA_VERSION, source=data.get("source"))
    payload = (json.dumps(data, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode("utf-8")
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("draft exceeds the schema's size limit")
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


def decode(payload):
    document, _ = _decode_versioned(payload)
    return document


def _decode_versioned(payload):
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("draft exceeds the schema's size limit")
    try:
        data = json.loads(payload.decode("utf-8"), object_pairs_hook=_unique_fields,
                          parse_constant=_invalid_constant)
    except (UnicodeError, ValueError, RecursionError) as error:
        raise DocumentError("invalid UTF-8 JSON draft") from error
    if not isinstance(data, dict) or type(data.get("schema_version")) is not int:
        raise DocumentError("missing or invalid schema_version")
    version = data.pop("schema_version")
    if version not in _MIGRATIONS:
        raise DocumentError("unsupported draft version")
    document = MapDocument(**_MIGRATIONS[version](data))
    if version < 5 and any(item.properties.terrain is not None for item in document.objects):
        raise DocumentError("terrain surfaces require Schema V5")
    if version == 6 and (document.design is None or document.design.enemy_spawns is None):
        raise DocumentError("Schema V6 requires an enemy spawn list")
    return document, version


_REGION_FIELDS = {"region_id", "display_name", "width", "height"}
_V2_FIELDS = _REGION_FIELDS | {"layers", "objects"}


def _migrate_v1(data):
    if data.keys() != _REGION_FIELDS:
        raise DocumentError("unrecognized or missing V1 draft fields")
    return data


def _migrate_v2(data):
    if data.keys() != _V2_FIELDS:
        raise DocumentError("unrecognized or missing V2 draft fields")
    layers, objects = data["layers"], data["objects"]
    if (not isinstance(layers, list) or not 1 <= len(layers) <= 128
            or not isinstance(objects, list) or len(objects) > MAX_OBJECTS):
        raise DocumentError("invalid layer or object count")
    try:
        data["layers"] = tuple(MapLayer(**layer) for layer in layers)
        data["objects"] = tuple(MapObject.from_data(item) for item in objects)
    except TypeError as error:
        raise DocumentError("invalid layer or object fields") from error
    return data


def _migrate_v3(data):
    if data.keys() != _V2_FIELDS | {"source"}:
        raise DocumentError("unrecognized or missing V3 draft fields")
    source = GodotSource.from_data(data.pop("source"))
    return {**_migrate_v2(data), "source": source}


def _decode_v4(data, *, allow_draft=False, enemy_spawns=False):
    if data.keys() != _V2_FIELDS | {"source", "design"}:
        raise DocumentError("unrecognized or missing V4 draft fields")
    design_data = data.pop("design")
    design = (None if allow_draft and design_data is None
              else RegionDesign.from_data(design_data, enemy_spawns=enemy_spawns))
    source = data.pop("source")
    return {**_migrate_v2(data), "design": design,
            "source": GodotSource.from_data(source) if source is not None else None}


def _decode_v5(data):
    return _decode_v4(data, allow_draft=True)


def _decode_v6(data):
    return _decode_v4(data, allow_draft=True, enemy_spawns=True)


_MIGRATIONS = {1: _migrate_v1, 2: _migrate_v2, 3: _migrate_v3, 4: _decode_v4, 5: _decode_v5, 6: _decode_v6}


def _draft_path(path):
    path = path.absolute()
    if path.suffix.lower() != SUFFIX:
        raise DocumentError("choose a regular .rtcmap file")
    for parent in path.parents:
        if parent.is_symlink() or parent.is_junction():
            raise DocumentError("draft directory must not be a symbolic link or junction")
    _file_state(path)
    return path


def _file_state(path):
    try:
        state = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(state.st_mode) or (
            getattr(state, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise DocumentError("choose a regular file without symbolic links or reparse points")
    return state


@contextmanager
def _save_lock(path):
    # Keep a stable sidecar so concurrent processes always lock the same file,
    # even across replacement of the document. Closing the handle releases it.
    sidecar = path.with_name(f".{path.name}.lock")
    _file_state(sidecar)
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
    with os.fdopen(os.open(sidecar, flags, 0o600), "r+b") as stream:
        if _file_state(sidecar) is None or not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise DocumentError("invalid document lock file")
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
                raise DocumentConflict("another editor is saving this file") from error
            raise
        yield


def _read(path):
    with path.open("rb") as stream:
        payload = stream.read(MAX_FILE_BYTES + 1)
    if len(payload) > MAX_FILE_BYTES:
        raise DocumentError("draft exceeds the schema's size limit")
    return payload


def read_document(path):
    document, revision, _ = read_document_snapshot(path)
    return document, revision


def read_document_snapshot(path):
    """Return the validated draft, exact byte revision and on-disk schema version."""
    payload = _read(_draft_path(path))
    document, version = _decode_versioned(payload)
    return document, hashlib.sha256(payload).hexdigest(), version


def document_revision(path):
    """Snapshot existing bytes before showing an overwrite confirmation."""
    try:
        return hashlib.sha256(_read(_draft_path(path))).hexdigest()
    except FileNotFoundError:
        return None


def write_document(path, document, expected_hash=None):
    """Publish a new file exclusively or replace the previously opened revision."""
    path = _draft_path(path)
    payload = encode(document)
    with _save_lock(path):
        _publish_document(path, payload, expected_hash)
    return hashlib.sha256(payload).hexdigest()


def _publish_document(path, payload, expected_hash):
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".rtcmap-", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
            stream.close()
            if expected_hash is None:
                try:
                    if os.name == "nt":
                        temporary.rename(path)  # Windows rename fails if the target exists.
                    else:
                        os.link(temporary, path)
                except FileExistsError as error:
                    raise DocumentConflict("a file already exists at this location") from error
            else:
                state = _file_state(_draft_path(path))
                if state is not None and not state.st_mode & (stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH):
                    raise PermissionError(f"document is read-only: {path}")
                actual_hash = document_revision(path)
                if actual_hash != expected_hash:
                    raise DocumentConflict("the file changed on disk")
                os.replace(temporary, path)
        finally:
            stream.close()
            temporary.unlink(missing_ok=True)
