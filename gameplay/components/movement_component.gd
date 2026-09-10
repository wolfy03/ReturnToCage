class_name MovementComponent
extends Node

signal mode_changed
signal climb_hint_changed

enum Mode { GROUND, AIR, CLIMB }
@export var acceleration: float = 1300.0
@export var deceleration: float = 1700.0
@export var jump_velocity: float = -390.0
@export var gravity: float = 1100.0
var body: CharacterBody2D
var input: PlayerInputComponent
var stats: StatBlock
var speed: float = 190.0
var enabled: bool = true
var mode: Mode = Mode.AIR
var climb_area: ClimbableArea2D
var climb_areas: Array[ClimbableArea2D] = []
var _needs_release: bool = false
var _interaction_granted: bool = false

func configure(p_body: CharacterBody2D, p_input: PlayerInputComponent, p_stats: StatBlock) -> void:
	if stats != null and stats.stat_changed.is_connected(_on_stat_changed):
		stats.stat_changed.disconnect(_on_stat_changed)
	body = p_body
	input = p_input
	stats = p_stats
	speed = stats.value(&"move_speed")
	stats.stat_changed.connect(_on_stat_changed)
	input.jump_requested.connect(request_jump)

func _on_stat_changed(stat_id: StringName, value: float) -> void:
	if stat_id == &"move_speed":
		speed = value

func add_climb_area(area: ClimbableArea2D) -> void:
	if not climb_areas.has(area):
		climb_areas.append(area)
	climb_hint_changed.emit()

func remove_climb_area(area: ClimbableArea2D) -> void:
	climb_areas.erase(area)
	_interaction_granted = false
	if climb_area == area:
		exit_climb()
	climb_hint_changed.emit()

func climb_candidate() -> ClimbableArea2D:
	for area in climb_areas:
		if is_instance_valid(area) and area.definition != null and area.contains(body):
			return area
	return null

func grant_climb_interaction() -> bool:
	var area: ClimbableArea2D = climb_candidate()
	_interaction_granted = area != null and area.definition.requires_interaction
	return _interaction_granted

func physics_tick(delta: float) -> void:
	if body == null or delta <= 0.0:
		return
	if absf(input.vertical_axis) < 0.1:
		_needs_release = false
	if mode == Mode.CLIMB:
		if not enabled or not is_instance_valid(climb_area) or not climb_area.overlaps_body(body):
			exit_climb()
		else:
			_climb_tick(delta)
			return
	if enabled and not _needs_release and absf(input.vertical_axis) >= 0.1:
		var candidate: ClimbableArea2D = climb_candidate()
		if candidate != null and (not candidate.definition.requires_interaction or _interaction_granted):
			climb_area = candidate
			mode = Mode.CLIMB
			body.velocity = Vector2.ZERO
			_interaction_granted = false
			mode_changed.emit()
			_climb_tick(delta)
			return
	mode = Mode.GROUND if body.is_on_floor() else Mode.AIR
	if mode == Mode.AIR:
		body.velocity.y += gravity * delta
	var target: float = input.move_axis * speed if enabled else 0.0
	body.velocity.x = move_toward(body.velocity.x, target, (acceleration if absf(target) > 0.01 else deceleration) * delta)
	body.move_and_slide()

func _climb_tick(delta: float) -> void:
	var definition: ClimbableDefinition = climb_area.definition
	body.velocity.x = clampf((climb_area.global_position.x - body.global_position.x) / delta, -definition.alignment_speed, definition.alignment_speed)
	body.velocity.y = input.vertical_axis * speed * definition.speed_multiplier
	var next_y: float = body.global_position.y + body.velocity.y * delta
	var leave: bool = false
	if next_y <= climb_area.top().y and input.vertical_axis < 0.0:
		body.velocity.y = (climb_area.top().y - body.global_position.y) / delta
		leave = definition.allow_top_exit
	elif next_y >= climb_area.bottom().y and input.vertical_axis > 0.0:
		body.velocity.y = (climb_area.bottom().y - body.global_position.y) / delta
		leave = definition.allow_bottom_exit
	body.move_and_slide()
	if leave:
		exit_climb()

func exit_climb() -> void:
	climb_area = null
	mode = Mode.AIR
	_needs_release = true
	mode_changed.emit()

func on_damage(forced_knockback: bool = false) -> void:
	if mode == Mode.CLIMB and (forced_knockback or climb_area.definition.drop_on_damage):
		exit_climb()

func request_jump() -> void:
	if not enabled or body == null:
		return
	if mode == Mode.CLIMB:
		if climb_area.definition.allow_jump_exit:
			exit_climb()
			body.velocity.y = jump_velocity
	elif body.is_on_floor():
		body.velocity.y = jump_velocity

func _exit_tree() -> void:
	if stats != null and stats.stat_changed.is_connected(_on_stat_changed):
		stats.stat_changed.disconnect(_on_stat_changed)
	climb_area = null
	climb_areas.clear()
	mode = Mode.AIR
