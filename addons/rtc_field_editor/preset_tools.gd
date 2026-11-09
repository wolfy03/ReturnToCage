@tool
extends RefCounted

const Preset := preload("placement_preset.gd")
const Placement := preload("placement.gd")
const MAX_OBJECTS := 128
const FOLDER := "res://addons/rtc_field_editor/presets"

static func capture(nodes: Array[Node], root: Node2D, label: String) -> Resource:
	if nodes.is_empty() or nodes.size() > MAX_OBJECTS or label.is_empty() or not nodes[0] is Node2D:
		return null
	var result := Preset.new()
	result.label = label
	var origin: Vector2 = nodes[0].global_position
	for node in nodes:
		if not node is Node2D or node.owner != root or not valid_transform(node.global_transform):
			return null
		var relative: Transform2D = node.global_transform
		relative.origin -= origin
		var entry := {"transform": relative, "id": &""}
		if node is FieldPlatform:
			entry.merge({"kind": "platform", "size": node.size, "tint": node.tint, "one_way": node.one_way})
		elif node is FieldDecoration:
			entry.merge({"kind": "scene" if ResourceLoader.exists(node.asset_path) and ResourceLoader.load(node.asset_path) is PackedScene else "texture", "path": node.asset_path})
		elif node is FieldEnemySpawnPoint:
			entry.merge({"kind": "enemy", "id": node.enemy_id, "enabled": node.enabled}, true)
		elif node is FieldGatherPoint:
			entry.merge({"kind": "gather", "id": node.item_id, "amount": node.amount, "enabled": node.enabled}, true)
		elif node is ClimbableArea2D:
			var collision := node.get_node_or_null("CollisionShape2D") as CollisionShape2D
			if node.definition == null or node.top_marker == null or node.bottom_marker == null or collision == null or collision.disabled or not collision.shape is RectangleShape2D:
				return null
			entry.merge({"kind": "climb", "id": node.definition.id, "top": node.to_local(node.top_marker.global_position),
				"bottom": node.to_local(node.bottom_marker.global_position), "size": collision.shape.size,
				"collision_transform": node.global_transform.affine_inverse() * collision.global_transform}, true)
		else:
			return null
		if not _valid(entry) or not valid_world(node, node.global_transform):
			return null
		result.objects.append(entry)
	return result

static func build(preset: Resource, root: Node2D, catalog: RefCounted) -> Array[Node2D]:
	var nodes: Array[Node2D] = []
	var reserved: Dictionary[StringName, bool] = {}
	if not preset is Preset or preset.objects.is_empty() or preset.objects.size() > MAX_OBJECTS:
		return nodes
	for entry in preset.objects:
		if not _valid(entry):
			break
		var node := Placement.make_node(entry, root, catalog, reserved)
		if node == null:
			break
		node.transform = entry.transform
		if node is FieldPlatform:
			node.size = entry.size
			node.tint = entry.tint
			node.one_way = entry.one_way
		elif node is FieldEnemySpawnPoint:
			node.enabled = entry.enabled
			reserved[node.spawn_id] = true
		elif node is FieldGatherPoint:
			node.enabled = entry.enabled
			node.amount = entry.amount
			reserved[node.interaction_id] = true
		elif node is ClimbableArea2D:
			node.top_marker.position = entry.top
			node.bottom_marker.position = entry.bottom
			var collision := node.get_node("CollisionShape2D") as CollisionShape2D
			collision.shape.size = entry.size
			collision.transform = entry.collision_transform
		nodes.append(node)
	if nodes.size() != preset.objects.size():
		for node in nodes:
			node.free()
		nodes.clear()
	return nodes

static func _valid(entry: Dictionary) -> bool:
	if not valid_transform(entry.get("transform")):
		return false
	if not entry.get("id") is StringName:
		return false
	match entry.get("kind"):
		"platform":
			return _positive_size(entry.get("size")) and entry.size.x >= 1 and entry.size.y >= 1 and _finite_color(entry.get("tint")) and entry.get("one_way") is bool
		"texture", "scene":
			if not entry.get("path") is String or not FieldDecoration.asset_issue(entry.path).is_empty():
				return false
			var asset := ResourceLoader.load(entry.path)
			return asset is Texture2D if entry.kind == "texture" else asset is PackedScene
		"enemy":
			return entry.get("enabled") is bool
		"gather":
			return entry.get("enabled") is bool and entry.get("amount") is int and entry.amount > 0 and entry.amount <= 2147483647
		"climb":
			return _positive_size(entry.get("size")) and entry.get("top") is Vector2 and entry.top.is_finite() and entry.get("bottom") is Vector2 and entry.bottom.is_finite() and valid_transform(entry.get("collision_transform"))
	return false

static func _positive_size(size: Variant) -> bool:
	return size is Vector2 and size.is_finite() and size.x > 0 and size.y > 0

static func valid_transform(value: Variant) -> bool:
	return value is Transform2D and value.is_finite() and is_finite(value.determinant()) and not is_zero_approx(value.determinant())

static func valid_world(node: Node2D, world: Transform2D) -> bool:
	if not valid_transform(world):
		return false
	if node is FieldPlatform:
		return _finite_rectangle(world, node.size)
	if not node is ClimbableArea2D:
		return true
	var collision := node.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision == null or collision.disabled or not collision.shape is RectangleShape2D:
		return false
	var relative := node.global_transform.affine_inverse()
	var top: Vector2 = relative * node.top_marker.global_position
	var bottom: Vector2 = relative * node.bottom_marker.global_position
	var shape_transform: Transform2D = relative * collision.global_transform
	if not _finite_rectangle(world * shape_transform, collision.shape.size) or not (world * top).is_finite() or not (world * bottom).is_finite() or (world * top).y >= (world * bottom).y:
		return false
	var shape_inverse := shape_transform.affine_inverse()
	var half: Vector2 = collision.shape.size * 0.5 + Vector2(0.01, 0.01)
	for endpoint in [top, bottom]:
		var point: Vector2 = (shape_inverse * endpoint).abs()
		if not point.is_finite() or point.x > half.x or point.y > half.y:
			return false
	return true

static func _finite_rectangle(transform: Transform2D, size: Vector2) -> bool:
	if not valid_transform(transform):
		return false
	var half := size * 0.5
	for corner in [half, -half, Vector2(-half.x, half.y), Vector2(half.x, -half.y)]:
		if not (transform * corner).is_finite():
			return false
	return true

static func _finite_color(value: Variant) -> bool:
	return value is Color and is_finite(value.r) and is_finite(value.g) and is_finite(value.b) and is_finite(value.a)
