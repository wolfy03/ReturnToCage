class_name PlayerInputComponent
extends Node

signal jump_requested
signal attack_requested
## Edge-triggered, like attack: a dodge is a discrete intent and never rides the
## continuous movement axes. It carries the horizontal intent sampled at the
## moment the button went down — -1, +1, or 0 when the player held no direction —
## because the cached axis below is only refreshed in [method _process] and can
## still describe the previous frame on the tick the player turns and dodges
## together.
signal dodge_requested(horizontal_direction: float)
signal interact_requested
signal quick_item_requested
signal inventory_requested
signal equipment_requested
signal pause_requested

## Below this the stick is treated as centred, so a resting analogue stick does
## not decide a dodge direction the player did not ask for.
const HORIZONTAL_INTENT_DEADZONE := 0.1

var vertical_axis: float = 0.0
var move_vector: Vector2:
	get:
		return Vector2(move_axis, vertical_axis)

var move_axis: float = 0.0
var local_input_enabled: bool = true
var gameplay_actions_enabled: bool = true
var network_intents_enabled: bool = false
var _jump_pressed: bool = false

var _local_combat_buffer: CombatInputBufferComponent

func _enter_tree() -> void:
	LocalInputContext.gameplay_input_blocked_changed.connect(_on_gameplay_blocked_changed)
	if LocalInputContext.is_gameplay_blocked():
		_on_gameplay_blocked_changed(true)

func _exit_tree() -> void:
	LocalInputContext.gameplay_input_blocked_changed.disconnect(_on_gameplay_blocked_changed)

func configure_input(
	p_local_input_enabled: bool,
	p_gameplay_actions_enabled: bool,
	local_combat_buffer: CombatInputBufferComponent = null
) -> void:
	local_input_enabled = p_local_input_enabled
	gameplay_actions_enabled = p_gameplay_actions_enabled
	_local_combat_buffer = local_combat_buffer
	if not local_input_enabled:
		_neutralize()
	if LocalInputContext.is_gameplay_blocked():
		_on_gameplay_blocked_changed(true)

func _on_gameplay_blocked_changed(blocked: bool) -> void:
	if not blocked or (not local_input_enabled and _local_combat_buffer == null):
		return
	_neutralize()
	if _local_combat_buffer != null:
		_local_combat_buffer.clear()

func _neutralize() -> void:
	move_axis = 0.0
	vertical_axis = 0.0
	_jump_pressed = false

func _process(_delta: float) -> void:
	if not local_input_enabled:
		return
	if LocalInputContext.is_gameplay_blocked():
		_neutralize()
		return
	move_axis = _sample_axis(&"move_left", &"move_right")
	vertical_axis = _sample_axis(&"move_up", &"move_down")

func _sample_axis(negative: StringName, positive: StringName) -> float:
	var negative_allowed := LocalInputContext.is_action_rearmed(negative)
	var positive_allowed := LocalInputContext.is_action_rearmed(positive)
	if negative_allowed and positive_allowed:
		return Input.get_axis(negative, positive)
	var negative_strength := Input.get_action_strength(negative) if negative_allowed else 0.0
	var positive_strength := Input.get_action_strength(positive) if positive_allowed else 0.0
	return positive_strength - negative_strength

func _unhandled_input(event: InputEvent) -> void:
	if not local_input_enabled:
		return
	# GUI and Presenter handlers get priority through Godot's input dispatch.
	if event.is_action_pressed(&"open_inventory"):
		inventory_requested.emit()
	elif event.is_action_pressed(&"open_equipment"):
		equipment_requested.emit()
	elif event.is_action_pressed(&"pause"):
		pause_requested.emit()
	elif not LocalInputContext.is_gameplay_blocked():
		_handle_gameplay_input(event)

func _handle_gameplay_input(event: InputEvent) -> void:
	if _is_fresh_press(event, &"jump"):
		_jump_pressed = true
		if gameplay_actions_enabled:
			jump_requested.emit()
	elif gameplay_actions_enabled or network_intents_enabled:
		if _is_fresh_press(event, &"primary_attack"):
			attack_requested.emit()
		elif _is_fresh_press(event, &"dodge"):
			dodge_requested.emit(_current_horizontal_intent())
		elif _is_fresh_press(event, &"interact"):
			interact_requested.emit()
		elif _is_fresh_press(event, &"use_quick_item"):
			quick_item_requested.emit()

func _is_fresh_press(event: InputEvent, action: StringName) -> bool:
	return event.is_action_pressed(action) and LocalInputContext.is_action_rearmed(action)

## Reads the movement actions directly rather than the cached axis, so a dodge
## pressed on the same frame as a turn rolls the way the player is pressing.
## Returns exactly -1, +1 or 0 — never a raw analogue value.
func _current_horizontal_intent() -> float:
	var axis := _sample_axis(&"move_left", &"move_right")
	return signf(axis) if absf(axis) >= HORIZONTAL_INTENT_DEADZONE else 0.0

func take_jump_pressed() -> bool:
	var pressed := _jump_pressed
	_jump_pressed = false
	return pressed

func take_local_move_command(sequence: int) -> PlayerMoveCommand:
	var jump := take_jump_pressed()
	if LocalInputContext.is_gameplay_blocked():
		return PlayerMoveCommand.new(sequence, 0.0, 0.0, false)
	return PlayerMoveCommand.new(sequence, move_axis, vertical_axis, jump)

func apply_move_command(command: PlayerMoveCommand) -> void:
	if _local_combat_buffer != null and LocalInputContext.is_gameplay_blocked():
		return
	move_axis = command.move_axis
	vertical_axis = command.vertical_axis
	if command.jump_pressed:
		jump_requested.emit()
