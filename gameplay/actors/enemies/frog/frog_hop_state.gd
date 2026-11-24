extends EnemyState
## Airborne part of a hop. Ends on landing; never starts another jump.

const MIN_AIR_SECONDS := 0.08
var elapsed := 0.0
var start_x := 0.0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.MOVING

func enter() -> void:
	elapsed = 0.0
	start_x = agent.global_position.x

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	elapsed += delta
	if (elapsed >= MIN_AIR_SECONDS and frog.is_on_floor()) or elapsed >= frog.max_air_seconds:
		frog.velocity.x = 0.0
		frog.last_hop_travel = absf(frog.global_position.x - start_x)
		var resume := frog.hop_resume_state
		# The resumed state reads hop_resume_state to tell "after my own hop"
		# from a fresh entry, then clears it.
		return resume if frog.states.has(resume) else &"idle"
	return &""
