extends EnemyState

## Time the body stays before loot drops and the actor is removed. The death
## clip is authored to fit inside it.
@export_range(0.05, 5.0, 0.01) var removal_seconds: float = 0.45

func enter() -> void:
	agent.velocity = Vector2.ZERO
	agent.collision_layer = 0
	agent.collision_mask = 0
	await agent.get_tree().create_timer(removal_seconds).timeout
	agent.drop_loot_and_remove()
