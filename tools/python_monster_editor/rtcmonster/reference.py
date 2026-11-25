"""Print the field reference of Schema V1 as Markdown: ``python -m rtcmonster.reference``.

docs/monster_editor_schema_v1.md embeds this output, and a test fails when the
two drift apart.
"""

from .modules import CONDITIONS, EVENTS, MODULES, RESERVED_MODULES
from .schema import CONDITION, DOCUMENT, EVENT, SHAPE, StateNode
from .spec import CONTRACT, Arr, Map, Obj, Opt


def _cell(value):
    if value is None:
        return "null"
    if value == "":
        return '""'
    if isinstance(value, bool):
        return "true" if value else "false"
    return str(value).replace("|", "\\|")


def _plain(value):
    return str(value or "").replace("|", "\\|")


def _row(path, node, support):
    info = node.describe()
    required = "required" if node.required else _cell(info.get("default"))
    return (f"| `{path}` | {_plain(info['type'])} | {required} | {_plain(info.get('range'))} "
            f"| {_plain(info.get('unit'))} | {support} | {node.doc} |")


def _rows(node, path, inherited=CONTRACT):
    """A container's support level applies to every field below it that does not state its own."""
    if isinstance(node, StateNode):
        node = node._base
    support = node.support if node.support != CONTRACT else inherited
    if isinstance(node, Obj):
        for key, child in node.fields.items():
            yield from _rows(child, f"{path}.{key}" if path else key, support)
        return
    yield _row(path, node, support)
    inner = node.node if isinstance(node, Opt) else node
    if isinstance(inner, (Arr, Map)) and isinstance(inner.item, (Obj, StateNode)):
        yield from _rows(inner.item, f"{path}[]" if isinstance(inner, Arr) else f"{path}.*", support)


HEADER = "| Field | Type | Default | Range | Unit | Support | Meaning |\n|---|---|---|---|---|---|---|"


def _params(params):
    rows = []
    for key, node in params.items():
        info = node.describe()
        rows.append(f"`{key}` {_cell(info['type'])}"
                    + ("" if node.required else f" = {_cell(info.get('default'))}")
                    + (f" {_plain(info['range'])}" if info.get("range") else "")
                    + (f" {info['unit']}" if info.get("unit") else ""))
    return "<br>".join(rows) or "–"


def fields():
    return "\n".join([HEADER, *_rows(DOCUMENT, "")])


def shapes():
    return "\n".join(["| Shape | Fields |", "|---|---|",
                      *(f"| `{name}` | {_params(fields_)} |" for name, fields_ in SHAPE.variants.items())])


def modules():
    lines = ["| Module | Category | Parameters | Completes | Can fail | Replicated state | Clip roles | Legacy equivalent "
             "| Support |", "|---|---|---|---|---|---|---|---|---|"]
    for module in MODULES.values():
        roles = ", ".join(module.required_roles) + (
            f" (optional: {', '.join(module.optional_roles)})" if module.optional_roles else "")
        lines.append(f"| `{module.id}` | {module.category} | {_params(module.params)} "
                     f"| {'yes' if module.completes else 'no'} | {'yes' if module.can_fail else 'no'} "
                     f"| {module.snapshot} | {roles or '–'} | {module.legacy or '–'} | {module.support} |")
    lines.append("")
    lines.append("Reserved module IDs (rejected by validation until they get a contract): "
                 + ", ".join(f"`{name}`" for name in RESERVED_MODULES) + ".")
    return "\n".join(lines)


def conditions():
    leaf = CONDITION._leaf
    lines = ["| Condition | Parameters | Meaning | Legacy equivalent | Support |", "|---|---|---|---|---|"]
    for name, entry in CONDITIONS.items():
        lines.append(f"| `{name}` | {_params(leaf.variants[name])} | {entry.summary} | {entry.legacy or '–'} "
                     f"| {entry.support} |")
    return "\n".join(lines)


def events():
    lines = ["| Event | Side | Parameters | Meaning | Legacy equivalent | Support |", "|---|---|---|---|---|---|"]
    for name, entry in EVENTS.items():
        lines.append(f"| `{name}` | {entry.side} | {_params(EVENT.variants[name])} | {entry.summary} "
                     f"| {entry.legacy or '–'} | {entry.support} |")
    return "\n".join(lines)


SECTIONS = {"fields": fields, "shapes": shapes, "modules": modules, "conditions": conditions, "events": events}


def render(name):
    return f"<!-- generated:{name} -->\n{SECTIONS[name]()}\n<!-- /generated:{name} -->"


if __name__ == "__main__":
    import sys

    sys.stdout.reconfigure(encoding="utf-8")
    print("\n\n".join(render(name) for name in SECTIONS))
