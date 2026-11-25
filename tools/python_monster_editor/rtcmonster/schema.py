"""`.rtcmonster` Schema V1.

The tree below is the single definition of the document: decoding, range
validation, defaults and the field reference in docs/monster_editor_schema_v1.md
are all derived from it (``python -m rtcmonster.reference`` prints the tables).

Units follow Godot 2D: pixels, seconds, +X right, +Y down, actor-local origin.
"""

from dataclasses import dataclass

from .modules import CONDITIONS, EVENTS, MODULES, SNAPSHOT_STATES, STAT_NAMES
from .spec import (APPLIED, CONTRACT, EDITOR, PLANNED, AnyJson, Arr, Bool, Choice, DocumentError, Id, Map, Node, Num,
                   Obj, Opt, ProjectPath, Str, Union, Vec, _fail)

SCHEMA_VERSION = 1
DOCUMENT_TYPE = "rtcmonster"
SUFFIX = ".rtcmonster"
MAX_CONDITION_DEPTH = 8
MAX_IMAGE_EXTENT = 8192
MAX_IMAGE_BYTES = 16 * 1024 * 1024
SECTIONS = ("metadata", "stats", "movement", "sensors", "assets", "animations", "presentation", "collision",
            "attack_patterns", "behavior", "loot")
EDITABILITY = ("editable", "read_only", "unsupported", "passthrough")
ROLES = ("idle", "move", "attack", "hurt", "death", "jump_start", "jump", "fall", "land")
REQUIRED_ROLES = ROLES[:5]
LOOPING_ROLES = ("idle", "move", "jump", "fall")
ONE_SHOT_ROLES = ("attack", "hurt", "death", "jump_start", "land")


@dataclass(frozen=True)
class Quantity(Node):
    """A number, or a stat reference ``{"stat": name, "scale": k, "offset": c}`` = stat * k + c."""
    value: object = 0
    low: float = 0
    high: float = 1_000_000
    unit: str = "px"
    support: str = CONTRACT
    doc: str = ""
    required: bool = False

    _reference = Obj({"stat": Choice(STAT_NAMES, required=True), "scale": Num(1, -1000, 1000),
                      "offset": Num(0, -1_000_000, 1_000_000)})

    def default(self):
        return dict(self.value) if isinstance(self.value, dict) else self.value

    def normalize(self, value, path):
        if isinstance(value, dict):
            return self._reference.normalize(value, path)
        return Num().normalize(value, path)

    def check(self, value, path, report):
        if isinstance(value, dict):
            self._reference.check(value, path, report)
        else:
            Num(low=self.low, high=self.high).check(value, path, report)

    def describe(self):
        return {"type": "number or stat reference", "default": self.default(),
                "range": f"[{self.low}, {self.high}]", "unit": self.unit}


def resolve(quantity, stats):
    """Evaluate a Quantity against ``stats`` (the document's stats object)."""
    if isinstance(quantity, dict):
        return stats[quantity["stat"]] * quantity["scale"] + quantity["offset"]
    return quantity


def _params(raw):
    return {key: Quantity(required=True, unit=node[1], low=node[2], high=node[3]) if isinstance(node, tuple) else node
            for key, node in raw.items()}


SHAPE = Union("type", {
    "rectangle": {"center": Vec((0, 0), low=-4096, high=4096, doc="Centre, actor-local, authored facing right."),
                  "size": Vec(None, low=0, high=4096, exclusive_low=True, required=True,
                              doc="Full width and height (RectangleShape2D.size).")},
    "circle": {"center": Vec((0, 0), low=-4096, high=4096),
               "radius": Num(None, 0, 2048, "px", exclusive_low=True, required=True)},
}, required=True, doc="Collision shape. capsule, polygon and composite are reserved and rejected in V1.")
RESERVED_SHAPES = ("capsule", "polygon", "composite")


class ConditionNode(Node):
    """Leaf ``{"type": ...}`` or a combinator ``{"all": [...]}``, ``{"any": [...]}``, ``{"not": {...}}``."""
    support = CONTRACT
    doc = "Transition condition."
    required = True
    _leaf = Union("type", {name: _params(entry.params) for name, entry in CONDITIONS.items()})

    def default(self):
        return {"type": "Always"}

    def normalize(self, value, path, depth=0):
        if depth > MAX_CONDITION_DEPTH:
            _fail(path, f"conditions nest deeper than {MAX_CONDITION_DEPTH}")
        if not isinstance(value, dict):
            _fail(path, "expected a condition object")
        keys = set(value)
        for combinator in ("all", "any"):
            if keys == {combinator}:
                parts = value[combinator]
                if not isinstance(parts, list) or not 1 <= len(parts) <= 16:
                    _fail(path, f"'{combinator}' needs 1 to 16 conditions")
                return {combinator: [self.normalize(part, f"{path}.{combinator}[{index}]", depth + 1)
                                     for index, part in enumerate(parts)]}
        if keys == {"not"}:
            return {"not": self.normalize(value["not"], f"{path}.not", depth + 1)}
        return self._leaf.normalize(value, path)

    def check(self, value, path, report):
        for path_, leaf in condition_leaves(value, path):
            self._leaf.check(leaf, path_, report)

    def describe(self):
        return {"type": "condition", "range": "leaf | all | any | not"}


def condition_leaves(condition, path=""):
    """Yield ``(path, leaf)`` for every leaf condition, in evaluation order."""
    for combinator in ("all", "any"):
        if combinator in condition:
            for index, part in enumerate(condition[combinator]):
                yield from condition_leaves(part, f"{path}.{combinator}[{index}]")
            return
    if "not" in condition:
        yield from condition_leaves(condition["not"], f"{path}.not")
    else:
        yield path, condition


CONDITION = ConditionNode()

EVENT = Union("type", {name: _params(entry.params) for name, entry in EVENTS.items()},
              common={"time": Num(None, 0, 30, "s", required=True,
                                  doc="Seconds from the start of the pattern. Never a frame number.")})

_BOX = Obj({"id": Id(required=True), "shape": SHAPE, "enabled": Bool(True)})

_STATE_BASE = {
    "id": Id(required=True),
    "display_name": Str("", support=EDITOR),
    "module": Str("", 64, required=True, doc="Registered module ID. Unknown IDs are a validation failure."),
    "params": AnyJson(8192, support=CONTRACT, doc="Module parameters. Missing ones take the module default."),
    "animation": Obj({
        "mode": Choice(("auto", "clip", "pattern"), "auto",
                       doc="auto = presenter role rules; clip = fixed clip; pattern = the running pattern's clip."),
        "clip": Id("", empty=True),
    }),
    "snapshot_state": Choice(("auto",) + SNAPSHOT_STATES, "auto",
                             doc="EnemyRuntimeSnapshot.State replicated in this state. auto = the module's own."),
    "max_seconds": Opt(Num(None, 0.05, 3600, "s"), doc="Raises ActionFailed when exceeded. null = no limit."),
    "interruptible": Bool(True, support=PLANNED, doc="false = the hurt interrupt is ignored in this state."),
    "transitions": Arr(Obj({
        "to": Id(required=True),
        "priority": Num(0, -1000, 1000, integer=True, doc="Higher is evaluated first; ties keep document order."),
        "condition": CONDITION,
    }), 32),
}


class StateNode(Node):
    """A state whose ``params`` are typed by the module it names."""
    support = CONTRACT
    doc = "One finite-state-machine state."
    _base = Obj(_STATE_BASE)

    def normalize(self, value, path):
        state = self._base.normalize(value, path)
        module = MODULES.get(state["module"])
        if module is not None:
            state["params"] = Obj(module.params).normalize(state["params"], f"{path}.params")
        return state

    def check(self, value, path, report):
        self._base.check(value, path, report)
        module = MODULES.get(value["module"])
        if module is not None:
            Obj(module.params).check(value["params"], f"{path}.params", report)

    def describe(self):
        return {"type": "state"}


DOCUMENT = Obj({
    "monster_id": Id(required=True, support=APPLIED,
                     doc="EnemyDefinition.id. Map spawns reference it, so it never follows the display name."),
    "metadata": Obj({
        "display_name": Str("", 120, required=True, support=APPLIED, doc="EnemyDefinition.display_name."),
        "description": Str("", 2000, multiline=True, support=EDITOR),
        "category": Id("", empty=True, support=EDITOR, doc="Catalog grouping, for example beetle or amphibian."),
        "rank": Choice(("normal", "elite", "boss"), "normal", support=PLANNED),
        "habitats": Arr(Id(), 16, support=EDITOR, doc="Region IDs or biome names the monster is meant for."),
        "tags": Arr(Id(), 32, support=EDITOR),
        "thumbnail": ProjectPath((".png",), support=EDITOR),
    }),
    "stats": Obj({
        "max_health": Num(20, 1, 99999, "HP", support=APPLIED),
        "attack_damage": Num(4, 0, 9999, "HP", support=APPLIED),
        "move_speed": Num(55, 0, 1000, "px/s", support=APPLIED),
        "chase_range": Num(230, 0, 2000, "px", support=APPLIED),
        "attack_range": Num(42, 0, 1000, "px", support=APPLIED),
        "faction": Id("hostile", support=APPLIED),
        "hit_invulnerability_seconds": Num(0.35, 0, 10, "s",
                                           doc="HealthComponent.invulnerability_seconds on the actor scene: "
                                               "direct hits are ignored this long after one lands."),
        "planned": Obj({
            "defense": Num(0, 0, 9999, "HP"),
            "attack_speed": Num(1, 0.1, 10, "x"),
            "knockback_resistance": Num(0, 0, 1, "ratio"),
            "stagger_resistance": Num(0, 0, 1, "ratio"),
            "damage_resistances": Map(Num(0, -1, 1, "ratio")),
            "status_resistances": Map(Num(0, 0, 1, "ratio")),
        }, support=PLANNED, doc="Stored for later steps. No runtime applies any of these."),
    }),
    "movement": Obj({
        "locomotion": Choice(("ground", "hop"), "ground", doc="fly is reserved."),
        "gravity": Num(1100, 0, 5000, "px/s^2", doc="EnemyAgent.GRAVITY. A constant in the legacy runtime."),
        "ground_brake": Num(0, 0, 10000, "px/s^2", doc="Deceleration of leftover ground speed. 0 = none."),
        "ground_grace_seconds": Num(0, 0, 1, "s", doc="Floor contact is remembered this long."),
    }),
    "sensors": Obj({
        "target_policy": Choice(("nearest_player",), "nearest_player"),
        "target_keep_scale": Num(1.35, 1, 10, "x chase_range",
                                 doc="The current target is kept inside chase_range times this."),
        "leash_distance": Opt(Num(None, 32, 4000, "px"), doc="Farthest chase from the spawn origin. null = none."),
    }),
    "assets": Obj({
        "images": Arr(Obj({
            "id": Id(required=True),
            "path": ProjectPath((".png",), empty=False, required=True),
            "width": Num(None, 1, MAX_IMAGE_EXTENT, "px", integer=True, required=True),
            "height": Num(None, 1, MAX_IMAGE_EXTENT, "px", integer=True, required=True),
            "sha256": Str("", 64, doc='Content hash when the image was registered. "" = not recorded.'),
        }), 256),
    }, support=APPLIED),
    "animations": Obj({
        "clips": Arr(Obj({
            "id": Id(required=True),
            "display_name": Str("", support=EDITOR),
            "fps": Num(10, 0.1, 120, "frames/s", doc="SpriteFrames animation speed."),
            "loop": Bool(False),
            "on_finish": Choice(("hold_last_frame", "return_to_locomotion"), "hold_last_frame", support=PLANNED),
            "priority": Num(0, 0, 100, integer=True, support=PLANNED),
            "frames": Arr(Obj({
                "image": Id(required=True),
                "rect": Opt(Vec(None, 4, 0, MAX_IMAGE_EXTENT, integer=True),
                            doc="[x, y, w, h] inside the image. null = the whole image."),
                "duration": Num(1, 0.01, 100, "x", doc="SpriteFrames relative duration. Seconds = duration / fps."),
                "offset": Vec((0, 0), low=-4096, high=4096, support=PLANNED),
            }), 256),
        }), 128),
    }, support=APPLIED),
    "presentation": Obj({
        "faces_right_by_default": Bool(True),
        "visual_scale": Vec((1, 1), low=0, high=64, unit="x", exclusive_low=True),
        "visual_offset": Vec((0, 0), low=-4096, high=4096,
                             doc="Position of the frame centre, in the unscaled visual space."),
        "airborne_speed": Num(30, 1, 400, "px/s"),
        "move_speed_threshold": Num(8, 0, 400, "px/s"),
        "attack_hit_frame": Num(0, 0, 64, "frame", integer=True,
                                doc="First attack frame that shows the strike. Presentation only."),
        "roles": Obj({role: Id("", empty=True) for role in ROLES},
                     doc="EnemyAnimationProfile clip names by role."),
    }, support=APPLIED),
    "collision": Obj({
        "body": Obj({
            "shape": SHAPE,
            "layer": Num(1, 0, 2 ** 32 - 1, integer=True),
            "mask": Num(1, 0, 2 ** 32 - 1, integer=True),
        }, required=True, doc="World collision. Never changes with animation frames."),
        "hurtboxes": Arr(_BOX, 16, doc="Default hurtbox set (layer 2 / mask 4)."),
        "hurtbox_overrides": Arr(Obj({
            "clip": Id(required=True),
            "frame": Opt(Num(None, 0, 255, integer=True), doc="null = every frame of the clip."),
            "boxes": Arr(_BOX, 16, required=True, doc="Replaces the whole set. [] = no hurtbox at all."),
        }), 512, support=PLANNED),
        "hitboxes": Arr(Obj({"id": Id(required=True), "shape": SHAPE}), 64, support=PLANNED,
                        doc="Hitbox shapes (layer 4 / mask 2) armed by EnableHitbox events."),
    }),
    "attack_patterns": Arr(Obj({
        "id": Id(required=True),
        "display_name": Str("", support=EDITOR),
        "kind": Choice(("melee", "leap"), "melee", doc="projectile is reserved."),
        "clip": Id("", empty=True, doc="Clip shown while the pattern runs."),
        "duration": Num(0.7, 0.05, 30, "s"),
        "completion": Obj({
            "mode": Choice(("duration", "duration_and_landed"), "duration"),
            "min_air_seconds": Num(0.08, 0, 5, "s"),
            "max_air_seconds": Num(2.5, 0.1, 30, "s"),
        }),
        "range": Obj({
            "min": Quantity(0, 0, 4000),
            "max": Quantity({"stat": "attack_range", "scale": 1, "offset": 0}, 0, 4000),
            "vertical": Opt(Num(None, 0, 4000, "px"), doc="Largest height difference. null = unlimited."),
        }),
        "cooldown": Num(0, 0, 600, "s"),
        "priority": Num(0, -1000, 1000, integer=True),
        "weight": Num(1, 0, 1000, exclusive_low=True),
        "condition": Opt(CONDITION, support=PLANNED),
        "movement_locked": Bool(True),
        "facing_locked": Bool(True),
        "interrupt": Obj({"on_hurt": Choice(("cancel", "ignore"), "cancel")}),
        "damage": Obj({
            "multiplier": Num(1, 0, 100, "x attack_power"),
            "type": Id("physical"),
            "knockback": Vec((100, -30), low=-10000, high=10000, unit="px/s"),
            "hit_policy": Choice(("once_per_target", "multi_hit"), "once_per_target"),
            "multi_hit_interval": Num(0.25, 0.05, 10, "s"),
            "status_effects": Arr(Id(), 8, support=PLANNED),
        }),
        "phases": Arr(Obj({
            "kind": Choice(("windup", "active", "recovery"), required=True),
            "start": Num(None, 0, 30, "s", required=True),
            "end": Num(None, 0, 30, "s", required=True),
        }), 32),
        "events": Arr(EVENT, 128),
    }), 64),
    "behavior": Obj({
        "initial_state": Id("idle"),
        "interrupts": Obj({
            "hurt": Obj({"state": Id("hurt", empty=True), "policy": Choice(("always", "never"), "always")}),
            "death": Obj({"state": Id("dead")}),
        }, doc="Global interrupts. Death outranks hurt, and both outrank every transition."),
        "states": Arr(StateNode(), 64),
        "phases": Arr(Obj({
            "id": Id(required=True),
            "health_ratio_below": Num(None, 0, 1, "ratio", required=True),
            "enter_state": Id("", empty=True),
            "pattern_weights": Map(Num(1, 0, 1000)),
        }), 16, support=PLANNED),
    }),
    "loot": Obj({
        "loot_table_id": Id("", empty=True, support=APPLIED),
        "entries": Opt(Arr(Obj({
            "item_id": Id(required=True),
            "weight": Num(None, 0, 1_000_000, exclusive_low=True, required=True),
            "min_amount": Num(1, 1, 9999, integer=True),
            "max_amount": Num(1, 1, 9999, integer=True),
        }), 64), doc="LootTableDefinition rows. null = the table is not managed by this document."),
        "apply_difficulty_multiplier": Bool(True),
    }, support=APPLIED),
    "source_binding": Opt(Obj({
        "runtime": Choice(("legacy", "data_driven"), required=True),
        "definition_path": ProjectPath((".tres",), empty=False, required=True),
        "actor_scene_path": ProjectPath((".tscn",)),
        "animation_profile_path": ProjectPath((".tres",)),
        "sprite_frames_path": ProjectPath((".tres",)),
        "loot_table_path": ProjectPath((".tres",)),
        "files": Arr(Obj({"path": ProjectPath((".tres", ".tscn", ".gd", ".png"), empty=False, required=True),
                          "sha256": Str("", 64, required=True)}), 256,
                     doc="Every project file the document was derived from, with its hash at import."),
        "editability": Map(Choice(EDITABILITY, "editable")),
        "unsupported": Arr(Obj({"path": Str("", 256, required=True), "reason": Str("", 500, required=True)}), 128),
        "passthrough": AnyJson(),
    }), support=EDITOR, doc="null = draft that was never published. Otherwise the Godot resources it mirrors."),
    "editor_metadata": Obj({
        "notes": Str("", 4000, multiline=True),
        "estimated": Arr(Str("", 256), 512, doc="Paths whose values are guesses, not measured game values."),
        "ui": AnyJson(),
    }, support=EDITOR),
})

TOP_LEVEL_ORDER = ("schema_version", "document_type") + tuple(DOCUMENT.fields)


def normalize(data):
    """Shape-check and default-fill the body of a document (without the version fields)."""
    return DOCUMENT.normalize(data, "")


__all__ = ["DOCUMENT", "SCHEMA_VERSION", "DOCUMENT_TYPE", "SUFFIX", "DocumentError", "normalize", "resolve",
           "condition_leaves", "Quantity"]
