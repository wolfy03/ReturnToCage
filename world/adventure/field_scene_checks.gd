extends RefCounted
## Detached scene checks. Spawn clearance remains a runtime physics decision.

static func validate(root: Node, inspect_decoration_assets: bool) -> PackedStringArray:
	var errors := PackedStringArray()
	var slots: Dictionary[int, NodePath] = {}
	var manager := root.get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	if manager != null and (manager.settlement_spawn_policy or manager.spawn_validation_collision_mask == 0):
		errors.append("PlayerSpawnManager: adventure requires settlement policy off and a nonzero spawn collision mask")
	var nodes: Array[Node] = [root]
	nodes.append_array(root.find_children("*", "Node2D", true, false))
	for node in nodes:
		if not node is Node2D:
			continue
		var path := root.get_path_to(node)
		var transform: Transform2D = node.global_transform
		if not transform.is_finite():
			errors.append("%s: non-finite Node2D transform or coordinates" % path)
		elif (node is RegionPoint or node == root) and is_zero_approx(transform.determinant()):
			errors.append("%s: singular transform prevents reliable region coordinates" % path)

		if node is PlayerSpawnPoint:
			var index: int = node.spawn_index
			if index < 0 or index >= NetworkManager.MAX_PLAYERS:
				errors.append("%s: player spawn index %d outside 0–%d" % [path, index, NetworkManager.MAX_PLAYERS - 1])
			elif slots.has(index):
				errors.append("duplicate player spawn index %d at %s and %s" % [index, slots[index], path])
			else:
				slots[index] = path
			if node.get_parent() != root:
				errors.append("%s: nested player spawn slot is ignored; place it directly under the field root" % path)
		elif node is FieldPlatform:
			var collision := node.get_node_or_null("CollisionShape2D") as CollisionShape2D
			if not node.size.is_finite() or node.size.x <= 0.0 or node.size.y <= 0.0:
				errors.append("%s: invalid FieldPlatform size" % path)
			if not _valid_collision(collision) or not collision.shape is RectangleShape2D:
				errors.append("%s: FieldPlatform requires an enabled rectangular CollisionShape2D" % path)
			var visual := node.get_node_or_null("Visual") as Polygon2D
			if visual == null:
				errors.append("%s: FieldPlatform requires a Visual Polygon2D" % path)
			# Detached PackedScene instances still contain the prefab geometry.
			# FieldPlatform applies its authored Size on ready.
			elif node.is_node_ready() and collision != null and collision.shape is RectangleShape2D:
				if not collision.shape.size.is_equal_approx(node.size) or not _polygon_size(visual.polygon).is_equal_approx(node.size):
					errors.append("%s: FieldPlatform Size, collision and visual bounds differ" % path)
		elif node is ClimbableArea2D:
			_validate_climb(node, path, errors)
		elif node is FieldDecoration:
			var issue := FieldDecoration.asset_issue(node.asset_path, inspect_decoration_assets)
			if not issue.is_empty():
				errors.append("%s: %s (%s)" % [path, issue, node.asset_path])
	return errors

static func _validate_climb(area: ClimbableArea2D, path: NodePath, errors: PackedStringArray) -> void:
	if area.definition == null:
		errors.append("%s: climbable requires a ClimbableDefinition" % path)
	var top := area.top_marker
	var bottom := area.bottom_marker
	if top == null or bottom == null or not area.is_ancestor_of(top) or not area.is_ancestor_of(bottom):
		errors.append("%s: climbable requires Top and Bottom Marker2D references within the area" % path)
	elif not top.global_position.is_finite() or not bottom.global_position.is_finite() or top.global_position.y >= bottom.global_position.y:
		errors.append("%s: climbable Top must be above Bottom in world coordinates" % path)
	for child in area.get_children():
		if child is CollisionShape2D and _valid_collision(child):
			return
	errors.append("%s: climbable requires an enabled CollisionShape2D with a shape" % path)

static func _valid_collision(collision: CollisionShape2D) -> bool:
	if collision == null or collision.disabled or collision.shape == null:
		return false
	if collision.shape is RectangleShape2D:
		var size: Vector2 = collision.shape.size
		return size.is_finite() and size.x > 0.0 and size.y > 0.0
	return true

static func spawn_warnings(root: Node) -> PackedStringArray:
	var indices: Dictionary[int, bool] = {}
	for child in root.get_children():
		if child is PlayerSpawnPoint and child.spawn_index >= 0 and child.spawn_index < NetworkManager.MAX_PLAYERS:
			indices[child.spawn_index] = true
	var warnings := PackedStringArray()
	if indices.size() < NetworkManager.MAX_PLAYERS:
		warnings.append("Warning: %d/%d direct player spawn slots; verify multiplayer capacity." % [indices.size(), NetworkManager.MAX_PLAYERS])
	warnings.append("Spawn clearance and safe footing are checked by the runtime physics policy.")
	return warnings

static func _polygon_size(polygon: PackedVector2Array) -> Vector2:
	if polygon.is_empty():
		return Vector2.ZERO
	var bounds := Rect2(polygon[0], Vector2.ZERO)
	for vertex in polygon:
		if not vertex.is_finite():
			return Vector2.INF
		bounds = bounds.expand(vertex)
	return bounds.size
