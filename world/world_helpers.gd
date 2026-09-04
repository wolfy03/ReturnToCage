class_name WorldHelpers
extends RefCounted

static func add_platform(parent: Node2D, position: Vector2, size: Vector2, color: Color) -> StaticBody2D:
	var body := StaticBody2D.new()
	body.position = position
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	var visual := Polygon2D.new()
	visual.polygon = PackedVector2Array([Vector2(-size.x/2.0,-size.y/2.0),Vector2(size.x/2.0,-size.y/2.0),Vector2(size.x/2.0,size.y/2.0),Vector2(-size.x/2.0,size.y/2.0)])
	visual.color = color
	body.add_child(visual)
	parent.add_child(body)
	return body

static func add_label(parent: Node2D, text: String, position: Vector2, color: Color = Color.WHITE) -> Label:
	var label := Label.new()
	label.text = text
	label.position = position
	label.modulate = color
	label.add_theme_font_size_override("font_size", 18)
	parent.add_child(label)
	return label

static func add_interaction(parent: Node2D, id: StringName, prompt: String, position: Vector2, size: Vector2, color: Color, priority: int = 0) -> InteractionTarget:
	var target := InteractionTarget.new()
	target.name = String(id)
	target.interaction_id = id
	target.prompt = prompt
	target.interaction_priority = priority
	target.position = position
	target.collision_layer = 8
	target.collision_mask = 0
	var collision := CollisionShape2D.new()
	var shape := RectangleShape2D.new()
	shape.size = size
	collision.shape = shape
	target.add_child(collision)
	var visual := Polygon2D.new()
	visual.polygon = PackedVector2Array([Vector2(-size.x/2.0,-size.y/2.0),Vector2(size.x/2.0,-size.y/2.0),Vector2(size.x/2.0,size.y/2.0),Vector2(-size.x/2.0,size.y/2.0)])
	visual.color = color
	target.add_child(visual)
	parent.add_child(target)
	return target
