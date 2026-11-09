@tool
extends RefCounted

const Placement := preload("placement.gd")

var recovery_pending := false
var _reversing := false

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

const STAGE_DIR := "res://.godot/rtc_field_sync"

static func stage_path(extension: String) -> String:
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(STAGE_DIR)) != OK:
		return ""
	return STAGE_DIR.path_join("%d.%s" % [Time.get_ticks_usec(), extension])

static func read_only(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	if OS.get_name() == "Windows":
		return FileAccess.get_read_only_attribute(path)
	return (FileAccess.get_unix_permissions(path) & 0x92) == 0

static func discard(path: String) -> void:
	if not path.is_empty() and FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

static func replace_file(staged: String, destination: String) -> Error:
	if read_only(destination):
		return ERR_FILE_NO_PERMISSION
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(staged), ProjectSettings.globalize_path(destination))

func prepare_points(region: RegionDefinition, entries: Array[StringName], escapes: Array[StringName]) -> Dictionary:
	var destination := region.resource_path
	if destination.is_empty() or not FileAccess.file_exists(destination):
		return {"error": ERR_FILE_NOT_FOUND}
	if read_only(destination):
		return {"error": ERR_FILE_NO_PERMISSION}
	var path := stage_path(destination.get_extension())
	if path.is_empty():
		return {"error": ERR_CANT_CREATE}
	var copy := region.duplicate() as RegionDefinition
	copy.entry_point_ids = entries
	copy.escape_point_ids = escapes
	var error := ResourceSaver.save(copy, path)
	var uid := ResourceLoader.get_resource_uid(destination)
	if error == OK and uid != ResourceUID.INVALID_ID:
		error = ResourceSaver.set_uid(path, uid)
	if error != OK:
		discard(path)
	return {"error": error, "path": path}

func publish_points(region: RegionDefinition, entries: Array[StringName], escapes: Array[StringName], staged: String) -> Error:
	var error := replace_file(staged, region.resource_path)
	discard(staged)
	if error == OK:
		region.entry_point_ids = entries
		region.escape_point_ids = escapes
		region.emit_changed()
	return error

func write_points(region: RegionDefinition, entries: Array[StringName], escapes: Array[StringName]) -> Error:
	var prepared := prepare_points(region, entries, escapes)
	if prepared.error != OK:
		return prepared.error
	return publish_points(region, entries, escapes, prepared.path)


func write_history(region: RegionDefinition, entries: Array[StringName], escapes: Array[StringName],
		undo: EditorUndoRedoManager, history_id: int, undoing: bool, notice: Callable) -> void:
	if _reversing:
		return
	var error := write_points(region, entries, escapes)
	if error == OK:
		_report(notice, "Saved %s." % region.resource_path)
		return
	var history := undo.get_history_undo_redo(history_id)
	var action := history.get_current_action() - (1 if undoing else 0)
	var version := history.get_version() + (-1 if undoing else 1)
	recovery_pending = true
	var message := "RegionDefinition %s failed: %s. File and resource unchanged." % ["undo" if undoing else "redo", error_string(error)]
	_restore_cursor.call_deferred(undo, history_id, action, version, undoing, notice, message)

func _restore_cursor(undo: EditorUndoRedoManager, history_id: int, action: int, version: int,
		undoing: bool, notice: Callable, message: String) -> void:
	recovery_pending = false
	if not is_instance_valid(undo):
		return
	var history := undo.get_history_undo_redo(history_id)
	# Godot advances the cursor even when a method returns a file error.
	# Reverse only our own transition once the engine finishes dispatching it.
	if history == null or history.get_current_action() != action or history.get_version() != version:
		_report(notice, message + " History changed before recovery; review and sync again.", true)
		return
	_reversing = true
	var recovered := history.redo() if undoing else history.undo()
	_reversing = false
	_report(notice, message + (" History restored; fix the file and retry." if recovered else " Review and sync again."), true)

static func _report(notice: Callable, message: String, failed: bool = false) -> void:
	if notice.is_valid():
		notice.call(message)
	elif failed:
		push_warning(message)
