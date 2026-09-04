class_name MovementComponent
extends Node

@export var acceleration: float = 1300.0
@export var deceleration: float = 1700.0
@export var jump_velocity: float = -390.0
@export var gravity: float = 1100.0
var body: CharacterBody2D
var input: PlayerInputComponent
var speed: float = 190.0
var enabled: bool = true

func configure(p_body: CharacterBody2D, p_input: PlayerInputComponent, p_stats: StatBlock) -> void:
	body = p_body
	input = p_input
	speed = p_stats.value(&"move_speed")
	p_stats.stat_changed.connect(func(stat_id: StringName, value: float) -> void:
		if stat_id == &"move_speed": speed = value
	)
	input.jump_requested.connect(request_jump)

func physics_tick(delta: float) -> void:
	if body == null:
		return
	if not body.is_on_floor():
		body.velocity.y += gravity * delta
	var target := input.move_axis * speed if enabled else 0.0
	var rate := acceleration if absf(target) > 0.01 else deceleration
	body.velocity.x = move_toward(body.velocity.x, target, rate * delta)
	body.move_and_slide()

func request_jump() -> void:
	if enabled and body != null and body.is_on_floor():
		body.velocity.y = jump_velocity
