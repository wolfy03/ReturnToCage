extends EnemyState

var remaining := 0.0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.IDLE

func enter() -> void:
	var frog := agent as FrogAgent
	remaining = frog.alert_seconds
	frog.velocity.x = 0.0
	frog.face(frog.target_direction())

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	if not frog.target_inside_leash():
		return &"return"
	frog.face(frog.target_direction())
	remaining -= delta
	return &"chase" if remaining <= 0.0 else &""
