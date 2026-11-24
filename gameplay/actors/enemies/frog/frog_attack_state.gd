extends EnemyState
## Short leap attack: crouch, lunge, at most one hit, land, recover.

## Whole attack on level ground, wind-up included.
@export_range(0.05, 5.0, 0.01) var duration_seconds: float = 0.6
## Time left when the lunge starts; the wind-up is duration_seconds minus this.
@export_range(0.0, 5.0, 0.01) var recovery_seconds: float = 0.4

var remaining := 0.0
var leaped := false
var attacked := false
var air_time := 0.0

func enter() -> void:
	var frog := agent as FrogAgent
	remaining = duration_seconds
	leaped = false
	attacked = false
	air_time = 0.0
	frog.velocity.x = 0.0
	frog.face(frog.target_direction())

func hit_seconds() -> float:
	return duration_seconds - recovery_seconds

func physics_tick(delta: float) -> StringName:
	var frog := agent as FrogAgent
	remaining -= delta
	if not leaped:
		if remaining > recovery_seconds:
			return &""
		leaped = true
		# The cooldown starts with the leap, so a leap cut short by a hit cannot
		# be repeated at once. A finished attack restarts it below.
		frog.attack_cooldown_remaining = frog.attack_cooldown_seconds
		if frog.is_grounded():
			frog.velocity = Vector2(frog.facing * frog.effect_stats.value(&"move_speed") * frog.attack_leap_speed_scale, -frog.attack_leap_lift)
		return &""
	air_time += delta
	if not attacked and frog.target_in_contact():
		# One hit per leap. perform_attack keeps the existing authority and range checks.
		attacked = true
		frog.perform_attack()
	var landed := air_time >= 0.08 and frog.is_on_floor()
	if landed:
		frog.velocity.x = 0.0
	if (landed and remaining <= 0.0) or air_time >= frog.max_air_seconds:
		frog.velocity.x = 0.0
		frog.attack_cooldown_remaining = frog.attack_cooldown_seconds
		return &"chase"
	return &""
