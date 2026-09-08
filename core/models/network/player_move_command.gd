class_name PlayerMoveCommand
extends RefCounted

var sequence: int
var move_axis: float
var vertical_axis: float
var jump_pressed: bool

func _init(p_sequence: int = 0, p_move_axis: float = 0.0, p_vertical_axis: float = 0.0, p_jump_pressed: bool = false) -> void:
	sequence = p_sequence
	move_axis = p_move_axis
	vertical_axis = p_vertical_axis
	jump_pressed = p_jump_pressed

func is_valid_after(previous_sequence: int) -> bool:
	return sequence > previous_sequence \
		and is_finite(move_axis) and is_finite(vertical_axis) \
		and move_axis >= -1.0 and move_axis <= 1.0 \
		and vertical_axis >= -1.0 and vertical_axis <= 1.0
