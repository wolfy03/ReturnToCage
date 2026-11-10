@tool
extends RefCounted

static func region_for(root: Node2D, catalog: RefCounted) -> RegionDefinition:
	if root == null:
		return null
	var found: RegionDefinition
	for region in catalog.regions:
		if region.scene_path != root.scene_file_path:
			continue
		if found != null or catalog.duplicates.has(region.id):
			return null
		found = region
	return found

static func connections(exit: SettlementExitDefinition, region: RegionDefinition, entry: StringName, add: bool, catalog: RefCounted, root: Node2D) -> Dictionary:
	if catalog.get_definition(exit.id) != exit or catalog.get_definition(region.id) != region:
		return {"error": "Missing or duplicate exit/region ID."}
	var ids := exit.connected_region_ids.duplicate()
	if add and not region.id in ids:
		ids.append(region.id)
	elif not add:
		ids.erase(region.id)
	if ids.is_empty() and not exit.development_locked:
		return {"error": "An implemented exit must retain a connected region."}
	if not add:
		entry = exit.entry_point_id
	var seen: Dictionary[StringName, bool] = {}
	for id in ids:
		var linked := catalog.get_definition(id) as RegionDefinition
		if seen.has(id) or linked == null or not linked.entry_point_ids.has(entry) or not _has_entry(linked, entry, root):
			return {"error": "Shared ENTRY '%s' must exist once in the scene and be declared by every linked region. Check '%s'." % [entry, id]}
		seen[id] = true
	for facility in exit.required_facility_levels:
		if not catalog.get_definition(facility) is FacilityDefinition or exit.required_facility_levels[facility] < 0:
			return {"error": "Invalid required facility: %s" % facility}
	return {"connected_region_ids": ids, "entry_point_id": entry}

static func _has_entry(region: RegionDefinition, id: StringName, root: Node2D) -> bool:
	if root.scene_file_path == region.scene_path and _entry_count(root, id) != 1:
		return false
	if not ResourceLoader.exists(region.scene_path, "PackedScene"):
		return false
	var packed := ResourceLoader.load(region.scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null or not packed.can_instantiate():
		return false
	var scene := packed.instantiate()
	var valid := scene.has_method("configure_server_runtime") and _entry_count(scene, id) == 1
	scene.free()
	return valid

static func _entry_count(root: Node, id: StringName) -> int:
	var points: Array[RegionPoint] = []
	RegionPoint.collect(root, points)
	var count := 0
	for point in points:
		if point.kind == RegionPoint.Kind.ENTRY and point.point_id == id:
			count += 1
	return count

static func references(point: RegionPoint, region: RegionDefinition, catalog: RefCounted) -> String:
	var ids := PackedStringArray()
	for definition in catalog.definitions.values():
		if point.kind == RegionPoint.Kind.ENTRY:
			if definition is SettlementExitDefinition and region != null and region.id in definition.connected_region_ids and definition.entry_point_id == point.point_id:
				ids.append(String(definition.id))
		elif definition is GameStartDefinition and point.point_id in definition.discovered_escape_points:
			ids.append(String(definition.id))
		elif definition is QuestDefinition:
			for objective in definition.objectives:
				if objective != null and objective.type == QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT and objective.target_id == point.point_id:
					ids.append(String(definition.id))
					break
	ids.sort()
	return ", ".join(ids) if not ids.is_empty() else "none in current content"

static func analyze(root: Node2D) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	var manager := root.get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	if manager == null:
		return results
	var player := PlayerSpawnManager.PLAYER_SCENE.instantiate()
	var collider := player.get_node("CollisionShape2D") as CollisionShape2D
	var shape := collider.shape
	var offset := collider.transform
	player.free()
	var markers: Array[Node] = root.find_children("*", "Marker2D", true, false).filter(func(node: Node) -> bool: return node is PlayerSpawnPoint)
	var terrain: Array[CollisionShape2D] = []
	for node in root.find_children("*", "CollisionShape2D", true, false):
		var collider_node := node as CollisionShape2D
		var parent := collider_node.get_parent() as PhysicsBody2D
		if parent != null and parent.collision_layer & manager.spawn_validation_collision_mask != 0 and not collider_node.disabled and collider_node.shape != null:
			terrain.append(collider_node)
	var slots: Dictionary[int, int] = {}
	for marker in markers:
		slots[marker.spawn_index] = slots.get(marker.spawn_index, 0) + 1
	var points: Array[RegionPoint] = []
	RegionPoint.collect(root, points)
	for node in markers + points:
		var marker := node as Node2D
		var transform := marker.global_transform
		var severity := "Info"
		var message := "Authored clearance and support passed"
		if not transform.is_finite() or is_zero_approx(transform.determinant()) or is_zero_approx(root.global_transform.determinant()):
			severity = "Error"
			message = "Non-finite or non-invertible transform"
		elif marker is PlayerSpawnPoint and (marker.get_parent() != root or marker.spawn_index < 0 or marker.spawn_index >= NetworkManager.MAX_PLAYERS or slots[marker.spawn_index] > 1):
			severity = "Error"
			message = "Slot must be unique, in range, and directly under the region"
		else:
			var issue := PlayerSpawnManager.authored_spawn_issue(root, root.to_local(marker.global_position), manager.clearance_radius, manager.support_distance, manager.spawn_validation_collision_mask)
			if issue == "BLOCKED" or issue == "INVALID_COLLISION_MASK":
				severity = "Error"
				message = issue
			elif not issue.is_empty():
				severity = "Warning"
				message = issue
			if shape != null and marker is PlayerSpawnPoint:
				var body := Transform2D(0, marker.global_position) * offset
				if severity == "Info":
					for obstacle in terrain:
						if shape.collide(body, obstacle.shape, obstacle.global_transform):
							severity = "Warning"
							message = "Player body overlaps authored terrain despite preflight clearance"
							break
				for other in markers:
					if other != marker and other.global_position.is_finite() and shape.collide(Transform2D(0, marker.global_position) * offset, shape, Transform2D(0, other.global_position) * offset):
						if severity != "Error":
							severity = "Warning"
							message = "Player body overlaps another authored spawn slot"
						break
		results.append({"node": marker, "severity": severity, "message": message, "radius": manager.clearance_radius, "body": shape.get_rect() if shape != null else Rect2(), "offset": offset, "at": marker.global_position})
	var valid_slots := 0
	for index in NetworkManager.MAX_PLAYERS:
		if slots.get(index, 0) == 1 and markers.any(func(node: Node) -> bool: return node.spawn_index == index and node.get_parent() == root):
			valid_slots += 1
	if valid_slots < NetworkManager.MAX_PLAYERS:
		results.append({"node": root, "severity": "Warning", "message": "%d/%d authored spawn slots" % [valid_slots, NetworkManager.MAX_PLAYERS]})
	return results
