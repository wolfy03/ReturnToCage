extends RefCounted

const Contract := preload("res://tools/map_bridge/scene_contract.gd")
const POINT := preload("res://world/region_point.gd")
const SPAWN := preload("res://world/multiplayer/player_spawn_point.gd")
const ENEMY := preload("res://world/adventure/field_enemy_spawn_point.gd")
const Placement := preload("res://addons/rtc_field_editor/placement.gd")
const TEMPLATE_LADDER := &"rtc_map_template_ladder"

class ContentView extends RefCounted:
	func get_definition(id: StringName) -> ContentDefinition:
		return ContentRegistry.get_definition(id)

## enemies: Schema V6. Only a request that manages enemy spawns inventories them,
## so the identity set of an older draft stays exactly what it was.
static func inventory(root: Node2D, region: RegionDefinition, enemies: bool = false) -> Dictionary:
	var bindings := {}
	var design := {"region_points": [], "spawn_points": [], "connections": [], "template_ladder": null,
		"environment": {"path": region.environment_path, "uid": Contract.uid(region.environment_path) if not region.environment_path.is_empty() else "",
			"loading_color": "#" + region.environment_loading_color.to_html()}}
	if enemies:
		design.enemy_spawns = []
	for node: Node2D in root.find_children("*", "Marker2D", true, false):
		if not node is RegionPoint and not node is PlayerSpawnPoint and not (enemies and node is FieldEnemySpawnPoint):
			continue
		var parent := node.get_parent() as Node2D
		if node.owner != root or parent == null or node.top_level or not node.global_transform.is_finite() \
				or is_zero_approx(parent.global_transform.determinant()):
			return {"error": "UNSUPPORTED_TRANSFORM: marker %s cannot be edited losslessly" % root.get_path_to(node)}
		var key := Contract.identity(root, node, String(region.id))
		if bindings.has(key):
			return {"error": "INVALID_DOCUMENT: duplicate marker identity %s" % key}
		bindings[key] = {"path": String(root.get_path_to(node)), "parent": String(root.get_path_to(parent)),
			"local_transform": Contract.affine(node.transform), "world_transform": Contract.affine(node.global_transform),
			"collision": {}}
		var row := {"id": key, "position": Contract.vector(node.global_position)}
		if node is RegionPoint:
			row.merge({"kind": "ENTRY" if node.kind == RegionPoint.Kind.ENTRY else "ESCAPE", "point_id": String(node.point_id),
				"requires_landing": node.requires_landing})
			design.region_points.append(row)
		elif node is FieldEnemySpawnPoint:
			row.merge({"spawn_id": String(node.spawn_id), "enemy_id": String(node.enemy_id), "enabled": node.enabled})
			design.enemy_spawns.append(row)
		else:
			row.spawn_index = node.spawn_index
			design.spawn_points.append(row)
	for node: Node2D in root.find_children("*", "Area2D", true, false):
		if not node.has_meta(TEMPLATE_LADDER):
			continue
		if design.template_ladder != null or not node is ClimbableArea2D or node.definition == null \
				or node.definition.id != &"ladder_default" or node.owner != root:
			return {"error": "UNSUPPORTED_NODE: invalid template ladder metadata"}
		design.template_ladder = Contract.vector(node.global_position)
	return {"design": design, "bindings": bindings, "definition_state": Contract.storage(region, root)}

static func _point_id(value: Variant) -> bool:
	return value is String and RegEx.create_from_string("^[a-z][a-z0-9_]{0,63}$").search(value) != null

static func _position(value: Variant) -> bool:
	return value is Array and value.size() == 2 and value.all(func(axis: Variant) -> bool:
		return Contract._number_in(axis, -Contract.MAX_SIZE, Contract.MAX_SIZE))

static func _reference_issue(region: RegionDefinition, point: Dictionary) -> String:
	var key := StringName(point.point_id)
	for definition in ContentRegistry.all_definitions():
		if point.kind == "ENTRY" and definition is SettlementExitDefinition:
			if region.id in definition.connected_region_ids and key == definition.entry_point_id:
				return "UNSUPPORTED_NODE: ENTRY %s is referenced by settlement exit %s" % [key, definition.id]
		elif point.kind == "ESCAPE":
			if definition is GameStartDefinition and key in definition.discovered_escape_points:
				return "UNSUPPORTED_NODE: ESCAPE %s is referenced by %s" % [key, definition.id]
			if definition is QuestDefinition:
				for objective in definition.objectives:
					if objective != null and objective.type == QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT and objective.target_id == key:
						return "UNSUPPORTED_NODE: ESCAPE %s is referenced by quest %s" % [key, definition.id]
	return ""

static func _ordered_ids(previous: Array[StringName], proposed: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for key in previous:
		if key in proposed:
			result.append(key)
	for key in proposed:
		if key not in previous:
			result.append(key)
	return result

static func _environment(region: RegionDefinition, desired: Variant, previous: Dictionary) -> String:
	if not desired is Dictionary or not desired.get("path") is String or not desired.get("uid") is String \
			or not desired.get("loading_color") is String or not desired.loading_color.begins_with("#") \
			or desired.loading_color.length() not in [7, 9] or not Color.html_is_valid(desired.loading_color):
		return "INVALID_DOCUMENT: invalid environment data"
	var path: String = desired.path
	if not path.is_empty():
		if not path.begins_with("res://") or path != path.simplify_path() or not path.ends_with(".tres") \
				or not ResourceLoader.exists(path) or not ResourceLoader.load(path) is EnvironmentDefinition:
			return "RESOURCE_MISSING: EnvironmentDefinition %s" % path
		if not desired.uid.is_empty():
			var uid := ResourceUID.text_to_id(desired.uid)
			if Contract.uid(path) != desired.uid or not ResourceUID.has_id(uid) or ResourceUID.get_id_path(uid) != path:
				return "UID_CONFLICT: environment %s" % path
	elif not desired.uid.is_empty():
		return "INVALID_DOCUMENT: environment UID without a path"
	region.environment_path = path
	if desired.loading_color != previous.loading_color:
		region.environment_loading_color = Color.html(desired.loading_color)
	return ""

static func apply(root: Node2D, region: RegionDefinition, original: Dictionary, design: Variant, links: Array,
		new_region: bool = false) -> String:
	if not design is Dictionary or not design.get("connections") is Array or not design.connections.is_empty():
		return "UNSUPPORTED_NODE: ESCAPE routes do not map to a runtime SettlementExitDefinition"
	var environment_issue := _environment(region, design.get("environment"), original.design.environment)
	if not environment_issue.is_empty():
		return environment_issue
	var requested_ladder: Variant = design.get("template_ladder")
	if new_region and requested_ladder != null:
		if not _position(requested_ladder):
			return "INVALID_DOCUMENT: invalid template ladder position"
		var group := root.get_node("Climbables") as Node2D
		var ladder := Placement.make_node({"kind": "climb", "id": &"ladder_default"}, root, ContentView.new()) as ClimbableArea2D
		if ladder == null:
			return "RESOURCE_MISSING: official ladder_default"
		ladder.name = "TemplateLadder"
		ladder.set_meta(TEMPLATE_LADDER, true)
		group.add_child(ladder)
		ladder.owner = root
		ladder.position = group.to_local(Vector2(requested_ladder[0], requested_ladder[1]))
		ladder.top_marker.position.y = -37
		for child in ladder.get_children():
			child.owner = root
	elif requested_ladder != original.design.template_ladder:
		return "UNSUPPORTED_NODE: linked template ladder changes are unavailable"
	var seen := {}
	var entries: Array[StringName] = []
	var escapes: Array[StringName] = []
	var slots: Array[int] = []
	for field: String in ["region_points", "spawn_points"]:
		var rows: Variant = design.get(field)
		if not rows is Array or rows.size() > 4096:
			return "INVALID_DOCUMENT: invalid marker list"
		var previous := {}
		for item: Dictionary in original.design[field]:
			previous[item.id] = item
		var point := field == "region_points"
		for row: Variant in rows:
			if not row is Dictionary or not _point_id(row.get("id")) or seen.has(row.id) or not _position(row.get("position")):
				return "INVALID_DOCUMENT: invalid or duplicate marker"
			seen[row.id] = true
			if point:
				if not _point_id(row.get("point_id")) or row.get("kind") not in ["ENTRY", "ESCAPE"] or not row.get("requires_landing") is bool:
					return "INVALID_DOCUMENT: invalid RegionPoint"
				var ids := entries if row.kind == "ENTRY" else escapes
				if StringName(row.point_id) in ids:
					return "INVALID_DOCUMENT: duplicate %s %s" % [row.kind, row.point_id]
				ids.append(StringName(row.point_id))
			else:
				var slot: Variant = row.get("spawn_index")
				if not Contract._number_in(slot, 0, NetworkManager.MAX_PLAYERS - 1) or slot != int(slot) or int(slot) in slots:
					return "INVALID_DOCUMENT: invalid or duplicate player spawn index"
				slots.append(int(slot))
			var before: Dictionary = previous.get(row.id, {})
			var node: Node2D
			if before.is_empty():
				if original.bindings.has(row.id):
					return "INVALID_DOCUMENT: marker type changed for %s" % row.id
				var parent := root.get_node_or_null("RegionPoints") as Node2D if point else root
				if parent == null and point and not root.has_node("RegionPoints"):
					parent = Node2D.new()
					parent.name = "RegionPoints"
					root.add_child(parent)
					parent.owner = root
				var name := NodePath("RTC_" + String(row.id))
				if parent == null or (parent != root and (parent.owner != root or parent.get_script() != null)) \
						or parent.has_node(name) or is_zero_approx(parent.global_transform.determinant()):
					return "UNSUPPORTED_NODE: marker placement parent or name collision %s" % name
				node = POINT.new() if point else SPAWN.new()
				node.name = String(name)
				node.set_meta(Contract.EDIT_ID, row.id)
				parent.add_child(node)
				node.owner = root
			else:
				node = root.get_node(NodePath(original.bindings[row.id].path))
				if node.get_script() != (POINT if point else SPAWN):
					if not before == row:
						return "UNSUPPORTED_NODE: cannot edit custom marker %s" % row.id
					continue
				if point and (row.kind != before.kind or row.point_id != before.point_id):
					var issue := _reference_issue(region, before)
					if not issue.is_empty():
						return issue
			var position := Vector2(row.position[0], row.position[1])
			if before.is_empty() or not node.global_position.is_equal_approx(position):
				node.position = (node.get_parent() as Node2D).to_local(position)
			if node is RegionPoint:
				node.kind = RegionPoint.Kind.ENTRY if row.kind == "ENTRY" else RegionPoint.Kind.ESCAPE
				node.point_id = StringName(row.point_id)
				node.requires_landing = row.requires_landing
			else:
				node.spawn_index = int(row.spawn_index)
		for key: String in previous:
			if seen.has(key):
				continue
			var victim := root.get_node(NodePath(original.bindings[key].path))
			if victim.get_child_count() or victim.get_script() != (POINT if point else SPAWN):
				return "UNSUPPORTED_NODE: cannot remove custom marker %s" % key
			var issue := Contract.removal_issue(root, victim, links)
			if issue.is_empty() and point:
				issue = _reference_issue(region, previous[key])
			if not issue.is_empty():
				return issue
			victim.free()
	if entries.is_empty() or slots.is_empty():
		return "INVALID_DOCUMENT: an ENTRY and a player spawn slot are required"
	var enemy_issue := _apply_enemy_spawns(root, region, original, design.get("enemy_spawns"), links, seen)
	if not enemy_issue.is_empty():
		return enemy_issue
	region.entry_point_ids = _ordered_ids(region.entry_point_ids, entries)
	region.escape_point_ids = _ordered_ids(region.escape_point_ids, escapes)
	return ""

## null leaves every FieldEnemySpawnPoint untouched (a V1-V5 draft). An Array is
## the complete authored list: missing markers are removed, new ones are created.
static func _apply_enemy_spawns(root: Node2D, region: RegionDefinition, original: Dictionary, rows: Variant,
		links: Array, seen: Dictionary) -> String:
	if rows == null:
		return ""
	if not rows is Array or rows.size() > 4096 or not original.design.has("enemy_spawns"):
		return "INVALID_DOCUMENT: invalid enemy spawn list"
	var previous := {}
	var previously_used: Array[StringName] = []
	for item: Dictionary in original.design.enemy_spawns:
		previous[item.id] = item
		previously_used.append(StringName(item.enemy_id))
	var kept := {}
	var spawn_ids := {}
	var used: Array[StringName] = []
	for row: Variant in rows:
		if not row is Dictionary or not _point_id(row.get("id")) or seen.has(row.id) or not _position(row.get("position")):
			return "INVALID_DOCUMENT: invalid or duplicate marker"
		seen[row.id] = true
		kept[row.id] = true
		if not _point_id(row.get("spawn_id")) or not _point_id(row.get("enemy_id")) or not row.get("enabled") is bool:
			return "INVALID_DOCUMENT: invalid enemy spawn %s" % row.id
		if spawn_ids.has(row.spawn_id):
			return "INVALID_DOCUMENT: duplicate enemy spawn ID %s" % row.spawn_id
		spawn_ids[row.spawn_id] = true
		var enemy := StringName(row.enemy_id)
		var before: Dictionary = previous.get(row.id, {})
		var node: Node2D
		if before.is_empty():
			if original.bindings.has(row.id):
				return "INVALID_DOCUMENT: marker type changed for %s" % row.id
			var parent := root.get_node_or_null("SpawnPoints") as Node2D
			if parent == null and not root.has_node("SpawnPoints"):
				parent = Node2D.new()
				parent.name = "SpawnPoints"
				root.add_child(parent)
				parent.owner = root
			var name := NodePath("RTC_" + String(row.id))
			if parent == null or parent.owner != root or parent.get_script() != null or parent.has_node(name) \
					or is_zero_approx(parent.global_transform.determinant()):
				return "UNSUPPORTED_NODE: marker placement parent or name collision %s" % name
			node = ENEMY.new()
			node.name = String(name)
			node.set_meta(Contract.EDIT_ID, row.id)
			parent.add_child(node)
			node.owner = root
		else:
			node = root.get_node(NodePath(original.bindings[row.id].path))
			if node.get_script() != ENEMY:
				if not before == row:
					return "UNSUPPORTED_NODE: cannot edit custom marker %s" % row.id
				if enemy not in used:
					used.append(enemy)
				continue
		if (before.is_empty() or before.enemy_id != row.enemy_id) and not ContentRegistry.get_definition(enemy) is EnemyDefinition:
			return "RESOURCE_MISSING: EnemyDefinition %s" % enemy
		if enemy not in used:
			used.append(enemy)
		var position := Vector2(row.position[0], row.position[1])
		if before.is_empty() or not node.global_position.is_equal_approx(position):
			node.position = (node.get_parent() as Node2D).to_local(position)
		if before.is_empty() or before.spawn_id != row.spawn_id:
			node.spawn_id = StringName(row.spawn_id)
		if before.is_empty() or before.enemy_id != row.enemy_id:
			node.enemy_id = enemy
		if node.enabled != row.enabled:
			node.enabled = row.enabled
	for key: String in previous:
		if kept.has(key):
			continue
		var victim := root.get_node(NodePath(original.bindings[key].path))
		if victim.get_child_count() or victim.get_script() != ENEMY:
			return "UNSUPPORTED_NODE: cannot remove custom marker %s" % key
		var issue := Contract.removal_issue(root, victim, links)
		if not issue.is_empty():
			return issue
		victim.free()
	# Keep the declared order, and keep an enemy the region declares without a
	# marker. Drop only what the edited markers no longer use; append new kinds.
	var declared: Array[StringName] = []
	for key in region.enemy_ids:
		if key in used or key not in previously_used:
			declared.append(key)
	for key in used:
		if key not in declared:
			declared.append(key)
	if declared != region.enemy_ids:
		region.enemy_ids = declared
	return ""
