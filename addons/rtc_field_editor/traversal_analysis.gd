@tool
extends RefCounted

const PLAYER := preload("res://gameplay/actors/player/player.tscn")
const SHAPE_LIMIT := 128
const SURFACE_LIMIT := 64
const EDGE_LIMIT := 256
const STARTS_PER_SURFACE := 3

static func point(value: Vector2) -> Array:
	return [value.x, value.y]

static func vector(value: Array) -> Vector2:
	return Vector2(float(value[0]), float(value[1]))

static func model() -> Dictionary:
	var player := PLAYER.instantiate() as PlayerActor
	var movement := player.get_node("Movement") as MovementComponent
	var collider := player.get_node("CollisionShape2D") as CollisionShape2D
	var start := load("res://data/content/game_start/default_game_start.tres") as GameStartDefinition
	var result := {"speed": start.player_stats.get(&"move_speed", StatBlock.DEFAULT_BASE_VALUES[&"move_speed"]),
		"acceleration": movement.acceleration, "deceleration": movement.deceleration, "jump_velocity": movement.jump_velocity,
		"gravity": movement.gravity, "body": point(collider.shape.get_rect().size), "margin": player.safe_margin,
		"floor_angle": player.floor_max_angle, "mask": player.collision_mask,
		"physics_fps": ProjectSettings.get_setting("physics/common/physics_ticks_per_second", 60),
		"profile": "Fresh default_game_start; no active effects. Worker records effective actor speed."}
	player.free()
	return result

static func fingerprint(root: Node2D, region: RegionDefinition) -> String:
	var packed := PackedScene.new()
	if packed.pack(root) != OK:
		return ""
	var state := packed.get_state()
	var values: Array = []
	for index in state.get_node_count():
		values.append(str(state.get_node_path(index)))
		for property in state.get_node_property_count(index):
			values.append(str(state.get_node_property_name(index, property)))
			var value: Variant = state.get_node_property_value(index, property)
			values.append(_value_key(value))
	if region != null:
		values.append(_value_key(region))
	for path in ["res://gameplay/components/movement_component.gd", "res://gameplay/components/climbable_area_2d.gd",
		"res://gameplay/actors/player/player.tscn", "res://data/content/game_start/default_game_start.tres",
		"res://project.godot", "res://world/adventure/field_platform.gd", "res://gameplay/actors/player/player.gd",
		"res://gameplay/components/player_input_component.gd", "res://gameplay/components/interaction_target.gd",
		"res://world/adventure/escape_point_2d.gd", "res://world/multiplayer/player_spawn_manager.gd"]:
		values.append(FileAccess.get_sha256(path))
	return str(values).sha256_text()

static func _value_key(value: Variant) -> String:
	if value is Resource:
		if value is Script:
			return value.resource_path + FileAccess.get_sha256(value.resource_path)
		var properties: Array = [value.get_class(), "" if value.is_built_in() else value.resource_path]
		for property in value.get_property_list():
			if property.usage & PROPERTY_USAGE_STORAGE and property.name != "script":
				properties.append([property.name, _value_key(value.get(property.name))])
		return str(properties)
	if value is Array:
		return str(value.map(func(item: Variant) -> String: return _value_key(item)))
	return str(value)

static func extract(root: Node2D, region: RegionDefinition = null) -> Dictionary:
	var started := Time.get_ticks_msec()
	var physics := model()
	var result := {"schema": 1, "region": String(region.id) if region != null else "", "fingerprint": fingerprint(root, region), "model": physics, "surfaces": [], "edges": [],
		"climbs": [], "starts": [], "escapes": [], "routes": [], "issues": [], "partial": false, "status": "Candidate",
		"limits": {"shapes": SHAPE_LIMIT, "surfaces": SURFACE_LIMIT, "edges": EDGE_LIMIT, "starts_per_surface": STARTS_PER_SURFACE},
		"metrics": {"wall_ms": 0, "physics_ticks": 0, "attempts": 0}}
	var template := PLAYER.instantiate()
	var template_collision := template.get_node("CollisionShape2D") as CollisionShape2D
	var body_shape := template_collision.shape
	var body_offset := template_collision.transform
	template.free()
	var shapes: Array[CollisionShape2D] = []
	for node in root.find_children("*", "CollisionShape2D", true, false):
		var shape := node as CollisionShape2D
		var body := shape.get_parent()
		if body is StaticBody2D and not shape.disabled and shape.shape != null and body.collision_layer & int(physics.mask) != 0 and not _disabled(body, root) and world_transform(shape).is_finite() and not is_zero_approx(world_transform(shape).determinant()):
			shapes.append(shape)
	if shapes.size() > SHAPE_LIMIT:
		result.partial = true
		result.issues.append({"path": ".", "status": "Not Evaluated", "reason": "128-shape geometry candidate budget reached; omitted shapes still participate in isolated runtime physics"})
		shapes.resize(SHAPE_LIMIT)
	for shape in shapes:
		var body := shape.get_parent() as StaticBody2D
		var path := String(root.get_path_to(shape))
		var geometry := PlayerSpawnManager.authored_collision_shape(shape)
		var one_way: bool = body.one_way if body is FieldPlatform and shape.name == &"CollisionShape2D" else shape.one_way_collision
		var transform := world_transform(shape)
		var why := ""
		if not geometry is RectangleShape2D:
			why = "Only rectangular surfaces are extracted"
		elif not transform.is_finite() or is_zero_approx(transform.determinant()):
			why = "Invalid collision transform"
		elif absf(transform.x.y) > 0.0001 or absf(transform.y.x) > 0.0001:
			why = "Rotated/skewed rectangle surface is not evaluated"
		elif one_way and transform.y.y <= 0:
			why = "Reversed one-way direction"
		elif _disabled(body, root):
			why = "Disabled body process mode removes collision"
		elif body.get_script() != null and not body is FieldPlatform:
			why = "Custom body script can change runtime collision"
		if not why.is_empty():
			result.issues.append({"path": path, "status": "Not Evaluated", "reason": why})
			continue
		var bounds := transform * geometry.get_rect()
		var half := vector(physics.body) * 0.5
		var left: float = bounds.position.x + half.x
		var right: float = bounds.end.x - half.x
		if right <= left:
			result.issues.append({"path": path, "status": "Not Evaluated", "reason": "No full-body landing interval"})
			continue
		var count := mini(64, maxi(2, ceili((right - left) / maxf(half.x, 1.0)) + 1))
		var run_start := INF
		for index in count + 1:
			var x := lerpf(left, right, float(mini(index, count - 1)) / float(count - 1))
			var position := Vector2(x, bounds.position.y - half.y - float(physics.margin) * 2.0)
			var clear := index < count and _body_clear(position, shapes, body_shape, body_offset)
			if clear and is_inf(run_start):
				run_start = x
			if not clear and not is_inf(run_start):
				var finish := lerpf(left, right, float(index - 1) / float(count - 1))
				if finish - run_start >= half.x:
					if result.surfaces.size() >= SURFACE_LIMIT:
						result.partial = true
					else:
						result.surfaces.append({"id": result.surfaces.size(), "path": path, "body_path": String(root.get_path_to(body)),
							"left": run_start, "right": finish, "y": position.y, "top": bounds.position.y,
							"one_way": one_way, "status": "Candidate", "trace": []})
				run_start = INF
	for node in root.find_children("*", "Node2D", true, false):
		if node is CollisionPolygon2D or node is TileMapLayer:
			result.issues.append({"path": String(root.get_path_to(node)), "status": "Not Evaluated", "reason": "Polygon/tile surface extraction unsupported"})
		elif node is ClimbableArea2D:
			if node.definition == null or node.top_marker == null or node.bottom_marker == null or not node.is_ancestor_of(node.top_marker) or not node.is_ancestor_of(node.bottom_marker):
				result.issues.append({"path": String(root.get_path_to(node)), "status": "Not Evaluated", "reason": "Missing climb definition or markers"})
			elif world_transform(node.top_marker).origin.y >= world_transform(node.bottom_marker).origin.y or not node.get_children().any(func(child: Node) -> bool: return child is CollisionShape2D and child.shape != null and not child.disabled):
				result.issues.append({"path": String(root.get_path_to(node)), "status": "Not Evaluated", "reason": "Climb endpoints or active collision area are invalid"})
			else:
				result.climbs.append({"path": String(root.get_path_to(node)), "top": point(world_transform(node.top_marker).origin), "bottom": point(world_transform(node.bottom_marker).origin),
					"requires_interaction": node.definition.requires_interaction, "alignment_tolerance": node.definition.alignment_tolerance})
		elif node is RegionPoint and node.kind == RegionPoint.Kind.ESCAPE:
			result.escapes.append({"path": String(root.get_path_to(node)), "id": String(node.point_id), "position": point(world_transform(node).origin),
				"requires_landing": node.requires_landing})
	var slot_counts: Dictionary = {}
	var slots: Array[PlayerSpawnPoint] = []
	for child in root.get_children():
		if child is PlayerSpawnPoint:
			if child.spawn_index < 0 or child.spawn_index >= NetworkManager.MAX_PLAYERS:
				result.partial = true
				result.issues.append({"path": String(root.get_path_to(child)), "status": "Invalid Spawn", "reason": "Spawn index outside runtime capacity"})
				continue
			slots.append(child)
			slot_counts[child.spawn_index] = int(slot_counts.get(child.spawn_index, 0)) + 1
	slots.sort_custom(func(a: PlayerSpawnPoint, b: PlayerSpawnPoint) -> bool: return a.spawn_index < b.spawn_index)
	for slot in slots:
		result.starts.append({"path": String(root.get_path_to(slot)), "kind": "Fresh Slot", "slot": slot.spawn_index, "position": point(world_transform(slot).origin), "invalid_reason": "Invalid spawn transform" if not world_transform(slot).is_finite() or is_zero_approx(world_transform(slot).determinant()) else ("Duplicate spawn index" if slot_counts[slot.spawn_index] > 1 else "")})
	var points: Array[RegionPoint] = []
	RegionPoint.collect(root, points)
	for entry in points:
		if entry.kind == RegionPoint.Kind.ENTRY:
			for slot in slots:
				var offset := slot.position - slots[0].position
				result.starts.append({"path": String(root.get_path_to(entry)), "kind": "ENTRY Physical Anchor", "entry": String(entry.point_id),
					"slot": slot.spawn_index, "position": point(world_transform(entry).origin + world_transform(root).basis_xform(offset)),
					"invalid_reason": "ENTRY reference missing or duplicate" if region != null and (not entry.point_id in region.entry_point_ids or points.filter(func(other: RegionPoint) -> bool: return other.kind == entry.kind and other.point_id == entry.point_id).size() != 1) else ("Duplicate spawn index" if slot_counts[slot.spawn_index] > 1 else "")})
	for escape in result.escapes:
		escape.valid = region == null or escape.id in region.escape_point_ids
		escape.valid = escape.valid and result.escapes.filter(func(other: Dictionary) -> bool: return other.id == escape.id).size() == 1
	if result.starts.size() > 32 or result.escapes.size() > 4 or result.climbs.size() > 64:
		result.partial = true
		result.issues.append({"path": ".", "status": "Not Evaluated", "reason": "Anchor budget exceeded: at most 32 starts, 4 escapes, 64 climbables; omitted anchors are not evaluated"})
		result.starts.resize(mini(32, result.starts.size()))
		result.escapes.resize(mini(4, result.escapes.size()))
		result.climbs.resize(mini(64, result.climbs.size()))
	_candidates(result)
	result.metrics.wall_ms = Time.get_ticks_msec() - started
	return result

static func world_transform(node: Node2D) -> Transform2D:
	var result := node.transform
	var parent := node.get_parent()
	while parent is Node2D:
		result = parent.transform * result
		parent = parent.get_parent()
	return result

static func _disabled(body: Node, root: Node) -> bool:
	var current := body
	while current != null:
		if current.process_mode == Node.PROCESS_MODE_DISABLED:
			return true
		if current == root:
			break
		current = current.get_parent()
	return false

static func _body_clear(at: Vector2, shapes: Array[CollisionShape2D], shape: Shape2D, offset: Transform2D) -> bool:
	for target in shapes:
		if shape.collide(Transform2D(0, at) * offset, PlayerSpawnManager.authored_collision_shape(target), world_transform(target)):
			return false
	return true

static func _candidates(report: Dictionary) -> void:
	var physics: Dictionary = report.model
	var apex: float = physics.jump_velocity * physics.jump_velocity / (2.0 * physics.gravity)
	var surfaces: Array = report.surfaces
	for source in surfaces:
		var ordered := surfaces.duplicate()
		ordered.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return absf((a.left + a.right) * 0.5 - (source.left + source.right) * 0.5) < absf((b.left + b.right) * 0.5 - (source.left + source.right) * 0.5))
		_add_edge(report, source.id, source.id, "WALK")
		for target in ordered:
			if source.id == target.id:
				continue
			var height: float = source.y - target.y
			var flight: float = (-float(physics.jump_velocity) + sqrt(maxf(0.0, physics.jump_velocity * physics.jump_velocity - 2.0 * physics.gravity * height))) / physics.gravity
			var gap: float = maxf(0, maxf(source.left - target.right, target.left - source.right))
			if height <= apex and gap <= physics.speed * flight:
				_add_edge(report, source.id, target.id, "JUMP")
			else:
				report.issues.append({"path": target.path, "status": "Not Evaluated", "reason": "Outside ballistic candidate envelope for this fresh profile"})
			if target.y > source.y:
				_add_edge(report, source.id, target.id, "DROP")
		for climb in report.climbs:
			for kind in ["CLIMB_UP", "CLIMB_DOWN"]:
				var start := vector(climb.bottom if kind == "CLIMB_UP" else climb.top)
				var finish := vector(climb.top if kind == "CLIMB_UP" else climb.bottom)
				var closest := -1
				var distance := INF
				for target in surfaces:
					var candidate: float = Vector2(clampf(finish.x, target.left, target.right), target.y).distance_to(finish)
					if candidate < distance:
						distance = candidate
						closest = target.id
				if closest >= 0 and closest != source.id and start.x >= source.left - climb.alignment_tolerance - vector(report.model.body).x * 0.5 and start.x <= source.right + climb.alignment_tolerance + vector(report.model.body).x * 0.5 and absf(start.y - source.y) <= vector(report.model.body).y * 2:
					_add_edge(report, source.id, closest, kind, climb.path)

static func _add_edge(report: Dictionary, source: int, target: int, kind: String, climb := "") -> void:
	if report.edges.size() >= EDGE_LIMIT:
		report.partial = true
		return
	report.edges.append({"from": source, "to": target, "kind": kind, "climb": climb, "status": "Candidate",
		"reason": "Requires actual input and physics validation", "trace": [], "inputs": []})

static func reachable(report: Dictionary, source: int) -> Array[int]:
	var reached: Array[int] = []
	if source < 0 or source >= report.surfaces.size():
		return reached
	reached.append(source)
	var at := 0
	while at < reached.size():
		var current: int = reached[at]
		at += 1
		for edge in report.edges:
			if int(edge.from) == current and edge.status == "Verified" and not int(edge.to) in reached:
				reached.append(int(edge.to))
	return reached
