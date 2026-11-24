"""Project atlas registration and the nine-slice geometry contract."""

import json
from pathlib import Path
import struct
import sys
import zlib

from document import _unique_fields
from objects import DocumentError, TerrainSurface, validate_texture

ATLAS_FOLDER = "assets/terrain"
MARGIN_KEYS = ("left", "top", "right", "bottom")
BUILTIN_ROOT = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))


def project_file(root, relative):
    if root is None:
        raise DocumentError("terrain atlas needs a project folder")
    path = Path(root).resolve(strict=True)
    for part in Path(relative).parts:
        path /= part
        if path.is_symlink() or path.is_junction():
            raise DocumentError(f"linked terrain path: {relative}")
    if not path.is_file():
        raise DocumentError(f"missing terrain file: {relative}")
    return path


def png_size(root, texture):
    validate_texture(texture)
    if not texture.startswith(ATLAS_FOLDER + "/"):
        raise DocumentError("terrain PNG must be under assets/terrain")
    with project_file(root, texture).open("rb") as stream:
        header = stream.read(33)
    if (len(header) != 33 or header[:16] != b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR"
            or zlib.crc32(header[12:29]) != int.from_bytes(header[29:33], "big")):
        raise DocumentError(f"invalid terrain PNG header: {texture}")
    return struct.unpack(">II", header[16:24])


def read_theme(root, theme_id):
    from objects import validate_id

    validate_id(theme_id)
    path = project_file(root, f"{ATLAS_FOLDER}/{theme_id}.json")
    try:
        with path.open("rb") as stream:
            raw = stream.read(8193)
        if len(raw) > 8192:
            raise DocumentError("terrain metadata exceeds 8 KiB")
        data = json.loads(raw, object_pairs_hook=_unique_fields)
        if (data.keys() != {"format", "version", "theme_id", "texture", "source_size", "margins",
                            "edge_mode", "center_mode", "filter"}
                or data["format"] != "rtc_terrain_9slice" or type(data["version"]) is not int
                or data["version"] != 1 or data["theme_id"] != theme_id
                or data["margins"].keys() != set(MARGIN_KEYS)
                or (data["edge_mode"], data["center_mode"], data["filter"]) != ("tile", "tile", "nearest")):
            raise DocumentError("unsupported atlas metadata or duplicate theme ID")
        surface = TerrainSurface(theme_id, data["texture"], data["source_size"],
                                 tuple(data["margins"][side] for side in MARGIN_KEYS))
        if png_size(root, surface.texture_path) != surface.source_size:
            raise DocumentError("terrain atlas dimensions do not match the PNG")
        return surface
    except (AttributeError, ValueError, TypeError, RecursionError) as error:
        raise DocumentError(f"{path.name}: {error}") from error


def atlas_error(root, surface):
    try:
        read_theme(root, surface.theme_id)
        if png_size(root, surface.texture_path) != surface.source_size:
            raise DocumentError("terrain PNG dimension mismatch")
    except (DocumentError, OSError) as error:
        return str(error)
    return ""


def discover_themes(root):
    themes, errors = {}, []
    if root is None:
        return themes, errors
    folder = Path(root) / ATLAS_FOLDER
    if not folder.exists():
        return themes, errors
    for candidate in sorted(folder.glob("*.json")):
        try:
            surface = read_theme(root, candidate.stem)
            themes[surface.theme_id] = surface
        except (DocumentError, OSError) as error:
            errors.append(str(error))
    return themes, errors


def slice_boxes(surface, width, height):
    """Yield source and destination xywh rectangles in row-major order."""
    left, top, right, bottom = surface.margins
    src_w, src_h = surface.source_size
    source_x, source_y = (0, left, src_w - right, src_w), (0, top, src_h - bottom, src_h)
    dest_x, dest_y = (0, left, width - right, width), (0, top, height - bottom, height)
    for row in range(3):
        for col in range(3):
            yield ((source_x[col], source_y[row], source_x[col+1] - source_x[col], source_y[row+1] - source_y[row]),
                   (dest_x[col], dest_y[row], dest_x[col+1] - dest_x[col], dest_y[row+1] - dest_y[row]))
