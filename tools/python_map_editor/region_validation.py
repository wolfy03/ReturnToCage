"""Pure Python checks for a map draft. Physical clearance is evaluated separately."""

from collections import Counter, defaultdict
from dataclasses import dataclass

from objects import rotate
from terrain_atlas import BUILTIN_ROOT, atlas_error
from region_index import INDEXED, INVALID, MISSING, MODIFIED

PASS = "PASS"
WARNING = "WARNING"
FAIL = "FAIL"
NOT_EVALUATED = "NOT EVALUATED"
STATIC = "static"
EXTERNAL = "external"
RUNTIME = "runtime"
PHYSICS = "physics"


def summarize(states):
    states = set(states)
    return next((status for status in (FAIL, WARNING, NOT_EVALUATED) if status in states),
                PASS if states else NOT_EVALUATED)


@dataclass(frozen=True, slots=True)
class Finding:
    status: str
    code: str
    detail: str = ""
    target: str = ""
    connection: int | None = None
    domain: str = STATIC


def _asset_exists(root, path):
    try:
        target = (root / path).resolve(strict=True)
        return target.is_relative_to(root) and target.is_file()
    except (OSError, RuntimeError):
        return False


def validate_region(document, index=None, project=None):
    index = index or {}
    findings = []

    def add(status, code, detail="", target="", connection=None, domain=STATIC):
        findings.append(Finding(status, code, detail, target, connection, domain))

    def in_bounds(position):
        x, y = position
        return 0 <= x <= document.width and 0 <= y <= document.height

    if not document.display_name.strip():
        add(WARNING, "display_name_missing")
    texture_checks = {}
    terrain_checks = {}
    for obj in document.objects:
        if document.source is None and not in_bounds(obj.position):
            add(WARNING, "outside_bounds", obj.id, f"object:{obj.id}")
        surface = obj.properties.terrain
        if surface is not None:
            if surface not in terrain_checks:
                terrain_checks[surface] = atlas_error(project or BUILTIN_ROOT, surface)
            if terrain_checks[surface]:
                add(FAIL, "terrain_missing", terrain_checks[surface], f"object:{obj.id}")
        path = obj.properties.texture_path
        if path and path not in texture_checks:
            texture_checks[path] = project is not None and _asset_exists(project, path)
            if not texture_checks[path]:
                add(FAIL if project else NOT_EVALUATED, "texture_reference", path, f"object:{obj.id}",
                    domain=STATIC if project else RUNTIME)

    design = document.design
    if design is None:
        add(NOT_EVALUATED, "region_design_unavailable")
    else:
        point_counts = Counter((point.kind, point.point_id) for point in design.region_points)
        if not any(kind == "ENTRY" for kind, _ in point_counts):
            add(FAIL, "entry_missing")
        if not any(kind == "ESCAPE" for kind, _ in point_counts):
            add(WARNING, "escape_missing")  # RegionDefinition permits an empty ESCAPE list.
        for point in design.region_points:
            target = f"marker:{point.id}"
            if point_counts[point.kind, point.point_id] > 1:
                add(FAIL, "duplicate_point", f"{point.kind} · {point.point_id}", target)
            if not in_bounds(point.position):
                add(FAIL, "outside_bounds", point.point_id, target)

        by_exit = defaultdict(set)
        routes = Counter((link.exit_id, link.region_id) for link in design.connections)
        external_entries = {key: Counter(row.current_entries) for key, row in index.items()
                            if row.current_entries is not None}
        for link in design.connections:
            by_exit[link.exit_id].add(link.entry_id)
        for offset, link in enumerate(design.connections):
            detail = f"{link.exit_id} → {link.region_id} / {link.entry_id}"
            source_count = point_counts["ESCAPE", link.exit_id]
            if source_count != 1:
                add(FAIL, "source_exit_missing" if source_count == 0 else "source_exit_ambiguous",
                    detail, connection=offset)
            if routes[link.exit_id, link.region_id] > 1:
                add(FAIL, "duplicate_connection", detail, connection=offset)
            if len(by_exit[link.exit_id]) > 1:
                add(FAIL, "shared_entry_conflict", detail, connection=offset)
            if link.region_id == document.region_id:
                if point_counts["ENTRY", link.entry_id] != 1:
                    add(FAIL, "destination_entry_invalid", detail, connection=offset)
                continue
            row = index.get(link.region_id)
            if row is None or (row.state == INDEXED and row.entries is None):
                add(NOT_EVALUATED, "destination_not_indexed", detail, connection=offset, domain=EXTERNAL)
            elif row.state != INDEXED:
                status, code = {MODIFIED: (NOT_EVALUATED, "destination_modified"),
                                MISSING: (FAIL, "destination_missing"),
                                INVALID: (FAIL, "destination_invalid")}[row.state]
                add(status, code, f"{detail} · {row.path}", connection=offset, domain=EXTERNAL)
            elif external_entries[link.region_id][link.entry_id] != 1:
                add(FAIL, "destination_entry_invalid", detail, connection=offset, domain=EXTERNAL)
            else:
                add(PASS, "destination_verified", detail, connection=offset, domain=EXTERNAL)

        platforms = [obj for obj in document.objects if obj.type == "platform"]
        slots = Counter(spawn.spawn_index for spawn in design.spawn_points)
        positions = Counter(spawn.position for spawn in design.spawn_points)
        if not slots:
            add(FAIL, "spawn_missing")
        elif len(slots) < 4:
            add(WARNING, "spawn_capacity", f"{len(slots)} / 4")
        for spawn in design.spawn_points:
            target = f"marker:{spawn.id}"
            if slots[spawn.spawn_index] > 1:
                add(FAIL, "duplicate_slot", str(spawn.spawn_index + 1), target)
            if not in_bounds(spawn.position):
                add(FAIL, "outside_bounds", spawn.id, target)
            if positions[spawn.position] > 1:
                add(WARNING, "coincident_spawn", spawn.id, target)
            if slots[spawn.spawn_index] == 1:
                for obj in platforms:
                    delta = spawn.position[0] - obj.position[0], spawn.position[1] - obj.position[1]
                    x, y = rotate(delta, -obj.rotation)
                    if abs(x) < obj.size[0] / 2 and abs(y) < obj.size[1] / 2:
                        add(WARNING, "spawn_center_overlap", obj.id, target)
                        break

        env = design.environment
        if env.path:
            if project and not _asset_exists(project, env.path.removeprefix("res://")):
                add(FAIL, "environment_reference", env.path)
            else:
                if project is None:
                    add(NOT_EVALUATED, "environment_reference_unchecked", env.path, domain=RUNTIME)
                add(NOT_EVALUATED, "environment_resource_type", env.path, domain=RUNTIME)
        if design.template_ladder is not None:
            if not in_bounds(design.template_ladder):
                add(FAIL, "outside_bounds", "ladder_default")
            add(NOT_EVALUATED, "template_ladder_support", domain=PHYSICS)

    if not any(item.domain == STATIC for item in findings):
        add(PASS, "document_structure_valid")
    if not any(item.domain == EXTERNAL for item in findings):
        add(PASS, "no_external_connections", domain=EXTERNAL)
    add(NOT_EVALUATED, "content_registry_check", domain=RUNTIME)
    add(NOT_EVALUATED, "physics_clearance_check", domain=PHYSICS)
    return findings
