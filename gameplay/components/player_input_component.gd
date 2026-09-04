class_name PlayerInputComponent
extends Node

signal jump_requested
signal attack_requested
signal interact_requested
signal quick_item_requested
signal inventory_requested
signal pause_requested

var move_axis: float = 0.0

func _process(_delta: float) -> void:
	move_axis = Input.get_axis(&"move_left", &"move_right")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"jump"):
		jump_requested.emit()
	elif event.is_action_pressed(&"primary_attack"):
		attack_requested.emit()
	elif event.is_action_pressed(&"interact"):
		interact_requested.emit()
	elif event.is_action_pressed(&"use_quick_item"):
		quick_item_requested.emit()
	elif event.is_action_pressed(&"open_inventory"):
		inventory_requested.emit()
	elif event.is_action_pressed(&"pause"):
		pause_requested.emit()
