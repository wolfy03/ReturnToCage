extends EnemyState

const ARRIVE_DISTANCE := 28.0
var wait := 0.0
var stuck := 0.0

func snapshot_state() -> int:
	return EnemyRuntimeSnapshot.State.IDLE

func enter() -> void:
	var frog := agent as FrogAgent
	if frog.hop_resume_state != &"return" or frog.last_hop_travel >= 6.0:
		stuck = 0.0
	frog.hop_resume_state = &"idle"
	wait = frog.chase_hop_interval
	frog.velocity.x = 0.0

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	if not frog.is_grounded():
		return &""
	if frog.distance_from_origin() <= ARRIVE_DISTANCE:
		return &"idle"
	if frog.target_inside_leash() and frog.distance_to_player() <= frog.definition.chase_range * 0.8 \
			and frog.distance_from_origin() < frog.leash_distance * 0.75:
		return &"alert"
	wait -= delta
	if wait > 0.0:
		return &""
	var direction := signf(frog.patrol_origin.x - frog.global_position.x)
	var speed := frog.effect_stats.value(&"move_speed")
	var lift := frog.chase_hop_lift
	if frog.distance_from_origin() < frog.hop_reach(speed, lift):
		speed *= frog.patrol_speed_scale
		lift = frog.patrol_hop_lift
	if frog.can_hop_toward(direction, speed, lift):
		return frog.request_hop(direction, speed, lift, &"return")
	stuck += delta
	if stuck >= frog.stuck_seconds:
		# The way home is cut off: settle here instead of waiting forever.
		frog.patrol_origin = frog.global_position
		return &"idle"
	return &""
