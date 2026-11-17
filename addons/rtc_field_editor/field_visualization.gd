@tool
extends RefCounted

const Layers := preload("field_layers.gd")
const LABELS := ["Enemy Spawns", "Gather Points", "Player Spawns", "Region Points", "Climbables", "IDs", "Spawn Clearance", "Spawn Warnings", "Walkable Surfaces", "Verified Jumps", "Candidate Jumps", "Drop Connections", "Climb Connections", "Unreachable Areas", "Escape Reachability"]

var enabled: Array[bool] = [false, false, false, false, false, true, false, false, false, false, false, false, false, false, false]
var spawn_results: Array[Dictionary] = []
var traversal: Dictionary = {}
var selected_edge := -1

func draw(root: Node2D, overlay: Control, canvas: Transform2D, hidden: Dictionary, region: RegionDefinition = null) -> void:
	if root == null:
		return
	_draw_traversal(root, overlay, canvas, hidden)
	if enabled.size() > 7 and (enabled[6] or enabled[7]):
		_draw_spawn_results(overlay, canvas, hidden)
	if not enabled.slice(0, 5).has(true):
		return
	for node in root.find_children("*", "Node2D", true, false):
		var marker := describe(node)
		if marker.is_empty() or not enabled[marker.index] or hidden.get(Layers.for_node(node, root), false):
			continue
		var point: Vector2 = canvas * node.global_position
		if not point.is_finite() or not Rect2(Vector2.ZERO, overlay.size).grow(80).has_point(point):
			continue
		var color: Color = marker.color
		if node is RegionPoint:
			var ids: Array[StringName] = []
			if region != null:
				ids = region.entry_point_ids if node.kind == RegionPoint.Kind.ENTRY else region.escape_point_ids
			if not node.point_id in ids:
				color = Color.TOMATO
			if node in EditorInterface.get_selection().get_selected_nodes():
				overlay.draw_circle(point, 9, Color.WHITE, false, 2)
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


func _draw_spawn_results(overlay: Control, canvas: Transform2D, hidden: Dictionary) -> void:
	for result in spawn_results:
		if not is_instance_valid(result.node) or not result.has("at") or hidden.get(Layers.for_node(result.node, result.node.owner), false):
			continue
		var point: Vector2 = canvas * result.node.global_position
		if not point.is_finite() or not result.node.global_position.is_equal_approx(result.at):
			continue
		var color := Color.SKY_BLUE if result.severity == "Info" else (Color.TOMATO if result.severity == "Error" else Color.GOLD)
		if result.node in EditorInterface.get_selection().get_selected_nodes():
			overlay.draw_circle(point, 12, color, false, 2)
			for candidate in result.get("detail", {}).get("candidates", []):
				if candidate.overlap and is_instance_valid(candidate.shape) and candidate.shape.shape != null:
					_rect(overlay, canvas * candidate.shape.global_transform, candidate.shape.shape.get_rect(), Color.TOMATO)
		if enabled[6]:
			overlay.draw_arc(point, result.radius * canvas.x.length(), 0, TAU, 24, color, 1)
			_rect(overlay, canvas * Transform2D(0, result.node.global_position) * result.offset, result.body, color)
		if enabled[7] and result.severity != "Info":
			overlay.draw_string(overlay.get_theme_default_font(), point + Vector2(8, 14), result.severity + " | " + result.message, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)

func _draw_traversal(root: Node2D, overlay: Control, canvas: Transform2D, hidden: Dictionary) -> void:
	if traversal.is_empty() or enabled.size() < 15 or not enabled.slice(8).has(true):
		return
	var clip := Rect2(Vector2.ZERO, overlay.size).grow(20)
	if enabled[8] and not hidden.get("Terrain", false):
		for surface in traversal.surfaces:
			var left: Vector2 = canvas * Vector2(surface.left, surface.top)
			var right: Vector2 = canvas * Vector2(surface.right, surface.top)
			if Rect2(left, Vector2.ZERO).expand(right).intersects(clip, true):
				overlay.draw_line(left, right, Color.LIME_GREEN if surface.status == "Verified" else Color.GRAY, 3)
	if enabled[13] and not hidden.get("Terrain", false):
		for surface in traversal.surfaces:
			if surface.get("access", "Not Evaluated") == "Not Evaluated":
				var left: Vector2 = canvas * Vector2(surface.left, surface.top)
				var right: Vector2 = canvas * Vector2(surface.right, surface.top)
				if Rect2(left, Vector2.ZERO).expand(right).intersects(clip, true):
					overlay.draw_dashed_line(left, right, Color.TOMATO, 2, 6)
					overlay.draw_string(overlay.get_theme_default_font(), left + Vector2(0, -8), "No verified approach", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.TOMATO)
	for edge_id in traversal.edges.size():
		var edge: Dictionary = traversal.edges[edge_id]
		var index := 8
		var color := Color.GRAY
		match edge.kind:
			"JUMP":
				index = 9 if edge.status == "Verified" else 10
				color = Color.CORNFLOWER_BLUE
			"DROP":
				index = 11
				color = Color.SKY_BLUE
			"CLIMB_UP", "CLIMB_DOWN":
				index = 12
				color = Color.GOLD
		if (not enabled[index] and not (enabled[13] and edge.status == "Unreachable Within Tested Inputs")) or hidden.get("Terrain", false) or index == 12 and hidden.get("Climbables", false):
			continue
		var points := PackedVector2Array()
		if edge.status == "Verified":
			for value in edge.trace:
				points.append(canvas * Vector2(value[0], value[1]))
		else:
			var source: Dictionary = traversal.surfaces[int(edge.from)]
			var target: Dictionary = traversal.surfaces[int(edge.to)]
			points = PackedVector2Array([canvas * Vector2((source.left + source.right) / 2, source.y), canvas * Vector2((target.left + target.right) / 2, target.y)])
			color = Color.TOMATO if edge.status == "Unreachable Within Tested Inputs" else Color.GRAY
		if points.size() < 2:
			continue
		var bounds := Rect2(points[0], Vector2.ZERO)
		for point in points:
			bounds = bounds.expand(point)
		if not bounds.intersects(clip, true):
			continue
		if edge.status == "Verified":
			overlay.draw_polyline(points, Color.WHITE if edge_id == selected_edge else color, 3.0 if edge_id == selected_edge else 1.5)
			var middle := points.size() / 2
			var direction := (points[middle] - points[maxi(0, middle - 1)]).normalized()
			overlay.draw_line(points[-1], points[-1] - direction.rotated(0.5) * 8, color)
			overlay.draw_line(points[-1], points[-1] - direction.rotated(-0.5) * 8, color)
		else:
			overlay.draw_dashed_line(points[0], points[-1], Color.WHITE if edge_id == selected_edge else color, 3 if edge_id == selected_edge else 1, 6)
	if enabled[14] and not hidden.get("RegionPoints", false):
		for escape in traversal.escapes:
			var marker := root.get_node_or_null(NodePath(escape.path)) as Node2D
			if marker == null:
				continue
			var routes: Array = traversal.routes.filter(func(route: Dictionary) -> bool: return route.escape == escape.id)
			var passed: int = routes.filter(func(route: Dictionary) -> bool: return route.status == "Verified Reachable").size()
			var all_slots: bool = not traversal.partial and not routes.is_empty() and passed == traversal.starts.size() and routes.size() == traversal.starts.size()
			var at: Vector2 = canvas * marker.global_position
			if clip.has_point(at):
				overlay.draw_circle(at, 12, Color.LIME_GREEN if all_slots else Color.GOLD, false, 2)
				overlay.draw_string(overlay.get_theme_default_font(), at + Vector2(14, 15), "Verified %d/%d starts" % [passed, traversal.starts.size()], HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
