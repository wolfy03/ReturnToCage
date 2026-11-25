"""Print the reference tables of Schema V1 as Markdown: ``python -m rtcmonster.reference``.

docs/monster_editor_schema_v1.md embeds this output, and a test fails when the
two drift apart. Every table is derived from the schema, the registry or the
finding-code declarations, so the document cannot describe something the code
does not do.
"""

from .schema import DEFAULT_SCHEMA, SHAPE, StateNode
from .spec import CAPABILITIES, CAPABILITY_STAGES, CONTRACT, Arr, Map, Obj, Opt
from .validation import CODES, DOMAINS, FAIL, NOT_EVALUATED, PASS, WARNING


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
        node = node.base
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


def fields(schema=DEFAULT_SCHEMA):
    return "\n".join([HEADER, *_rows(schema.document, "")])


def shapes(schema=DEFAULT_SCHEMA):
    return "\n".join(["| Shape | Fields |", "|---|---|",
                      *(f"| `{name}` | {_params(fields_)} |" for name, fields_ in SHAPE.variants.items())])


def modules(schema=DEFAULT_SCHEMA):
    lines = ["| Module | Category | Parameters | Completes | Can fail | Replicated state | Clip roles | Legacy equivalent "
             "| Support |", "|---|---|---|---|---|---|---|---|---|"]
    for module in schema.registry.modules.values():
        roles = ", ".join(module.required_roles) + (
            f" (optional: {', '.join(module.optional_roles)})" if module.optional_roles else "")
        lines.append(f"| `{module.id}` | {module.category} | {_params(schema.module_params(module.id))} "
                     f"| {'yes' if module.completes else 'no'} | {'yes' if module.can_fail else 'no'} "
                     f"| {module.snapshot} | {roles or '–'} | {module.legacy or '–'} | {module.support} |")
    lines.append("")
    lines.append("Reserved module IDs (rejected by validation until they get a contract): "
                 + ", ".join(f"`{name}`" for name in schema.registry.reserved_modules) + ".")
    return "\n".join(lines)


def conditions(schema=DEFAULT_SCHEMA):
    lines = ["| Condition | Parameters | Meaning | Legacy equivalent | Support |", "|---|---|---|---|---|"]
    for name, entry in schema.registry.conditions.items():
        lines.append(f"| `{name}` | {_params(schema.condition_leaf.variants[name])} | {entry.summary} "
                     f"| {entry.legacy or '–'} | {entry.support} |")
    return "\n".join(lines)


def events(schema=DEFAULT_SCHEMA):
    lines = ["| Event | Side | Parameters | Meaning | Legacy equivalent | Support |", "|---|---|---|---|---|---|"]
    for name, entry in schema.registry.events.items():
        lines.append(f"| `{name}` | {entry.side} | {_params(schema.event.variants[name])} | {entry.summary} "
                     f"| {entry.legacy or '–'} | {entry.support} |")
    return "\n".join(lines)


def capabilities(schema=DEFAULT_SCHEMA):
    lines = ["| Support | " + " | ".join(CAPABILITY_STAGES) + " |", "|---|" + "---|" * len(CAPABILITY_STAGES)]
    for support, stages in CAPABILITIES.items():
        lines.append(f"| `{support}` | " + " | ".join("yes" if stages[stage] else "no"
                                                    for stage in CAPABILITY_STAGES) + " |")
    return "\n".join(lines)


def codes(schema=DEFAULT_SCHEMA):
    lines = ["| Domain | Status | Code | Fix in | Meaning |", "|---|---|---|---|---|"]
    order = {status: index for index, status in enumerate((FAIL, WARNING, NOT_EVALUATED, PASS))}
    domains = {domain: index for index, domain in enumerate(DOMAINS)}
    for info in sorted(CODES.values(), key=lambda row: (domains.get(row.domain, -1), order[row.status], row.code)):
        lines.append(f"| {info.domain or 'by field'} | {info.status} | `{info.code}` | {info.remedy} "
                     f"| {info.summary} |")
    return "\n".join(lines)


SECTIONS = {"fields": fields, "shapes": shapes, "modules": modules, "conditions": conditions, "events": events,
            "capabilities": capabilities, "codes": codes}


def render(name, schema=DEFAULT_SCHEMA):
    return f"<!-- generated:{name} -->\n{SECTIONS[name](schema)}\n<!-- /generated:{name} -->"


def update(text):
    """Return ``text`` with every generated block replaced by the current tables."""
    import re

    for name in SECTIONS:
        block = re.compile(rf"<!-- generated:{name} -->.*?<!-- /generated:{name} -->", re.DOTALL)
        if len(block.findall(text)) != 1:
            raise ValueError(f"expected exactly one generated block for '{name}'")
        text = block.sub(lambda _match, name=name: render(name), text)
    return text


if __name__ == "__main__":
    import sys
    from pathlib import Path

    sys.stdout.reconfigure(encoding="utf-8")
    if len(sys.argv) == 3 and sys.argv[1] == "--update":
        target = Path(sys.argv[2])
        target.write_text(update(target.read_text(encoding="utf-8")), encoding="utf-8", newline="\n")
    else:
        print("\n\n".join(render(name) for name in SECTIONS))
