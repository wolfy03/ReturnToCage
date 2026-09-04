extends EnemyState

var remaining := 0.0

func enter() -> void:
	remaining = 0.25
	agent.velocity.x = -agent.last_hit_direction * 90.0

func physics_tick(delta: float) -> StringName:
	remaining -= delta
	return &"chase" if remaining <= 0.0 else &""
