class_name PlayerAttackCommand
extends RefCounted

var sequence: int

func _init(p_sequence: int = -1) -> void:
	sequence = p_sequence

func is_valid_after(previous_sequence: int) -> bool:
	return sequence >= 0 and sequence > previous_sequence
