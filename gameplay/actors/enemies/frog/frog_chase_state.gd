extends EnemyState

var wait := 0.0
var stuck := 0.0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.IDLE

func enter() -> void:
	var frog := agent as FrogAgent
	# Re-entered after each hop. A hop that went nowhere keeps the stuck clock.
	if frog.hop_resume_state != &"chase" or frog.last_hop_travel >= 6.0:
		stuck = 0.0
	frog.hop_resume_state = &"idle"
	wait = frog.chase_hop_interval
	frog.velocity.x = 0.0

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	if not frog.has_target() or not frog.target_inside_leash() \
			or frog.distance_from_origin() > frog.leash_distance \
			or frog.distance_to_player() > frog.definition.chase_range * 1.35:
		return &"return"
	if not frog.is_grounded():
		return &""
	var direction := frog.target_direction()
	frog.face(direction)
	if frog.target_in_attack_reach():
		if frog.attack_cooldown_remaining <= 0.0:
			return &"attack"
		return &""
	wait -= delta
	if wait > 0.0:
		return &""
	var speed := frog.effect_stats.value(&"move_speed")
	if frog.can_hop_toward(direction, speed, frog.chase_hop_lift):
		return frog.request_hop(direction, speed, frog.chase_hop_lift, &"chase")
	stuck += delta
	return &"return" if stuck >= frog.stuck_seconds else &""
