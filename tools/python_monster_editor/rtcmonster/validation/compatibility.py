"""What the stored data means for a runtime that exists today, and whether its sources are unchanged."""

import re

from .. import project as project_files
from ..schema import StateNode, condition_leaves
from ..spec import PLANNED, Arr, DocumentError, Map, Obj, Opt
from .context import rule
from .report import COMPATIBILITY, FAIL, IN_PROJECT, NOT_EVALUATED, NOWHERE, WARNING, define

define(COMPATIBILITY, WARNING, {
    "value_not_applied_by_any_runtime": "A planned field has a non-default value that no runtime reads.",
    "planned_module": "A state uses a module that is only planned.",
    "planned_condition": "A transition uses a condition that is only planned.",
    "planned_event": "An attack pattern uses an event that is only planned.",
})
define(COMPATIBILITY, FAIL, {
    "source_missing": "A project file this document was derived from no longer exists.",
}, remedy=IN_PROJECT)
define(COMPATIBILITY, WARNING, {
    "source_changed": "A project file changed since this document was derived from it.",
}, remedy=IN_PROJECT)
define(COMPATIBILITY, NOT_EVALUATED, {
    "source_files_unchecked": "No project folder was given, so the source files were not compared.",
}, remedy=NOWHERE)


def _planned_paths(node, value, path="", inherited=False):
    """Paths of values that differ from their default but that no runtime reads."""
    if isinstance(node, StateNode):
        node = node.base
    planned = inherited or node.support == PLANNED
    if isinstance(node, Opt):
        if value is not None:
            if planned:
                yield path
            else:
                yield from _planned_paths(node.node, value, path, planned)
    elif isinstance(node, Obj):
        for key, child in node.fields.items():
            yield from _planned_paths(child, value[key], f"{path}.{key}" if path else key, planned)
    elif isinstance(node, Arr):
        if planned:
            if value:
                yield path
        else:
            for index, item in enumerate(value):
                yield from _planned_paths(node.item, item, f"{path}[{index}]", False)
    elif isinstance(node, Map):
        if planned and value:
            yield path
    elif planned:
        try:
            if value != node.default():
                yield path
        except (NotImplementedError, DocumentError):
            return


@rule
def planned_features(context):
    data, registry = context.data, context.registry
    for path in _planned_paths(context.schema.document, data):
        context.add("value_not_applied_by_any_runtime", path)
    for index, state in enumerate(data["behavior"]["states"]):
        path = f"behavior.states[{index}]"
        module = context.module(state)
        if module is not None and module.support == PLANNED:
            context.add("planned_module", f"{path}.module", state["module"], subject=state["id"])
        for transition_index, transition in enumerate(state["transitions"]):
            for leaf_path, leaf in condition_leaves(
                    transition["condition"], f"{path}.transitions[{transition_index}].condition"):
                if registry.conditions[leaf["type"]].support == PLANNED:
                    context.add("planned_condition", leaf_path, leaf["type"], subject=state["id"])
    for index, pattern in enumerate(data["attack_patterns"]):
        for event_index, event in enumerate(pattern["events"]):
            if registry.events[event["type"]].support == PLANNED:
                context.add("planned_event", f"attack_patterns[{index}].events[{event_index}]", event["type"],
                            subject=pattern["id"])


@rule
def source_files(context):
    binding = context.data["source_binding"]
    if binding is None:
        return
    for index, row in enumerate(binding["files"]):
        if not re.fullmatch(r"[0-9a-f]{64}", row["sha256"]):
            context.add("invalid_hash", f"source_binding.files[{index}].sha256", domain=COMPATIBILITY)
    if context.project is None:
        context.add("source_files_unchecked", "source_binding.files", "No project folder was given.")
        return
    for row in binding["files"]:
        state = context.project.source_state(row["path"], row["sha256"])
        if state == project_files.MISSING:
            context.add("source_missing", "source_binding.files", row["path"], related=(row["path"],))
        elif state == project_files.MODIFIED:
            context.add("source_changed", "source_binding.files",
                        f"{row['path']} changed in the project since this document was derived from it",
                        related=(row["path"],))
