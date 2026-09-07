class_name ClimbableArea2D
extends Area2D

@export var definition: ClimbableDefinition
@export var top_marker: Marker2D
@export var bottom_marker: Marker2D

func _ready() -> void:
	body_entered.connect(_on_entered)
	body_exited.connect(_on_exited)
	queue_redraw()

func _on_entered(body: Node2D) -> void:
	if body is PlayerActor:
		body.movement.add_climb_area(self)

func _on_exited(body: Node2D) -> void:
	if body is PlayerActor:
		body.movement.remove_climb_area(self)

func top() -> Vector2:
	return top_marker.global_position if top_marker != null else global_position

func bottom() -> Vector2:
	return bottom_marker.global_position if bottom_marker != null else global_position

func contains(body: CharacterBody2D) -> bool:
	return overlaps_body(body) and absf(body.global_position.x - global_position.x) <= definition.alignment_tolerance

func _draw() -> void:
	if definition == null or top_marker == null or bottom_marker == null:
		return
	var start: Vector2 = to_local(top())
	var finish: Vector2 = to_local(bottom())
	if definition.kind == ClimbableDefinition.Kind.ROPE:
		draw_line(start, finish, Color("cbb98d"), 5.0)
	else:
		draw_line(start + Vector2(-16, 0), finish + Vector2(-16, 0), Color("c89f54"), 4.0)
		draw_line(start + Vector2(16, 0), finish + Vector2(16, 0), Color("c89f54"), 4.0)
		var y: float = start.y
		while y <= finish.y:
			draw_line(Vector2(-16, y), Vector2(16, y), Color("c89f54"), 3.0)
			y += 22.0
