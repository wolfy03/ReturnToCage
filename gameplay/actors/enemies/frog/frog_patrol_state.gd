extends EnemyState

## Hops taken before resting in Idle again.
@export_range(1, 20, 1) var hops_per_patrol: int = 3
var wait := 0.0
var hops_left := 0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.IDLE

func enter() -> void:
	var frog := agent as FrogAgent
	if is_zero_approx(frog.patrol_direction):
		frog.patrol_direction = 1.0
	# Re-entered after each of its own hops: only a fresh patrol refills the budget.
	if frog.hop_resume_state != &"patrol":
		hops_left = hops_per_patrol
	elif frog.last_hop_travel < 6.0:
		frog.patrol_direction = -frog.patrol_direction
	frog.hop_resume_state = &"idle"
	wait = frog.patrol_hop_interval
	frog.velocity.x = 0.0

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	if frog.target_inside_leash() and frog.distance_to_player() <= frog.definition.chase_range:
		return &"alert"
	if not frog.is_grounded():
		return &""
	wait -= delta
	if wait > 0.0:
		return &""
	if hops_left <= 0:
		return &"idle"
	var speed := frog.effect_stats.value(&"move_speed") * frog.patrol_speed_scale
	# Turn around before the hop that would leave the patrol area, not after it.
	var landing := frog.global_position.x + frog.patrol_direction * frog.hop_reach(speed, frog.patrol_hop_lift) - frog.patrol_origin.x
	if landing > frog.patrol_radius:
		frog.patrol_direction = -1.0
	elif landing < -frog.patrol_radius:
		frog.patrol_direction = 1.0
	if not frog.can_hop_toward(frog.patrol_direction, speed, frog.patrol_hop_lift):
		frog.patrol_direction = -frog.patrol_direction
		if not frog.can_hop_toward(frog.patrol_direction, speed, frog.patrol_hop_lift):
			return &"idle"
	hops_left -= 1
	return frog.request_hop(frog.patrol_direction, speed, frog.patrol_hop_lift, &"patrol")
