extends EnemyState

var remaining := 0.0

func enter() -> void:
	remaining = 0.25

func physics_tick(delta: float) -> StringName:
	remaining -= delta
	return &"chase" if remaining <= 0.0 else &""
