"""PNG checks without an image library.

Four levels exist for an image asset; this module does the middle two.

    1 path       project.resolve_project_file   inside the project, regular file, size limit
    2 header     read_header                    signature, IHDR, dimensions, colour format
    3 integrity  verify                         chunk layout, every CRC, the zlib stream, the number of
                                                scanlines and their filter types
    4 import     Godot                          a Texture2D really loads - only a Godot run can say

Level 3 walks the container and inflates the pixel stream to count and check
the scanlines. It does not reconstruct pixels: there is no decoder here, only
the structural checks the standard library makes possible (``zlib``). That is
enough to reject truncated files, damaged or missing IDAT data, CRC errors and
streams of the wrong length, which a header check lets through.

The inflated stream is consumed in bounded pieces and never held whole, so a
small file that expands enormously ("decompression bomb") stops at the size
the header promised.
"""

from dataclasses import dataclass
import struct
import zlib

SIGNATURE = b"\x89PNG\r\n\x1a\n"
CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}
BIT_DEPTHS = {0: (1, 2, 4, 8, 16), 2: (8, 16), 3: (1, 2, 4, 8), 4: (8, 16), 6: (8, 16)}
ADAM7 = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
INFLATE_PIECE = 1 << 20

HEADER, INTEGRITY = "header", "integrity"


class PngError(ValueError):
    """``level`` is HEADER (not a usable PNG at all) or INTEGRITY (the header is fine, the data is not)."""

    def __init__(self, level, message):
        super().__init__(message)
        self.level = level


@dataclass(frozen=True)
class PngInfo:
    width: int
    height: int
    bit_depth: int
    color_type: int
    interlaced: bool

    @property
    def has_alpha(self):
        return self.color_type in (4, 6)

    @property
    def row_bytes(self):
        return (self.width * CHANNELS[self.color_type] * self.bit_depth + 7) // 8


def read_header(payload, maximum_extent):
    """Level 2. ``payload`` is the file's bytes (or at least its first 33)."""
    if len(payload) < 33 or payload[:8] != SIGNATURE or payload[12:16] != b"IHDR" \
            or struct.unpack(">I", payload[8:12])[0] != 13:
        raise PngError(HEADER, "not a PNG image")
    width, height, depth, color, compression, filtering, interlace = struct.unpack(">IIBBBBB", payload[16:29])
    if not 0 < width <= maximum_extent or not 0 < height <= maximum_extent:
        raise PngError(HEADER, f"image is {width}x{height}; the limit is {maximum_extent}")
    if color not in CHANNELS or depth not in BIT_DEPTHS[color] or compression or filtering or interlace > 1:
        raise PngError(HEADER, "unsupported or invalid PNG format fields")
    return PngInfo(width, height, depth, color, bool(interlace))


def _expected_rows(info):
    """``[(row_length_including_filter_byte, row_count), ...]`` for every pass of the image."""
    if not info.interlaced:
        return [(1 + info.row_bytes, info.height)]
    bits = CHANNELS[info.color_type] * info.bit_depth
    passes = []
    for x0, y0, dx, dy in ADAM7:
        width = (info.width - x0 + dx - 1) // dx
        height = (info.height - y0 + dy - 1) // dy
        if width > 0 and height > 0:
            passes.append((1 + (width * bits + 7) // 8, height))
    return passes


def verify(payload, info):
    """Level 3. Raises PngError(INTEGRITY) when the data does not match what the header promises."""
    position, seen_idat, idat_closed, seen_plte, ended = 8, False, False, False, False
    inflater = zlib.decompressobj()
    layout = _expected_rows(info)
    expected = sum(length * rows for length, rows in layout)
    produced = 0
    pass_index, in_row, rows_left = 0, 0, layout[0][1]

    def consume(data):
        nonlocal produced, pass_index, in_row, rows_left
        produced += len(data)
        if produced > expected:
            raise PngError(INTEGRITY, "pixel data is longer than the image size allows")
        offset = 0
        while offset < len(data):
            length = layout[pass_index][0]
            if in_row == 0 and data[offset] > 4:
                raise PngError(INTEGRITY, f"invalid scanline filter type {data[offset]}")
            step = min(length - in_row, len(data) - offset)
            in_row += step
            offset += step
            if in_row == length:
                in_row, rows_left = 0, rows_left - 1
                if rows_left == 0 and pass_index + 1 < len(layout):
                    pass_index += 1
                    rows_left = layout[pass_index][1]

    while position < len(payload):
        if ended:
            raise PngError(INTEGRITY, "data after the IEND chunk")
        if position + 12 > len(payload):
            raise PngError(INTEGRITY, "truncated chunk")
        length, kind = struct.unpack(">I", payload[position:position + 4])[0], payload[position + 4:position + 8]
        end = position + 12 + length
        if end > len(payload):
            raise PngError(INTEGRITY, f"truncated {kind.decode('latin-1')} chunk")
        body = payload[position + 8:position + 8 + length]
        if zlib.crc32(kind + body) != struct.unpack(">I", payload[end - 4:end])[0]:
            raise PngError(INTEGRITY, f"CRC error in the {kind.decode('latin-1')} chunk")
        if kind == b"IDAT":
            if idat_closed:
                raise PngError(INTEGRITY, "IDAT chunks are not consecutive")
            seen_idat = True
            try:
                data = inflater.decompress(body, INFLATE_PIECE)
                consume(data)
                while inflater.unconsumed_tail:
                    consume(inflater.decompress(inflater.unconsumed_tail, INFLATE_PIECE))
            except zlib.error as error:
                raise PngError(INTEGRITY, f"corrupt pixel data: {error}") from error
        else:
            if seen_idat:
                idat_closed = True
            if kind == b"PLTE":
                seen_plte = True
            elif kind == b"IEND":
                ended = True
            elif position != 8 and kind == b"IHDR":
                raise PngError(INTEGRITY, "more than one IHDR chunk")
        position = end
    if not ended:
        raise PngError(INTEGRITY, "the IEND chunk is missing")
    if not seen_idat:
        raise PngError(INTEGRITY, "the image has no pixel data (no IDAT chunk)")
    if info.color_type == 3 and not seen_plte:
        raise PngError(INTEGRITY, "an indexed image has no palette")
    if not inflater.eof:
        raise PngError(INTEGRITY, "the pixel data stream ends early")
    if produced != expected:
        raise PngError(INTEGRITY, f"pixel data has {produced} bytes; the image size needs {expected}")
