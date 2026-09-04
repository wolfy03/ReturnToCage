extends EnemyState

func enter() -> void:
	if is_zero_approx(agent.patrol_direction):
		agent.patrol_direction = 1.0

func physics_tick(_delta: float) -> StringName:
	if agent.distance_to_player() <= agent.definition.chase_range:
		return &"chase"
	if agent.global_position.x < agent.patrol_origin.x - 90.0:
		agent.patrol_direction = 1.0
	elif agent.global_position.x > agent.patrol_origin.x + 90.0:
		agent.patrol_direction = -1.0
	agent.velocity.x = agent.patrol_direction * agent.definition.move_speed * 0.55
	return &""
