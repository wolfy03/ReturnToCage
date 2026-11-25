"""Coordinate contract between the editor canvas and the Godot actor.

All stored geometry is **actor-local**: pixels, +X right, +Y down, origin at
the CharacterBody2D origin, authored for an actor that faces right. Zoom and
canvas position never reach a document.

Three spaces are involved:

* frame space   – pixel inside one sprite frame, origin at its top-left corner
* visual space  – the AnimatedSprite2D inside EnemyAnimationPresenter: the frame
                  is centred, then moved by ``visual_offset`` (plus the frame's
                  own ``offset``)
* actor space   – the presenter scales visual space by ``visual_scale`` and
                  mirrors X when the actor faces away from the art's direction

Collision never uses ``visual_scale``: shapes are already actor-local pixels.

Shapes are dispatched through ``SHAPES``. A new shape type is one entry there
(its bounds and its Godot values) plus its fields in ``schema.SHAPE``; no
caller has an ``if type == ...`` to extend.
"""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class ShapeKind:
    godot_class: str
    half_extents: object   # callable(shape) -> (half_width, half_height)
    godot_fields: object   # callable(shape) -> dict of Shape2D resource fields


SHAPES = {
    "rectangle": ShapeKind("RectangleShape2D",
                           lambda shape: (shape["size"][0] / 2, shape["size"][1] / 2),
                           # RectangleShape2D.size is the full extent, centred on the CollisionShape2D position.
                           lambda shape: {"size": list(shape["size"])}),
    "circle": ShapeKind("CircleShape2D",
                        lambda shape: (shape["radius"], shape["radius"]),
                        lambda shape: {"radius": shape["radius"]}),
}


def _kind(shape):
    try:
        return SHAPES[shape["type"]]
    except (KeyError, TypeError) as error:
        raise ValueError(f"unsupported collision shape: {shape!r}") from error


def _finite(values, what):
    for value in values:
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"{what} must be finite numbers, got {list(values)!r}")
    return values


def facing_sign(facing):
    _finite([facing], "facing")
    return -1 if facing < 0 else 1


def mirror_point(point, facing):
    """Mirror an authored (facing-right) actor-local point for the given facing. Y never changes."""
    return [point[0] * facing_sign(facing), point[1]]


def mirror_shape(shape, facing):
    """A shape keeps its size; only the centre's X is mirrored."""
    _kind(shape)
    return {**shape, "center": mirror_point(shape["center"], facing)}


def shape_bounds(shape):
    """``(left, top, right, bottom)`` in actor space."""
    half_w, half_h = _kind(shape).half_extents(shape)
    x, y = _finite(shape["center"], "shape center")
    return (x - half_w, y - half_h, x + half_w, y + half_h)


def to_godot_shape(shape, facing=1):
    """Values for a CollisionShape2D: its ``position`` and the Shape2D resource fields."""
    kind = _kind(shape)
    return {"shape_class": kind.godot_class, "position": mirror_point(shape["center"], facing),
            **kind.godot_fields(shape)}


def _visual(presentation, facing):
    """``(scale_x signed by facing, scale_y, offset_x, offset_y)`` after checking they are usable."""
    scale = _finite(presentation["visual_scale"], "visual_scale")
    if scale[0] <= 0 or scale[1] <= 0:
        raise ValueError(f"visual_scale components must be positive, got {list(scale)!r}")
    offset = _finite(presentation["visual_offset"], "visual_offset")
    direction = facing_sign(facing)
    if not presentation["faces_right_by_default"]:
        direction = -direction
    return scale[0] * direction, scale[1], offset[0], offset[1]


def sprite_to_actor(point, frame_size, presentation, facing=1, frame_offset=(0, 0)):
    """Frame-space pixel -> actor-local point for an actor with the given facing."""
    scale_x, scale_y, offset_x, offset_y = _visual(presentation, facing)
    _finite(tuple(point) + tuple(frame_size) + tuple(frame_offset), "sprite coordinates")
    return [(point[0] - frame_size[0] / 2 + offset_x + frame_offset[0]) * scale_x,
            (point[1] - frame_size[1] / 2 + offset_y + frame_offset[1]) * scale_y]


def actor_to_sprite(point, frame_size, presentation, facing=1, frame_offset=(0, 0)):
    """Inverse of :func:`sprite_to_actor`."""
    scale_x, scale_y, offset_x, offset_y = _visual(presentation, facing)
    _finite(tuple(point) + tuple(frame_size) + tuple(frame_offset), "actor coordinates")
    return [point[0] / scale_x + frame_size[0] / 2 - offset_x - frame_offset[0],
            point[1] / scale_y + frame_size[1] / 2 - offset_y - frame_offset[1]]


def bottom_center_offset(frame_size, visual_scale, body_shape, foot_margin=0):
    """``visual_offset`` that puts the frame's bottom-centre on the bottom of the body shape.

    A convenience for art drawn with a bottom-centre anchor. It only proposes a
    presentation value; the actor origin and the body shape are left alone.
    ``foot_margin`` is the empty rows below the feet inside the frame.
    """
    _finite(visual_scale, "visual_scale")
    if visual_scale[1] <= 0:
        raise ValueError(f"visual_scale components must be positive, got {list(visual_scale)!r}")
    bottom = shape_bounds(body_shape)[3]
    return [0, bottom / visual_scale[1] - frame_size[1] / 2 + foot_margin]


def slice_grid(image_id, frame_width, frame_height, columns, rows=1, count=None, origin=(0, 0), spacing=(0, 0)):
    """Row-major frames of a sprite sheet. Returns frame objects for a clip's ``frames`` list."""
    if min(frame_width, frame_height, columns, rows) < 1:
        raise ValueError("frame size and grid counts must be positive")
    if min(origin[0], origin[1], spacing[0], spacing[1]) < 0:
        raise ValueError("origin and spacing must not be negative")
    total = columns * rows if count is None else count
    if not 0 < total <= columns * rows:
        raise ValueError("count must fit inside the grid")
    return [{"image": image_id,
             "rect": [origin[0] + (index % columns) * (frame_width + spacing[0]),
                      origin[1] + (index // columns) * (frame_height + spacing[1]), frame_width, frame_height],
             "duration": 1, "offset": [0, 0]}
            for index in range(total)]
