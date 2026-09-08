class_name PlayerInputComponent
extends Node

signal jump_requested
signal attack_requested
signal interact_requested
signal quick_item_requested
signal inventory_requested
signal pause_requested

var vertical_axis: float = 0.0
var move_vector: Vector2:
	get:
		return Vector2(move_axis, vertical_axis)

var move_axis: float = 0.0
var local_input_enabled: bool = true
var gameplay_actions_enabled: bool = true
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
		if gameplay_actions_enabled:
			attack_requested.emit()
	elif event.is_action_pressed(&"interact"):
		if gameplay_actions_enabled:
			interact_requested.emit()
	elif event.is_action_pressed(&"use_quick_item"):
		if gameplay_actions_enabled:
			quick_item_requested.emit()
	elif event.is_action_pressed(&"open_inventory"):
		inventory_requested.emit()
	elif event.is_action_pressed(&"pause"):
		pause_requested.emit()

func take_jump_pressed() -> bool:
	var pressed := _jump_pressed
	_jump_pressed = false
	return pressed

func apply_move_command(command: PlayerMoveCommand) -> void:
	move_axis = command.move_axis
	vertical_axis = command.vertical_axis
	if command.jump_pressed:
		jump_requested.emit()
