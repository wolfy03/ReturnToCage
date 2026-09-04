extends EnemyState

var remaining: float

func enter() -> void:
	remaining = 1.0
	agent.velocity.x = 0.0

func physics_tick(delta: float) -> StringName:
	remaining -= delta
	if agent.distance_to_player() <= agent.definition.chase_range:
		return &"chase"
	return &"patrol" if remaining <= 0.0 else &""
