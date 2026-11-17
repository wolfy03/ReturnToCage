extends Node2D

func _ready() -> void:
	push_error("Unmodelled gameplay behaviour must not execute in the static traversal profile")
