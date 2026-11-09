@tool
extends RefCounted

const PLATFORM := preload("res://world/adventure/field_platform.tscn")

static func group_for(kind: String) -> String:
	match kind:
		"enemy", "player": return "SpawnPoints" if kind == "enemy" else ""
		"gather": return "GatherPoints"
		"entry", "escape": return "RegionPoints"
		"platform", "obstacle": return "Terrain"
		"climb": return "Climbables"
		"texture", "scene": return "Decorations"
	return ""

static func world_position(canvas: Transform2D, cursor: Vector2, interval: float) -> Vector2:
	var world := canvas.affine_inverse() * cursor
	return world.snapped(Vector2.ONE * interval) if interval > 0.0 else world

static func make_node(entry: Dictionary, root: Node2D, catalog: RefCounted, reserved: Dictionary[StringName, bool] = {}) -> Node2D:
	var id: StringName = entry.id
	match entry.kind:
		"enemy":
			if not catalog.get_definition(id) is EnemyDefinition:
				return null
			var point := FieldEnemySpawnPoint.new()
			point.enemy_id = id
			point.spawn_id = _unique_id(root, String(id) + "_spawn", reserved)
			point.name = "EnemySpawn"
			return point
		"gather":
			if not catalog.get_definition(id) is ItemDefinition:
				return null
			var point := FieldGatherPoint.new()
			point.item_id = id
			point.interaction_id = _unique_id(root, String(id) + "_gather", reserved)
			point.name = "GatherPoint"
			return point
		"entry", "escape":
			var point := RegionPoint.new()
			point.kind = RegionPoint.Kind.ENTRY if entry.kind == "entry" else RegionPoint.Kind.ESCAPE
			point.point_id = _unique_id(root, entry.kind)
			for definition in catalog.definitions.values():
				if definition is RegionDefinition and definition.scene_path == root.scene_file_path:
					var ids: Array[StringName] = definition.entry_point_ids if entry.kind == "entry" else definition.escape_point_ids
					for declared in ids:
						if not _has_point(root, declared, point.kind):
							point.point_id = declared
							break
					break
			point.name = "Entry" if entry.kind == "entry" else "Escape"
			return point
		"player":
			var used: Array[int] = []
			for child in root.get_children():
				if child is PlayerSpawnPoint:
					used.append(child.spawn_index)
			for index in 4:
				if not used.has(index):
					var point := PlayerSpawnPoint.new()
					point.spawn_index = index
					point.name = "PlayerSpawnPoint%d" % index
					return point
		"platform", "obstacle":
			var platform := PLATFORM.instantiate() as FieldPlatform
			if entry.kind == "obstacle":
				platform.name = "Obstacle"
				platform.size = Vector2(48, 96)
			return platform
		"climb":
			var definition := catalog.get_definition(id) as ClimbableDefinition
			if definition == null:
				return null
			var area := ClimbableArea2D.new()
			area.name = "Climbable"
			area.definition = definition
			area.collision_layer = 0
			area.collision_mask = 1
			var collision := CollisionShape2D.new()
			collision.name = "CollisionShape2D"
			var shape := RectangleShape2D.new()
			shape.size = Vector2(definition.alignment_tolerance * 2.0, 180)
			collision.shape = shape
			area.add_child(collision)
			for label in ["Top", "Bottom"]:
				var marker := Marker2D.new()
				marker.name = label
				marker.position.y = -80 if label == "Top" else 80
				area.add_child(marker)
				if label == "Top":
					area.top_marker = marker
				else:
					area.bottom_marker = marker
			return area
		"texture", "scene":
			if not ResourceLoader.exists(entry.path):
				return null
			var asset := ResourceLoader.load(entry.path)
			if entry.kind == "texture" and not asset is Texture2D:
				return null
			if entry.kind == "scene" and (not asset is PackedScene or not FieldDecoration.is_visual_scene(asset)):
				return null
			var decoration := FieldDecoration.new()
			decoration.name = "Decoration"
			decoration.asset_path = entry.path
			return decoration
	return null

static func _has_point(root: Node2D, id: StringName, kind: RegionPoint.Kind) -> bool:
	for marker in root.find_children("*", "Marker2D", true, false):
		if marker is RegionPoint and marker.kind == kind and marker.point_id == id:
			return true
		if kind == RegionPoint.Kind.ESCAPE and marker is FieldGatherPoint and marker.interaction_id == id:
			return true
	return false

static func _unique_id(root: Node2D, stem: String, reserved: Dictionary[StringName, bool] = {}) -> StringName:
	var used := reserved.duplicate()
	for marker in root.find_children("*", "Marker2D", true, false):
		if marker is RegionPoint:
			used[marker.point_id] = true
		elif marker is FieldGatherPoint:
			used[marker.interaction_id] = true
		elif marker is FieldEnemySpawnPoint:
			used[marker.spawn_id] = true
	var suffix := 1
	while used.has(StringName("%s_%d" % [stem, suffix])):
		suffix += 1
	return StringName("%s_%d" % [stem, suffix])
