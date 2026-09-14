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

func configure_input(p_local_input_enabled: bool, p_gameplay_actions_enabled: bool) -> void:
	local_input_enabled = p_local_input_enabled
	gameplay_actions_enabled = p_gameplay_actions_enabled
	if not local_input_enabled:
		move_axis = 0.0
		vertical_axis = 0.0
		_jump_pressed = false

func _process(_delta: float) -> void:
	if not local_input_enabled:
		return
	move_axis = Input.get_axis(&"move_left", &"move_right")
	vertical_axis = Input.get_axis(&"move_up", &"move_down")

func _unhandled_input(event: InputEvent) -> void:
	if not local_input_enabled:
		return
	if event.is_action_pressed(&"jump"):
		_jump_pressed = true
		if gameplay_actions_enabled:
			jump_requested.emit()
	elif event.is_action_pressed(&"primary_attack"):
		if gameplay_actions_enabled or network_intents_enabled:
			attack_requested.emit()
	elif event.is_action_pressed(&"dodge"):
		if gameplay_actions_enabled or network_intents_enabled:
			dodge_requested.emit(_current_horizontal_intent())
	elif event.is_action_pressed(&"interact"):
		if gameplay_actions_enabled or network_intents_enabled:
			interact_requested.emit()
	elif event.is_action_pressed(&"use_quick_item"):
		if gameplay_actions_enabled or network_intents_enabled:
			quick_item_requested.emit()
	elif event.is_action_pressed(&"open_inventory"):
		inventory_requested.emit()
	elif event.is_action_pressed(&"pause"):
		pause_requested.emit()

## Reads the movement actions directly rather than the cached axis, so a dodge
## pressed on the same frame as a turn rolls the way the player is pressing.
## Returns exactly -1, +1 or 0 — never a raw analogue value.
func _current_horizontal_intent() -> float:
	var axis := Input.get_axis(&"move_left", &"move_right")
	return signf(axis) if absf(axis) >= HORIZONTAL_INTENT_DEADZONE else 0.0

func take_jump_pressed() -> bool:
	var pressed := _jump_pressed
	_jump_pressed = false
	return pressed

func apply_move_command(command: PlayerMoveCommand) -> void:
	move_axis = command.move_axis
	vertical_axis = command.vertical_axis
	if command.jump_pressed:
		jump_requested.emit()
