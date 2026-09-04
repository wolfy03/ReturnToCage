extends EnemyState

func enter() -> void:
	agent.velocity = Vector2.ZERO
	agent.collision_layer = 0
	agent.collision_mask = 0
	await agent.get_tree().create_timer(0.45).timeout
	agent.drop_loot_and_remove()
