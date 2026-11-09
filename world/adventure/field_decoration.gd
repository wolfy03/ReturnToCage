@tool
class_name FieldDecoration
extends Marker2D

## A path keeps textures and scenes out of the authoritative world's dependencies.
@export_file var asset_path: String = "":
	set(value):
		asset_path = value
		if Engine.is_editor_hint() and is_node_ready():
			build_visual()

var _visual: Node2D

func _ready() -> void:
	if Engine.is_editor_hint():
		build_visual()

static func is_visual_scene(scene: PackedScene) -> bool:
	return visual_scene_issue(scene).is_empty()

static func visual_scene_issue(scene: PackedScene) -> String:
	var state := scene.get_state()
	if state.get_node_count() == 0:
		return "empty decoration scene"
	for index in state.get_node_count():
		var path := state.get_node_path(index)
		if state.get_node_instance(index) != null or state.is_node_instance_placeholder(index):
			return "nested or inherited decoration scene at %s" % path
		for property in state.get_node_property_count(index):
			if state.get_node_property_name(index, property) == &"script":
				return "scripted decoration scene node at %s" % path
		if not state.get_node_type(index) in [&"Node2D", &"Sprite2D", &"Polygon2D", &"Line2D"]:
			return "unsupported decoration scene node at %s" % path
	return ""

static func asset_issue(path: String, inspect_resource: bool = true) -> String:
	if path.is_empty() or not path.begins_with("res://") or not ResourceLoader.exists(path):
		return "missing or invalid decoration asset path"
	if not inspect_resource:
		return ""
	var resource := ResourceLoader.load(path)
	if resource is Texture2D:
		return ""
	if resource is PackedScene:
		return visual_scene_issue(resource)
	return "unsupported decoration resource; expected Texture2D or a visual PackedScene"

func build_visual() -> void:
	if is_instance_valid(_visual):
		_visual.free()
		_visual = null
	if asset_path.is_empty() or not ResourceLoader.exists(asset_path):
		return
	var asset := ResourceLoader.load(asset_path)
	if asset is Texture2D:
		var sprite := Sprite2D.new()
		sprite.texture = asset
		_visual = sprite
	elif asset is PackedScene and is_visual_scene(asset):
		_visual = asset.instantiate() as Node2D
	if _visual != null:
		add_child(_visual, false, Node.INTERNAL_MODE_BACK)
