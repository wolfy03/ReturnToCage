extends EnemyState

@export_range(0.0, 10.0, 0.05) var wait_seconds: float = 0.9
var remaining := 0.0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.IDLE

func enter() -> void:
	remaining = wait_seconds
	agent.velocity.x = 0.0

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	if frog.target_inside_leash() and frog.distance_to_player() <= frog.definition.chase_range:
		return &"alert"
	remaining -= delta
	return &"patrol" if remaining <= 0.0 else &""
