@tool
extends RefCounted

const Preset := preload("placement_preset.gd")
const Placement := preload("placement.gd")
const FOLDER := "res://addons/rtc_field_editor/presets"

static func capture(nodes: Array[Node], root: Node2D, label: String) -> Resource:
	if nodes.is_empty() or nodes.size() > 128 or label.is_empty() or not nodes[0] is Node2D:
		return null
	var result := Preset.new()
	result.label = label
	var origin: Vector2 = nodes[0].global_position
	for node in nodes:
		if not node is Node2D or node.owner != root:
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
		result.objects.append(entry)
	return result

static func build(preset: Resource, root: Node2D, catalog: RefCounted) -> Array[Node2D]:
	var nodes: Array[Node2D] = []
	var reserved: Dictionary[StringName, bool] = {}
	if not preset is Preset or preset.objects.is_empty() or preset.objects.size() > 128:
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
	if not entry.get("transform") is Transform2D or not entry.transform.is_finite() or is_zero_approx(entry.transform.determinant()):
		return false
	if not entry.get("id") is StringName:
		return false
	match entry.get("kind"):
		"platform":
			return _positive_size(entry.get("size")) and entry.get("tint") is Color and entry.get("one_way") is bool
		"texture", "scene":
			return entry.get("path") is String and FieldDecoration.asset_issue(entry.path).is_empty()
		"enemy":
			return entry.get("enabled") is bool
		"gather":
			return entry.get("enabled") is bool and entry.get("amount") is int and entry.amount > 0
		"climb":
			return _positive_size(entry.get("size")) and entry.get("top") is Vector2 and entry.top.is_finite() and entry.get("bottom") is Vector2 and entry.bottom.is_finite() and entry.top.y < entry.bottom.y and entry.get("collision_transform") is Transform2D and entry.collision_transform.is_finite()
	return false

static func _positive_size(size: Variant) -> bool:
	return size is Vector2 and size.is_finite() and size.x > 0 and size.y > 0
