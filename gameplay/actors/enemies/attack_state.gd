extends EnemyState

var attacked := false
var remaining := 0.0

func enter() -> void:
	attacked = false
	remaining = 0.7
	agent.velocity.x = 0.0

func physics_tick(delta: float) -> StringName:
	remaining -= delta
	if not attacked and remaining <= 0.5:
		attacked = true
		agent.perform_attack()
	return &"chase" if remaining <= 0.0 else &""
