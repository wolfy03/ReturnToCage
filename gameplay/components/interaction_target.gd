class_name InteractionTarget
extends Area2D

signal activated(actor: Node)

@export var prompt: String = "Interact"
@export var interaction_priority: int = 0
@export var interaction_id: StringName
@export var enabled: bool = true

func can_interact(_actor: Node) -> bool:
	return enabled

func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	activated.emit(actor)
	return true
