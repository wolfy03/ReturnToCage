"""Schema ranges and reference integrity. Both are derived from the schema, not written per field."""

from collections import Counter

from ..catalog import DUPLICATE_ID
from ..project import bound_definition_id
from ..schema import REFERENCE_SOURCES, format_path
from ..spec import Id, Map
from .context import rule
from .report import (AI, ANIMATION, ASSETS, ATTACK, COLLISION, FAIL, IN_PROJECT, NOT_EVALUATED, NOWHERE, REFERENCES,
                     SCHEMA, WARNING, define)

define(None, FAIL, {"out_of_range": "A number is outside the range its field allows."})
define(SCHEMA, FAIL, {
    "unreadable_document": "The bytes are not a readable .rtcmonster document.",
    "loot_amount_order": "A loot row's minimum amount is larger than its maximum.",
    "loot_table_id_missing": "Loot rows are managed by the document but no loot table ID is set.",
})
define(REFERENCES, FAIL, {
    "duplicate_image_id": "Two images share an ID.",
    "duplicate_animation_id": "Two animation clips share an ID.",
    "duplicate_hurtbox_id": "Two hurtboxes of one set share an ID.",
    "duplicate_hitbox_id": "Two hitboxes share an ID.",
    "duplicate_pattern_id": "Two attack patterns share an ID.",
    "duplicate_state_id": "Two states share an ID.",
    "duplicate_phase_id": "Two phases share an ID.",
    "duplicate_hurtbox_override": "Two hurtbox overrides target the same clip and frame.",
    "unknown_image": "A frame names an image that is not registered.",
    "unknown_animation": "A field names an animation clip that does not exist.",
    "unknown_hitbox": "An event names a hitbox that does not exist.",
    "unknown_pattern": "A field names an attack pattern that does not exist.",
    "unknown_state": "A field names a state that does not exist.",
    "frame_out_of_range": "A hurtbox override names a frame the clip does not have.",
    "duplicate_monster_id": "A draft uses the ID of a monster the game already has.",
    "binding_id_mismatch": "The document's ID differs from the EnemyDefinition it is bound to.",
})
define(REFERENCES, FAIL, {
    "unknown_loot_table": "The loot table ID does not exist in the project.",
    "unknown_item": "A loot row names an item that does not exist in the project.",
    "catalog_duplicate_id": "Several project files define this monster's ID; none of them is authoritative.",
}, remedy=IN_PROJECT)
define(REFERENCES, WARNING, {
    "catalog_problem": "A project content file could not be catalogued, so ID checks may be incomplete.",
}, remedy=IN_PROJECT)
define(REFERENCES, NOT_EVALUATED, {
    "monster_id_uniqueness_unchecked": "No project folder was given, so the ID was not compared with the game.",
    "loot_reference_unchecked": "No project folder was given, so loot references were not checked.",
}, remedy=NOWHERE)

_RANGE_DOMAINS = (("collision", COLLISION), ("attack_patterns", ATTACK), ("behavior", AI),
                  ("animations", ANIMATION), ("presentation", ANIMATION), ("assets", ASSETS))
# Lists whose items must have unique IDs: everything referable, plus two that are only listed.
_UNIQUE = {**REFERENCE_SOURCES, "hurtbox": ("collision", "hurtboxes"), "phase": ("behavior", "phases")}


@rule
def ranges(context):
    def report(path, code, detail):
        domain = next((domain for prefix, domain in _RANGE_DOMAINS if path.startswith(prefix)), SCHEMA)
        context.add(code, path, detail, domain=domain)

    context.schema.document.check(context.data, "", report)
    loot = context.data["loot"]
    for index, row in enumerate(loot["entries"] or ()):
        if row["min_amount"] > row["max_amount"]:
            context.add("loot_amount_order", f"loot.entries[{index}]",
                        f"min {row['min_amount']} > max {row['max_amount']}", subject=row["item_id"])
    if loot["entries"] is not None and not loot["loot_table_id"]:
        context.add("loot_table_id_missing", "loot.loot_table_id")


def _duplicates(context, rows, kind, path):
    counts = Counter(row["id"] for row in rows)
    for index, row in enumerate(rows):
        if counts[row["id"]] > 1:
            context.add(f"duplicate_{kind}_id", f"{path}[{index}].id", row["id"], subject=row["id"])


@rule
def unique_ids(context):
    for kind, path in _UNIQUE.items():
        rows = context.data
        for key in path:
            rows = rows[key]
        _duplicates(context, rows, kind, format_path(path))
    overrides = context.data["collision"]["hurtbox_overrides"]
    seen = Counter((row["clip"], row["frame"]) for row in overrides)
    for index, row in enumerate(overrides):
        path = f"collision.hurtbox_overrides[{index}]"
        _duplicates(context, row["boxes"], "hurtbox", f"{path}.boxes")
        clip = context.index["animation"].get(row["clip"])
        if clip is not None and row["frame"] is not None and row["frame"] >= len(clip["frames"]):
            context.add("frame_out_of_range", f"{path}.frame", f"{row['clip']} has {len(clip['frames'])} frames",
                        subject=row["clip"])
        if seen[row["clip"], row["frame"]] > 1:
            context.add("duplicate_hurtbox_override", path, f"{row['clip']} / {row['frame']}", subject=row["clip"])


@rule
def references(context):
    """Every identifier field that declares what it points at must point at something that exists."""
    for path, node, value in context.schema.fields(context.data):
        if isinstance(node, Id) and node.ref and value != "" and value not in context.index[node.ref]:
            context.add(f"unknown_{node.ref}", format_path(path), value, subject=value)
        elif isinstance(node, Map) and node.key_ref:
            for key in value:
                if key not in context.index[node.key_ref]:
                    context.add(f"unknown_{node.key_ref}", format_path(path + (key,)), key, subject=key)
    for index, state in enumerate(context.data["behavior"]["states"]):
        if state["animation"]["mode"] == "clip" and not state["animation"]["clip"]:
            context.add("unknown_animation", f"behavior.states[{index}].animation.clip",
                        "mode 'clip' needs a clip", subject=state["id"])


@rule
def project_references(context):
    data = context.data
    binding, loot, monster_id = data["source_binding"], data["loot"], data["monster_id"]
    if context.project is None:
        context.add("monster_id_uniqueness_unchecked", "monster_id", "No project folder was given.")
        if loot["loot_table_id"] or loot["entries"]:
            context.add("loot_reference_unchecked", "loot")
        return
    enemies = context.project.content("enemies")
    for problem in enemies.problems:
        if problem.code == DUPLICATE_ID and problem.id == monster_id:
            context.add("catalog_duplicate_id", "monster_id", f"{problem.path}: {problem.detail}",
                        related=(problem.path,), subject=monster_id)
        else:
            context.add("catalog_problem", "", f"{problem.code}: {problem.path} {problem.detail}".strip(),
                        related=(problem.path,), subject=problem.id)
    if binding is None:
        if monster_id in enemies.entries:
            context.add("duplicate_monster_id", "monster_id",
                        f"already published by {enemies.entries[monster_id].path}",
                        related=(enemies.entries[monster_id].path,), subject=monster_id)
    else:
        bound = bound_definition_id(context.project.root, binding["definition_path"])
        if bound is not None and bound != monster_id:
            context.add("binding_id_mismatch", "monster_id", f"{binding['definition_path']} defines {bound}",
                        related=(binding["definition_path"],), subject=monster_id)
    if loot["entries"] is None:
        if loot["loot_table_id"] and loot["loot_table_id"] not in context.project.content("loot").entries:
            context.add("unknown_loot_table", "loot.loot_table_id", loot["loot_table_id"],
                        subject=loot["loot_table_id"])
    else:
        items = context.project.content("items").entries
        for index, row in enumerate(loot["entries"]):
            if row["item_id"] not in items:
                context.add("unknown_item", f"loot.entries[{index}].item_id", row["item_id"], subject=row["item_id"])
