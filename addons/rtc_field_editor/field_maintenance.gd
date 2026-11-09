@tool
extends RefCounted

const Placement := preload("placement.gd")

static func duplicates(root: Node2D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var seen: Dictionary[String, Node] = {}
	var markers := root.find_children("*", "Marker2D", true, false)
	# ESCAPE owns the interaction id_group when it collides with a gather.
	for node in markers:
		if node is RegionPoint:
			_record(result, seen, node, "point_id", "escape" if node.kind == RegionPoint.Kind.ESCAPE else "entry")
	for node in markers:
		if node is FieldEnemySpawnPoint:
			_record(result, seen, node, "spawn_id", "enemy")
		elif node is FieldGatherPoint:
			_record(result, seen, node, "interaction_id", "escape")
	return result

static func _record(result: Array[Dictionary], seen: Dictionary[String, Node], node: Node,
		property: String, id_group: String) -> void:
	var id: StringName = node.get(property)
	if id.is_empty():
		return
	var key := "%s:%s" % [id_group, id]
	if seen.has(key):
		result.append({"first": seen[key], "node": node, "property": property, "id": id})
	else:
		seen[key] = node

static func repair(root: Node2D, undo: EditorUndoRedoManager) -> int:
	var repairs: Array[Dictionary] = []
	var reserved: Dictionary[StringName, bool] = {}
	for conflict in duplicates(root):
		var node: Node = conflict.node
		if node.owner != root or not (node is FieldEnemySpawnPoint or node is FieldGatherPoint):
			continue
		var id := Placement._unique_id(root, String(conflict.id), reserved)
		reserved[id] = true
		repairs.append({"node": node, "property": conflict.property, "old": conflict.id, "new": id})
	if repairs.is_empty():
		return 0
	undo.create_action("Reissue duplicate field IDs", UndoRedo.MERGE_DISABLE, root)
	for item in repairs:
		undo.add_do_property(item.node, item.property, item.new)
		undo.add_undo_property(item.node, item.property, item.old)
	undo.commit_action()
	return repairs.size()

static func sync_plan(root: Node2D, regions: Array[RegionDefinition], catalog: RefCounted) -> Dictionary:
	if regions.size() != 1:
		return {"error": "Expected one RegionDefinition for this scene; found %d." % regions.size()}
	var region := regions[0]
	var entries: Array[StringName] = []
	var escapes: Array[StringName] = []
	var points: Array[RegionPoint] = []
	RegionPoint.collect(root, points)
	for point in points:
		var ids := entries if point.kind == RegionPoint.Kind.ENTRY else escapes
		if point.point_id.is_empty() or ids.has(point.point_id):
			return {"error": "Empty or duplicate RegionPoint ID at %s." % root.get_path_to(point)}
		ids.append(point.point_id)
	var proposed := region.duplicate() as RegionDefinition
	proposed.entry_point_ids = entries
	proposed.escape_point_ids = escapes
	var errors := RegionDefinition.validate_field_nodes(proposed, root, catalog)
	if not errors.is_empty():
		return {"error": "\n".join(errors)}
	for definition in catalog.definitions.values():
		if definition is SettlementExitDefinition and region.id in definition.connected_region_ids and not definition.entry_point_id in entries:
			return {"error": "Entry %s is referenced by settlement exit %s." % [definition.entry_point_id, definition.id]}
		if definition is GameStartDefinition:
			for id in region.escape_point_ids:
				if id in definition.discovered_escape_points and not id in escapes:
					return {"error": "Escape %s is referenced by game start %s." % [id, definition.id]}
		if definition is QuestDefinition:
			for objective in definition.objectives:
				if objective != null and objective.type == QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT and objective.target_id in region.escape_point_ids and not objective.target_id in escapes:
					return {"error": "Escape %s is referenced by quest %s." % [objective.target_id, definition.id]}
	var changes := PackedStringArray()
	for spec in [["ENTRY", region.entry_point_ids, entries], ["ESCAPE", region.escape_point_ids, escapes]]:
		for id in spec[1]:
			if not id in spec[2]:
				changes.append("Remove %s %s" % [spec[0], id])
		for id in spec[2]:
			if not id in spec[1]:
				changes.append("Add %s %s" % [spec[0], id])
	# Preserve declaration order for unchanged IDs. The first entry is used as a default.
	return {"region": region, "entries": _preserve_order(region.entry_point_ids, entries),
		"escapes": _preserve_order(region.escape_point_ids, escapes), "changes": changes}

static func _preserve_order(old: Array[StringName], current: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for id in old + current:
		if id in current and not id in result:
			result.append(id)
	return result

func write_points(region: RegionDefinition, entries: Array[StringName], escapes: Array[StringName]) -> Error:
	var previous_entries := region.entry_point_ids
	var previous_escapes := region.escape_point_ids
	region.entry_point_ids = entries
	region.escape_point_ids = escapes
	var error := ResourceSaver.save(region, region.resource_path)
	if error != OK:
		region.entry_point_ids = previous_entries
		region.escape_point_ids = previous_escapes
		push_error("Cannot save field point declarations: %s (%s)" % [region.resource_path, error_string(error)])
	else:
		region.emit_changed()
	return error
