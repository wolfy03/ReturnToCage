extends EnemyState
## Crouch before a hop. Launching happens here, on the ground, exactly once.

var remaining := 0.0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.MOVING

func enter() -> void:
	var frog := agent as FrogAgent
	remaining = frog.prepare_seconds
	frog.velocity.x = 0.0
	frog.face(frog.hop_direction)

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	remaining -= delta
	if remaining > 0.0:
		return &""
	if not frog.is_grounded():
		# Knocked off the ground while crouching: no launch from mid-air.
		return frog.hop_resume_state
	frog.velocity = Vector2(frog.hop_direction * frog.hop_speed, -frog.hop_lift)
	return &"hop"
