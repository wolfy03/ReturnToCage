extends EnemyState

## Whole attack, wind-up included.
@export_range(0.05, 5.0, 0.01) var duration_seconds: float = 0.7
## Time left when the hit lands; the wind-up is duration_seconds minus this.
@export_range(0.0, 5.0, 0.01) var recovery_seconds: float = 0.5

var attacked := false
var remaining := 0.0

func enter() -> void:
	attacked = false
	remaining = duration_seconds
	agent.velocity.x = 0.0

func hit_seconds() -> float:
	return duration_seconds - recovery_seconds

func physics_tick(delta: float) -> StringName:
	remaining -= delta
	if not attacked and remaining <= recovery_seconds:
		attacked = true
		agent.perform_attack()
	return &"chase" if remaining <= 0.0 else &""
