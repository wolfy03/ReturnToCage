class_name InteractionTarget
extends Area2D

signal activated(actor: Node)

@export var prompt: String = "Interact"
@export var interaction_priority: int = 0
@export var interaction_id: StringName
@export var enabled: bool = true

func can_interact(_actor: Node) -> bool:
	return enabled

## Reuse the authored interaction shapes, independent of broadphase timing.
## Both transforms come from the server world, never from an intent payload.
func is_in_range(actor: PlayerActor) -> bool:
	if actor == null or not actor.global_position.is_finite() or not global_position.is_finite():
		return false
	for source in actor.interaction.get_children():
		if not source is CollisionShape2D or source.disabled or source.shape == null:
			continue
		for target in get_children():
			if target is CollisionShape2D and not target.disabled and target.shape != null \
					and source.shape.collide(source.global_transform, target.shape, target.global_transform):
				return true
	return false

func interact(actor: Node) -> bool:
	if not can_interact(actor):
		return false
	activated.emit(actor)
	return true
