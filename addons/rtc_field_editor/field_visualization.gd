@tool
extends RefCounted

const Layers := preload("field_layers.gd")
const LABELS := ["Enemy Spawns", "Gather Points", "Player Spawns", "Region Points", "Climbables", "IDs"]

var enabled: Array[bool] = [false, false, false, false, false, true]

func draw(root: Node2D, overlay: Control, canvas: Transform2D, hidden: Dictionary) -> void:
	if root == null or not enabled.slice(0, 5).has(true):
		return
	for node in root.find_children("*", "Node2D", true, false):
		var marker := describe(node)
		if marker.is_empty() or not enabled[marker.index] or hidden.get(Layers.for_node(node, root), false):
			continue
		var point: Vector2 = canvas * node.global_position
		if not point.is_finite() or not Rect2(Vector2.ZERO, overlay.size).grow(80).has_point(point):
			continue
		var color: Color = marker.color
		if node is FieldGatherPoint:
			var size := FieldGatherPoint.TARGET_SIZE
			var transform := Transform2D(root.global_transform.x, root.global_transform.y, node.global_position)
			_rect(overlay, canvas * transform, Rect2(-size / 2, size), color)
			overlay.draw_arc(point, FieldGatherPoint.SERVER_DISTANCE * canvas.x.length(), 0, TAU, 32, Color(color, 0.30), 1)
		elif node is ClimbableArea2D:
			for child in node.get_children():
				if child is CollisionShape2D and child.shape is RectangleShape2D:
					_rect(overlay, canvas * child.global_transform, Rect2(-child.shape.size / 2, child.shape.size), color)
			for end in [node.top_marker, node.bottom_marker]:
				if end != null:
					overlay.draw_circle(canvas * end.global_position, 4, color)
		if marker.index == 3:
			overlay.draw_circle(point, 5, color, false, 2)
		else:
			overlay.draw_circle(point, 5, color)
		var label: String = marker.label + (" [server ≤%d]" % FieldGatherPoint.SERVER_DISTANCE if node is FieldGatherPoint else "") + ("  " + marker.id if enabled[5] and not marker.id.is_empty() else "")
		var font := overlay.get_theme_default_font()
		overlay.draw_string_outline(font, point + Vector2(8, -5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 3, Color.BLACK)
		overlay.draw_string(font, point + Vector2(8, -5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)

static func describe(node: Node) -> Dictionary:
	if node is FieldEnemySpawnPoint:
		return {"index": 0, "color": Color.SALMON, "label": "Enemy" if node.enabled else "Enemy (off)", "id": "%s / %s" % [node.enemy_id, node.spawn_id]}
	if node is FieldGatherPoint:
		return {"index": 1, "color": Color.KHAKI, "label": "Gather ×%d%s" % [node.amount, "" if node.enabled else " (off)"], "id": "%s / %s" % [node.item_id, node.interaction_id]}
	if node is PlayerSpawnPoint:
		return {"index": 2, "color": Color.SKY_BLUE, "label": "Player slot %d" % node.spawn_index, "id": ""}
	if node is RegionPoint:
		return {"index": 3, "color": Color.AQUAMARINE if node.kind == RegionPoint.Kind.ENTRY else Color.VIOLET,
			"label": "ENTRY" if node.kind == RegionPoint.Kind.ENTRY else ("ESCAPE (landing)" if node.requires_landing else "ESCAPE"), "id": String(node.point_id)}
	if node is ClimbableArea2D:
		return {"index": 4, "color": Color.LIGHT_GREEN, "label": "Climb", "id": String(node.definition.id) if node.definition != null else ""}
	return {}

static func _rect(overlay: Control, transform: Transform2D, box: Rect2, color: Color) -> void:
	overlay.draw_polyline(PackedVector2Array([transform * box.position, transform * Vector2(box.end.x, box.position.y),
		transform * box.end, transform * Vector2(box.position.x, box.end.y), transform * box.position]), color, 1)
