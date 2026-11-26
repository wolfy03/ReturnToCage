"""Who points at what inside one document, and how an edit keeps those pointers true. No Qt.

Two kinds of pointer exist in Schema V1:

* **ID references** - a field declared ``Id(ref=kind)`` (or a map keyed by one) names an image, an
  animation clip, a hitbox, an attack pattern or a state. They are found with the schema's own walk, so a
  module or event added to the registry later is covered without touching this file.
* **Frame indexes** - a number that means "frame N of clip C". There are exactly two:
  ``collision.hurtbox_overrides[].frame`` (of the override's own clip) and
  ``presentation.attack_hit_frame`` (of the clip bound to the ``attack`` role). Attack pattern events are
  timed in seconds and are *not* frame references; reordering frames never touches them.

Everything here returns edits or descriptions. Nothing is applied: the caller passes the edits of one
user action to ``DocumentSession.apply`` together, so the action is atomic and one undo step.

This is the module the attack-pattern and behaviour editors use for "may I delete this?", "what breaks if
I do?" and "rename it everywhere".
"""

from dataclasses import dataclass
import re

from rtcmonster import DocumentError, format_path, rename_id, set_value
from rtcmonster.schema import REFERENCE_SOURCES
from rtcmonster.spec import ID_PATTERN, Id, Map

OVERRIDES = ("collision", "hurtbox_overrides")
HIT_FRAME = ("presentation", "attack_hit_frame")
# A reference from one of these places is part of the thing's own presentation and is dropped with it.
# Anything else (attack patterns, behaviour states, events) carries gameplay meaning: it is never removed
# or redirected on the editor's own initiative.
SOFT_SECTIONS = ("presentation", "collision")


class ReferenceBlocked(DocumentError):
    """The edit would leave a gameplay reference dangling. ``usages`` says which."""

    def __init__(self, message, usages):
        super().__init__(message)
        self.usages = tuple(usages)


@dataclass(frozen=True)
class Usage:
    """One place that names a target. ``path`` is a tuple path; ``key`` is True for a map key."""
    kind: str               # the reference kind: image / animation / hitbox / pattern / state
    target: str
    path: tuple
    key: bool = False

    @property
    def section(self):
        return self.path[0]

    @property
    def soft(self):
        return self.section in SOFT_SECTIONS

    @property
    def where(self):
        return format_path(self.path)


def incoming(document, kind, target):
    """Every field of the document that names ``target`` as a reference of ``kind``, in document order."""
    if kind not in REFERENCE_SOURCES:
        raise DocumentError(f"unknown reference kind: {kind}")
    found = []
    for path, node, value in document.schema.fields(document.data):
        if isinstance(node, Id) and node.ref == kind and value == target:
            found.append(Usage(kind, target, tuple(path)))
        elif isinstance(node, Map) and node.key_ref == kind and target in value:
            found.append(Usage(kind, target, tuple(path) + (target,), key=True))
    return found


def exists(document, kind, target):
    rows = document.data
    for key in REFERENCE_SOURCES[kind]:
        rows = rows[key]
    return any(row["id"] == target for row in rows)


def blocking(usages):
    return [usage for usage in usages if not usage.soft]


def describe(usages):
    """One line per usage, for a confirmation or a refusal."""
    return [usage.where for usage in usages]


def retarget(document, kind, old, new, usages=None):
    """Edits that make every reference to ``old`` name ``new`` instead. ``new`` must exist."""
    if not exists(document, kind, new):
        raise DocumentError(f"{kind} {new!r} does not exist")
    if new == old:
        raise DocumentError(f"{kind} {old!r} cannot replace itself")
    usages = incoming(document, kind, old) if usages is None else usages
    if any(usage.key for usage in usages):
        raise DocumentError(f"{kind} {old!r} is used as a table key and cannot be redirected")
    return [set_value(usage.path, new) for usage in usages]


def rename(document, kind, old, new):
    """Edits that rename an object and every reference to it (the core's own rename, checked first)."""
    if not exists(document, kind, old):
        raise DocumentError(f"{kind} {old!r} does not exist")
    if new == old:
        return []
    if not isinstance(new, str) or not re.fullmatch(ID_PATTERN, new):
        raise DocumentError(f"{new!r} is not a valid identifier")
    if exists(document, kind, new):
        raise DocumentError(f"{kind} {new!r} already exists")
    return [rename_id(kind, old, new)]


# ------------------------------------------------------------------------------------------ frame indexes
@dataclass(frozen=True)
class FrameUsage:
    """A number that means "frame ``frame`` of clip ``clip``"."""
    what: str               # "hurtbox_override" or "attack_hit_frame"
    clip: str
    frame: int
    path: tuple

    @property
    def where(self):
        return format_path(self.path)


def frame_usages(data, clip_id):
    """Every frame index that refers to a frame of ``clip_id``.

    ``attack_hit_frame`` counts only while the clip is bound to the ``attack`` role, and only while it
    names a frame the clip really has (a stale value is validation's business, not a reference).
    """
    found = []
    frames = next((len(clip["frames"]) for clip in data["animations"]["clips"] if clip["id"] == clip_id), 0)
    for index, row in enumerate(data["collision"]["hurtbox_overrides"]):
        if row["clip"] == clip_id and row["frame"] is not None:
            found.append(FrameUsage("hurtbox_override", clip_id, row["frame"], OVERRIDES + (index, "frame")))
    hit = data["presentation"]["attack_hit_frame"]
    if data["presentation"]["roles"]["attack"] == clip_id and hit < frames:
        found.append(FrameUsage("attack_hit_frame", clip_id, hit, HIT_FRAME))
    return found


def move_mapping(count, source, target):
    """``{old index: new index}`` after moving the item at ``source`` so that it ends at ``target``."""
    if not (0 <= source < count and 0 <= target < count):
        raise DocumentError(f"cannot move frame {source} to {target} in a clip of {count} frames")
    order = list(range(count))
    order.insert(target, order.pop(source))
    return {old: new for new, old in enumerate(order)}


def insert_mapping(count, index):
    if not 0 <= index <= count:
        raise DocumentError(f"cannot insert a frame at {index} in a clip of {count} frames")
    return {old: old + (1 if old >= index else 0) for old in range(count)}


def remove_mapping(count, index):
    """``{old: new}``; the removed frame maps to None."""
    if not 0 <= index < count:
        raise DocumentError(f"the clip has no frame {index}")
    return {old: (None if old == index else old - (1 if old > index else 0)) for old in range(count)}


def remap_frames(data, clip_id, mapping):
    """Edits that move every frame index of ``clip_id`` through ``mapping`` (old -> new).

    A usage whose frame maps to None must have been dealt with by the caller (removed or given a new
    value) - leaving it would silently re-point it at whatever frame takes that number, so it is refused.
    Indexes outside the mapping are left alone.
    """
    edits = []
    for usage in frame_usages(data, clip_id):
        if usage.frame not in mapping:
            continue
        new = mapping[usage.frame]
        if new is None:
            raise ReferenceBlocked(f"{usage.where} still points at the removed frame {usage.frame}", [usage])
        if new != usage.frame:
            edits.append(set_value(usage.path, new))
    return edits
