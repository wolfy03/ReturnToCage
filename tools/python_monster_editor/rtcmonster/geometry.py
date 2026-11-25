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
"""


def facing_sign(facing):
    return -1 if facing < 0 else 1


def mirror_point(point, facing):
    """Mirror an authored (facing-right) actor-local point for the given facing. Y never changes."""
    return [point[0] * facing_sign(facing), point[1]]


def mirror_shape(shape, facing):
    """A rectangle or circle keeps its size; only the centre's X is mirrored."""
    return {**shape, "center": mirror_point(shape["center"], facing)}


def shape_bounds(shape):
    """``(left, top, right, bottom)`` in actor space."""
    x, y = shape["center"]
    if shape["type"] == "circle":
        half_w = half_h = shape["radius"]
    else:
        half_w, half_h = shape["size"][0] / 2, shape["size"][1] / 2
    return (x - half_w, y - half_h, x + half_w, y + half_h)


def to_godot_shape(shape, facing=1):
    """Values for a CollisionShape2D: its ``position`` and the Shape2D resource fields."""
    position = mirror_point(shape["center"], facing)
    if shape["type"] == "circle":
        return {"shape_class": "CircleShape2D", "position": position, "radius": shape["radius"]}
    # RectangleShape2D.size is the full extent, centred on the CollisionShape2D position.
    return {"shape_class": "RectangleShape2D", "position": position, "size": list(shape["size"])}


def _visual_direction(presentation, facing):
    direction = facing_sign(facing)
    return direction if presentation["faces_right_by_default"] else -direction


def sprite_to_actor(point, frame_size, presentation, facing=1, frame_offset=(0, 0)):
    """Frame-space pixel -> actor-local point for an actor with the given facing."""
    scale_x, scale_y = presentation["visual_scale"]
    offset_x, offset_y = presentation["visual_offset"]
    visual_x = point[0] - frame_size[0] / 2 + offset_x + frame_offset[0]
    visual_y = point[1] - frame_size[1] / 2 + offset_y + frame_offset[1]
    return [visual_x * scale_x * _visual_direction(presentation, facing), visual_y * scale_y]


def actor_to_sprite(point, frame_size, presentation, facing=1, frame_offset=(0, 0)):
    """Inverse of :func:`sprite_to_actor`."""
    scale_x, scale_y = presentation["visual_scale"]
    offset_x, offset_y = presentation["visual_offset"]
    visual_x = point[0] / (scale_x * _visual_direction(presentation, facing))
    visual_y = point[1] / scale_y
    return [visual_x + frame_size[0] / 2 - offset_x - frame_offset[0],
            visual_y + frame_size[1] / 2 - offset_y - frame_offset[1]]


def bottom_center_offset(frame_size, visual_scale, body_shape, foot_margin=0):
    """``visual_offset`` that puts the frame's bottom-centre on the bottom of the body shape.

    A convenience for art drawn with a bottom-centre anchor. It only proposes a
    presentation value; the actor origin and the body shape are left alone.
    ``foot_margin`` is the empty rows below the feet inside the frame.
    """
    bottom = shape_bounds(body_shape)[3]
    return [0, bottom / visual_scale[1] - frame_size[1] / 2 + foot_margin]


def slice_grid(image_id, frame_width, frame_height, columns, rows=1, count=None, origin=(0, 0), spacing=(0, 0)):
    """Row-major frames of a sprite sheet. Returns frame objects for a clip's ``frames`` list."""
    if min(frame_width, frame_height, columns, rows) < 1:
        raise ValueError("frame size and grid counts must be positive")
    total = columns * rows if count is None else count
    if not 0 < total <= columns * rows:
        raise ValueError("count must fit inside the grid")
    return [{"image": image_id,
             "rect": [origin[0] + (index % columns) * (frame_width + spacing[0]),
                      origin[1] + (index // columns) * (frame_height + spacing[1]), frame_width, frame_height],
             "duration": 1, "offset": [0, 0]}
            for index in range(total)]
