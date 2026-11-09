@tool
extends RefCounted

const NAMES := ["Terrain", "Decorations", "SpawnPoints", "GatherPoints", "RegionPoints", "Climbables", "Background"]

var active: String = ""
var hidden: Dictionary[String, bool] = {}
var locked: Dictionary[String, bool] = {}
var _suppressed: Array[CanvasItem] = []

static func for_node(node: Node, root: Node) -> String:
	var current := node
	while current != null and current != root:
		if current is FieldPlatform or current is StaticBody2D:
			return "Terrain"
		if current is FieldDecoration:
			return "Decorations"
		if current is FieldEnemySpawnPoint or current is PlayerSpawnPoint:
			return "SpawnPoints"
		if current is FieldGatherPoint:
			return "GatherPoints"
		if current is RegionPoint:
			return "RegionPoints"
		if current is ClimbableArea2D:
			return "Climbables"
		if current.name == &"Signs":
			return "Background"
		if String(current.name) in NAMES:
			return String(current.name)
		current = current.get_parent()
	return ""

func issue(layer: String) -> String:
	if not active.is_empty() and active != layer:
		return "Active layer is %s. This tool requires %s." % [active, layer]
	if locked.get(layer, false):
		return "%s is locked for Field Editor tools." % layer
	if hidden.get(layer, false):
		return "%s is hidden in the editor." % layer
	return ""

func set_preview(root: Node2D) -> void:
	restore()
	if root == null or not hidden.values().has(true):
		return
	for node in root.find_children("*", "CanvasItem", true, false):
		# Empty groups can contain nodes classified in other layers.
		if node.get_class() == "Node2D" and node.get_script() == null:
			continue
		var item := node as CanvasItem
		if hidden.get(for_node(item, root), false):
			RenderingServer.canvas_item_set_visible(item.get_canvas_item(), false)
			item.visibility_changed.connect(_suppress.bind(item))
			_suppressed.append(item)

func _suppress(item: CanvasItem) -> void:
	if is_instance_valid(item):
		RenderingServer.canvas_item_set_visible(item.get_canvas_item(), false)

func restore() -> void:
	for item in _suppressed:
		if is_instance_valid(item):
			item.visibility_changed.disconnect(_suppress.bind(item))
			RenderingServer.canvas_item_set_visible(item.get_canvas_item(), item.visible)
	_suppressed.clear()
