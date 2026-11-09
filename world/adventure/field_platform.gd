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

func _ready() -> void:
	_update_geometry()

func _update_geometry() -> void:
	if not is_node_ready():
		return
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	var visual := get_node_or_null("Visual") as Polygon2D
	if collision == null or visual == null:
		return
	var shape := RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	collision.one_way_collision = one_way
	var half := size / 2.0
	visual.polygon = PackedVector2Array([-half, Vector2(half.x, -half.y), half, Vector2(-half.x, half.y)])
	visual.color = tint
