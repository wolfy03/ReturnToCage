@tool
class_name FieldPlatform
extends StaticBody2D

@export var size := Vector2(192, 24):
	set(value):
		size = value.max(Vector2.ONE) if value.is_finite() else Vector2(192, 24)
		_update_geometry()
@export var tint := Color("37565a"):
	set(value):
		tint = value
		_update_geometry()
@export var one_way := false:
	set(value):
		one_way = value
		_update_geometry()

@export var terrain_theme := "":
	set(value):
		terrain_theme = value
		_update_appearance()
@export var terrain_texture: Texture2D:
	set(value):
		terrain_texture = value
		_update_appearance()
@export var terrain_margins := Vector4i.ZERO:
	set(value):
		terrain_margins = value
		_update_appearance()

var _overrides_visual := false
var _legacy_visible := true


func _ready() -> void:
	_update_geometry()

func _update_geometry() -> void:
	if not is_node_ready():
		return
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	var visual := get_node_or_null("Visual") as Polygon2D
	if collision == null or visual == null:
		return
	var shape := collision.shape as RectangleShape2D
	if shape == null or shape.size != size:
		shape = RectangleShape2D.new() if shape == null else shape.duplicate() as RectangleShape2D
		shape.size = size
		collision.shape = shape
	collision.one_way_collision = one_way
	var half := size / 2.0
	visual.polygon = PackedVector2Array([-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
	visual.color = tint

	_update_appearance()


func has_terrain() -> bool:
	if terrain_theme.is_empty() or terrain_texture == null:
		return false
	var m := terrain_margins
	var border := Vector2(m.x + m.z, m.y + m.w)
	var dimensions := terrain_texture.get_size()
	return mini(mini(m.x, m.y), mini(m.z, m.w)) > 0 and border.x < dimensions.x \
		and border.y < dimensions.y and size.x >= border.x and size.y >= border.y


func _update_appearance() -> void:
	if not is_node_ready():
		return
	var visual := get_node_or_null("Visual") as Polygon2D
	var active := has_terrain()
	if visual != null and active != _overrides_visual:
		if active:
			_legacy_visible = visual.visible
		visual.visible = false if active else _legacy_visible
		_overrides_visual = active
	queue_redraw()


func _draw() -> void:
	if not has_terrain():
		return
	var m := terrain_margins
	var canvas := get_canvas_item()
	RenderingServer.canvas_item_set_default_texture_filter(canvas, RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST)
	RenderingServer.canvas_item_add_nine_patch(canvas, Rect2(-size / 2.0, size),
		Rect2(Vector2.ZERO, terrain_texture.get_size()), terrain_texture.get_rid(),
		Vector2(m.x, m.y), Vector2(m.z, m.w),
		RenderingServer.NINE_PATCH_TILE, RenderingServer.NINE_PATCH_TILE)
