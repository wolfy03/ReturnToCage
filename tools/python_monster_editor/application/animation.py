"""Image, clip, presentation and collision editing for MONSTER-STEP 3. No Qt.

Every function here reads a document's frozen data and returns the edits that
make one user action. Nothing is applied here: the caller hands the edits to
``DocumentSession.apply`` so one action is one undo step. Geometry and time
come from ``rtcmonster.geometry`` and ``rtcmonster.timing``; this module adds
no formula of its own.
"""

from rtcmonster import DocumentError, insert_item, inspect_image, remove_item, set_value
from rtcmonster.geometry import bottom_center_offset, shape_bounds, slice_grid
from rtcmonster.schema import ROLES

IMAGES = ("assets", "images")
CLIPS = ("animations", "clips")
ROLE_PATH = ("presentation", "roles")
HURTBOXES = ("collision", "hurtboxes")
HITBOXES = ("collision", "hitboxes")
OVERRIDES = ("collision", "hurtbox_overrides")
BODY = ("collision", "body", "shape")
SHAPE_KINDS = ("rectangle", "circle")
MINIMUM_EXTENT = 1.0
HANDLES = ("left", "top", "right", "bottom")


# ----------------------------------------------------------------------------------------------------- ids
def unique_id(base, taken):
    """``base``, or ``base_2``, ``base_3`` ... : the first one not in ``taken``."""
    taken = set(taken)
    if base not in taken:
        return base
    index = 2
    while f"{base}_{index}" in taken:
        index += 1
    return f"{base}_{index}"


def id_from_path(relative):
    """A document ID suggested by a file name: lower case, ``[a-z0-9_]``, starting with a letter."""
    stem = relative.replace("\\", "/").rsplit("/", 1)[-1].rsplit(".", 1)[0].lower()
    cleaned = "".join(character if character.isascii() and (character.isalnum() or character == "_") else "_"
                      for character in stem).strip("_")
    if not cleaned or not cleaned[0].isalpha():
        cleaned = "image_" + cleaned if cleaned else "image"
    return cleaned[:64]


def _rows(data, path):
    return data[path[0]][path[1]]


def _index(data, path, row_id):
    for index, row in enumerate(_rows(data, path)):
        if row["id"] == row_id:
            return index
    raise DocumentError(f"no {path[-1][:-1]} named {row_id!r}")


def image_index(data, image_id):
    return _index(data, IMAGES, image_id)


def clip_index(data, clip_id):
    return _index(data, CLIPS, clip_id)


# -------------------------------------------------------------------------------------------------- images
def register_image(data, project_root, relative, image_id=None):
    """``(image_id, edits)`` that register a project PNG with its measured size and content hash.

    The file is read through the core's path, header and integrity checks, so a
    file that is missing, outside the project or not a sound PNG is refused
    here (FileNotFoundError, DocumentError or png.PngError) and nothing is added.
    """
    relative = relative.replace("\\", "/")
    if any(row["path"] == relative for row in _rows(data, IMAGES)):
        raise DocumentError(f"{relative} is already registered")
    width, height, digest = inspect_image(project_root, relative)
    image_id = image_id or unique_id(id_from_path(relative), (row["id"] for row in _rows(data, IMAGES)))
    return image_id, [insert_item(IMAGES, {"id": image_id, "path": relative, "width": width, "height": height,
                                           "sha256": digest})]


def refresh_image(data, project_root, image_id):
    """Edits that record the file's current size and hash. Empty when the record is already current."""
    index = image_index(data, image_id)
    row = _rows(data, IMAGES)[index]
    width, height, digest = inspect_image(project_root, row["path"])
    return [set_value(IMAGES + (index, key), value)
            for key, value in (("width", width), ("height", height), ("sha256", digest)) if row[key] != value]


def image_users(data, image_id):
    """IDs of the clips that draw from an image."""
    return [clip["id"] for clip in _rows(data, CLIPS) if any(frame["image"] == image_id for frame in clip["frames"])]


def remove_image(data, image_id):
    """Edits that drop an unused image. An image a clip still draws from is not removed."""
    users = image_users(data, image_id)
    if users:
        raise DocumentError(f"image {image_id!r} is used by clip {', '.join(users)}")
    return [remove_item(IMAGES + (image_index(data, image_id),))]


# --------------------------------------------------------------------------------------------------- clips
def _new_clip(clip_id, frames, fps, loop):
    return {"id": clip_id, "fps": fps, "loop": loop, "frames": frames}


def clip_from_grid(data, image_id, clip_id, columns, rows=1, count=None, fps=10, loop=False):
    """Edits that add a clip whose frames are a row-major grid over one registered image.

    The frame size is the image size divided by the grid, and it must divide
    exactly: a sheet that does not is refused instead of being cut with a remainder.
    """
    image = _rows(data, IMAGES)[image_index(data, image_id)]
    if columns < 1 or rows < 1:
        raise DocumentError("grid counts must be at least 1")
    if image["width"] % columns or image["height"] % rows:
        raise DocumentError(f"{image['width']}x{image['height']} does not divide into {columns}x{rows} equal frames")
    if any(clip["id"] == clip_id for clip in _rows(data, CLIPS)):
        raise DocumentError(f"clip {clip_id!r} already exists")
    try:
        frames = slice_grid(image_id, image["width"] // columns, image["height"] // rows, columns, rows, count)
    except ValueError as error:
        raise DocumentError(str(error)) from error
    return [insert_item(CLIPS, _new_clip(clip_id, frames, fps, loop))]


def clip_from_images(data, clip_id, image_ids, fps=10, loop=False):
    """Edits that add a clip with one whole-image frame per listed image, in order."""
    if not image_ids:
        raise DocumentError("a clip needs at least one image")
    for image_id in image_ids:
        image_index(data, image_id)
    if any(clip["id"] == clip_id for clip in _rows(data, CLIPS)):
        raise DocumentError(f"clip {clip_id!r} already exists")
    frames = [{"image": image_id, "rect": None, "duration": 1, "offset": [0, 0]} for image_id in image_ids]
    return [insert_item(CLIPS, _new_clip(clip_id, frames, fps, loop))]


def clip_roles(data, clip_id):
    """Roles currently bound to a clip."""
    roles = data["presentation"]["roles"]
    return [role for role in ROLES if roles[role] == clip_id]


def remove_clip(data, clip_id):
    """Edits that remove a clip together with what points at it: its role bindings and hurtbox overrides.

    Overrides are removed from the last one backwards so each index is still valid when its edit runs.
    """
    edits = [set_value(ROLE_PATH + (role,), "") for role in clip_roles(data, clip_id)]
    overrides = [index for index, row in enumerate(_rows(data, OVERRIDES)) if row["clip"] == clip_id]
    edits += [remove_item(OVERRIDES + (index,)) for index in reversed(overrides)]
    return edits + [remove_item(CLIPS + (clip_index(data, clip_id),))]


def remove_frame(data, clip_id, frame):
    """Edits that remove one frame and keep the frame overrides pointing at the frames they were made for.

    The removed frame's own override goes with it, and overrides of later frames move down by one.
    """
    position = clip_index(data, clip_id)
    clip = _rows(data, CLIPS)[position]
    if not 0 <= frame < len(clip["frames"]):
        raise DocumentError(f"clip {clip_id!r} has no frame {frame}")
    edits = []
    own = override_index(data, clip_id, frame)
    if own is not None:
        edits.append(remove_item(OVERRIDES + (own,)))
    later = sorted((row["frame"], index) for index, row in enumerate(_rows(data, OVERRIDES))
                   if row["clip"] == clip_id and row["frame"] is not None and row["frame"] > frame)
    for number, index in later:
        # Lower frames first, so no two overrides ever share a frame; indexes follow the removal above.
        index -= 1 if own is not None and index > own else 0
        edits.append(set_value(OVERRIDES + (index, "frame"), number - 1))
    return edits + [remove_item(CLIPS + (position, "frames", frame))]


def frame_size(data, clip, index):
    """``(width, height)`` in pixels of one frame, or None when its image is not registered."""
    frame = clip["frames"][index]
    if frame["rect"] is not None:
        return frame["rect"][2], frame["rect"][3]
    for image in _rows(data, IMAGES):
        if image["id"] == frame["image"]:
            return image["width"], image["height"]
    return None


def frame_source(data, clip, index):
    """``(project-relative path, rect or None)`` to draw one frame from, or ``("", None)``."""
    frame = clip["frames"][index]
    for image in _rows(data, IMAGES):
        if image["id"] == frame["image"]:
            return image["path"], (list(frame["rect"]) if frame["rect"] is not None else None)
    return "", None


# -------------------------------------------------------------------------------------------- presentation
def bind_role(data, role, clip_id):
    """Edits that bind a role to a clip, or unbind it with ``""``."""
    if role not in ROLES:
        raise DocumentError(f"unknown role {role!r}")
    if clip_id:
        clip_index(data, clip_id)
    return [set_value(ROLE_PATH + (role,), clip_id)]


def bottom_center_edits(data, clip_id, foot_margin=0):
    """Edits that put the bottom-centre of a clip's first frame on the bottom of the body shape."""
    clip = _rows(data, CLIPS)[clip_index(data, clip_id)]
    if not clip["frames"]:
        raise DocumentError(f"clip {clip_id!r} has no frames")
    size = frame_size(data, clip, 0)
    if size is None:
        raise DocumentError(f"the first frame of {clip_id!r} uses an unregistered image")
    try:
        offset = bottom_center_offset(size, data["presentation"]["visual_scale"], data["collision"]["body"]["shape"],
                                      foot_margin)
    except ValueError as error:
        raise DocumentError(str(error)) from error
    return [set_value(("presentation", "visual_offset"), offset)]


# --------------------------------------------------------------------------------------------------- shapes
def default_shape(kind, center=(0, 0), extent=16):
    """A small shape of the given kind, for a newly added box."""
    if kind == "rectangle":
        return {"type": "rectangle", "center": list(center), "size": [extent * 2, extent * 2]}
    if kind == "circle":
        return {"type": "circle", "center": list(center), "radius": extent}
    raise DocumentError(f"unknown shape type {kind!r}")


def convert_shape(shape, kind):
    """The same place and roughly the same extent as ``shape``, as another kind."""
    if shape["type"] == kind:
        return dict(shape)
    left, top, right, bottom = shape_bounds(shape)
    if kind == "circle":
        return {"type": "circle", "center": list(shape["center"]), "radius": max(right - left, bottom - top) / 2}
    if kind == "rectangle":
        return {"type": "rectangle", "center": list(shape["center"]), "size": [right - left, bottom - top]}
    raise DocumentError(f"unknown shape type {kind!r}")


def moved_shape(shape, delta):
    """``shape`` translated by ``delta`` in actor space."""
    return {**shape, "center": [shape["center"][0] + delta[0], shape["center"][1] + delta[1]]}


def resized_shape(shape, handle, point):
    """``shape`` after dragging one edge handle to ``point`` (actor space, authored facing right).

    A rectangle moves only the dragged edge; the opposite edge stays where it
    was. A circle keeps its centre and takes the distance to the point along
    the handle's axis as its radius. The result is never smaller than
    ``MINIMUM_EXTENT`` and an edge cannot be dragged past its opposite.
    """
    if handle not in HANDLES:
        raise DocumentError(f"unknown handle {handle!r}")
    axis = 0 if handle in ("left", "right") else 1
    if shape["type"] == "circle":
        return {**shape, "radius": max(MINIMUM_EXTENT / 2, abs(point[axis] - shape["center"][axis]))}
    left, top, right, bottom = shape_bounds(shape)
    if handle == "left":
        left = min(point[0], right - MINIMUM_EXTENT)
    elif handle == "right":
        right = max(point[0], left + MINIMUM_EXTENT)
    elif handle == "top":
        top = min(point[1], bottom - MINIMUM_EXTENT)
    else:
        bottom = max(point[1], top + MINIMUM_EXTENT)
    return {**shape, "center": [(left + right) / 2, (top + bottom) / 2], "size": [right - left, bottom - top]}


def handle_points(shape):
    """``{handle: (x, y)}`` of the four edge handles in actor space."""
    left, top, right, bottom = shape_bounds(shape)
    middle_x, middle_y = (left + right) / 2, (top + bottom) / 2
    return {"left": (left, middle_y), "right": (right, middle_y), "top": (middle_x, top), "bottom": (middle_x, bottom)}


def rounded_shape(shape, digits=2):
    """``shape`` with its numbers rounded, so a drag does not store sub-pixel noise."""
    def tidy(value):
        value = round(float(value), digits)
        return int(value) if value == int(value) else value
    return {key: ([tidy(item) for item in value] if isinstance(value, (list, tuple)) else
                  tidy(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else value)
            for key, value in shape.items()}


# ---------------------------------------------------------------------------------------------- shape slots
class ShapeSlot:
    """Where one editable shape lives in the document.

    ``kind`` is ``body``, ``hurtbox``, ``hitbox`` or ``override`` (a hurtbox
    inside one hurtbox override). ``path`` is the path of the shape value.
    """

    __slots__ = ("kind", "label", "path", "enabled")

    def __init__(self, kind, label, path, enabled=True):
        self.kind, self.label, self.path, self.enabled = kind, label, tuple(path), enabled

    def __eq__(self, other):
        return isinstance(other, ShapeSlot) and self.path == other.path

    def __hash__(self):
        return hash(self.path)

    def __repr__(self):
        return f"ShapeSlot({self.kind!r}, {self.label!r}, {self.path!r})"


def override_index(data, clip_id, frame):
    """Index of the override that applies to exactly this clip and frame (``None`` = whole clip), or None."""
    for index, row in enumerate(_rows(data, OVERRIDES)):
        if row["clip"] == clip_id and row["frame"] == frame:
            return index
    return None


def active_override(data, clip_id, frame):
    """Index of the override in force for a frame: its own first, then the whole-clip one, or None."""
    exact = override_index(data, clip_id, frame)
    return exact if exact is not None else override_index(data, clip_id, None)


def effective_hurtboxes(data, clip_id=None, frame=None):
    """The hurtbox set in force: the frame's override, else the clip's, else the default set."""
    index = active_override(data, clip_id, frame) if clip_id else None
    return list(_rows(data, HURTBOXES) if index is None else _rows(data, OVERRIDES)[index]["boxes"])


def shape_slots(data, clip_id=None, frame=None):
    """Every shape shown for a clip frame, in drawing order: body, hurtboxes in force, hitboxes."""
    slots = [ShapeSlot("body", "body", BODY)]
    index = active_override(data, clip_id, frame) if clip_id else None
    if index is None:
        slots += [ShapeSlot("hurtbox", box["id"], HURTBOXES + (position, "shape"), box["enabled"])
                  for position, box in enumerate(_rows(data, HURTBOXES))]
    else:
        slots += [ShapeSlot("override", box["id"], OVERRIDES + (index, "boxes", position, "shape"), box["enabled"])
                  for position, box in enumerate(_rows(data, OVERRIDES)[index]["boxes"])]
    slots += [ShapeSlot("hitbox", box["id"], HITBOXES + (position, "shape"))
              for position, box in enumerate(_rows(data, HITBOXES))]
    return slots


def _plain_shape(value):
    return {key: (list(item) if isinstance(item, (list, tuple)) else item) for key, item in value.items()}


def shape_at(data, slot):
    """The shape a slot points at, as a plain dict."""
    value = data
    for key in slot.path:
        value = value[key]
    return _plain_shape(value)


def set_shape(slot, shape):
    """Edits that store a shape in its slot."""
    return [set_value(slot.path, rounded_shape(shape))]


def add_box(data, kind, shape_kind="rectangle"):
    """``(id, edits)`` that add a default hurtbox or hitbox."""
    path = HURTBOXES if kind == "hurtbox" else HITBOXES if kind == "hitbox" else None
    if path is None:
        raise DocumentError(f"cannot add a {kind}")
    box_id = unique_id(kind, (row["id"] for row in _rows(data, path)))
    row = {"id": box_id, "shape": default_shape(shape_kind)}
    if kind == "hurtbox":
        row["enabled"] = True
    return box_id, [insert_item(path, row)]


def remove_box(slot):
    """Edits that remove the box a slot belongs to. The body cannot be removed."""
    if slot.kind == "body":
        raise DocumentError("the body shape cannot be removed")
    return [remove_item(slot.path[:-1])]


def create_override(data, clip_id, frame=None):
    """Edits that give a clip frame (``None`` = the whole clip) its own copy of the hurtbox set in force."""
    clip = _rows(data, CLIPS)[clip_index(data, clip_id)]
    if frame is not None and not 0 <= frame < len(clip["frames"]):
        raise DocumentError(f"clip {clip_id!r} has no frame {frame}")
    if override_index(data, clip_id, frame) is not None:
        raise DocumentError("this frame already has its own hurtbox set")
    boxes = [{"id": box["id"], "shape": _plain_shape(box["shape"]), "enabled": box["enabled"]}
             for box in effective_hurtboxes(data, clip_id, frame)]
    return [insert_item(OVERRIDES, {"clip": clip_id, "frame": frame, "boxes": boxes})]


def remove_override(data, clip_id, frame=None):
    """Edits that drop a frame's own hurtbox set, so the clip's or the default set applies again."""
    index = override_index(data, clip_id, frame)
    if index is None:
        raise DocumentError("this frame has no hurtbox set of its own")
    return [remove_item(OVERRIDES + (index,))]
