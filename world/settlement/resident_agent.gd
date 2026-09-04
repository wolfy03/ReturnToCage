class_name ResidentAgent
extends CharacterBody2D

enum State { IDLE, WALK_TO_POINT, USE_FACILITY }
var state := State.IDLE
var interest_points: Array[Vector2] = []
var target := Vector2.ZERO
var idle_time := 1.0

func configure(points: Array[Vector2]) -> void:
	interest_points = points

func _physics_process(delta: float) -> void:
	match state:
		State.IDLE:
			idle_time -= delta
			if idle_time <= 0.0 and not interest_points.is_empty():
				target = interest_points[randi() % interest_points.size()]
				state = State.WALK_TO_POINT
		State.WALK_TO_POINT:
			velocity.x = signf(target.x - global_position.x) * 38.0
			move_and_slide()
			if absf(target.x - global_position.x) < 8.0:
				velocity.x = 0.0
				idle_time = 2.0
				state = State.USE_FACILITY
		State.USE_FACILITY:
			idle_time -= delta
			if idle_time <= 0.0:
				idle_time = 1.5
				state = State.IDLE
