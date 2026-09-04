extends EnemyState

func physics_tick(_delta: float) -> StringName:
	var distance := agent.distance_to_player()
	if distance > agent.definition.chase_range * 1.35:
		return &"patrol"
	if distance <= agent.definition.attack_range:
		return &"attack"
	agent.velocity.x = signf(agent.player.global_position.x - agent.global_position.x) * agent.definition.move_speed
	return &""
