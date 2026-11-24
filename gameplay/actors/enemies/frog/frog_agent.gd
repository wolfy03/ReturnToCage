class_name FrogAgent
extends EnemyAgent
## A hopping enemy. It only travels through the air: every move is a hop that
## starts on the ground in the Prepare state and ends in the Hop state on
## landing, so it can never chain a second jump in mid-air.

@export_group("Hop")
## Crouch time before every hop.
@export_range(0.05, 1.0, 0.01) var prepare_seconds: float = 0.18
@export_range(0.0, 5.0, 0.05) var patrol_hop_interval: float = 0.8
@export_range(0.0, 5.0, 0.05) var chase_hop_interval: float = 0.3
## Share of move_speed used for a relaxed patrol hop.
@export_range(0.1, 1.0, 0.05) var patrol_speed_scale: float = 0.6
@export_range(50.0, 800.0, 1.0) var patrol_hop_lift: float = 230.0
@export_range(50.0, 800.0, 1.0) var chase_hop_lift: float = 340.0
@export_group("Territory")
@export_range(16.0, 1000.0, 1.0) var patrol_radius: float = 130.0
## Chasing stops this far from the patrol origin.
@export_range(32.0, 4000.0, 1.0) var leash_distance: float = 520.0
## Deepest drop a hop may land on. Anything lower counts as an edge.
@export_range(4.0, 400.0, 1.0) var max_drop: float = 56.0
@export_group("Attack")
@export_range(0.0, 10.0, 0.05) var attack_cooldown_seconds: float = 1.2
@export_range(50.0, 800.0, 1.0) var attack_leap_lift: float = 250.0
@export_range(1.0, 4.0, 0.05) var attack_leap_speed_scale: float = 1.5
## Horizontal centre distance at which the leap connects.
@export_range(8.0, 200.0, 1.0) var attack_contact_distance: float = 44.0
## Height difference the leap can cover. A target further above or below is
## approached by hopping instead of attacked from the wrong level.
@export_range(8.0, 200.0, 1.0) var attack_vertical_reach: float = 40.0
@export_group("Recovery")
@export_range(0.1, 2.0, 0.05) var alert_seconds: float = 0.35
## A chase or return that makes no progress for this long is abandoned.
@export_range(0.5, 20.0, 0.1) var stuck_seconds: float = 2.5
## Safety net for a hop that never reports a landing.
@export_range(0.5, 10.0, 0.1) var max_air_seconds: float = 2.5

const GROUND_GRACE_SECONDS := 0.06
const GROUND_BRAKE := 1400.0

var hop_direction: float = 1.0
var hop_speed: float = 0.0
var hop_lift: float = 0.0
var hop_resume_state: StringName = &"idle"
## Horizontal distance covered by the most recent finished hop.
var last_hop_travel: float = 0.0
var attack_cooldown_remaining: float = 0.0
var _since_floor: float = 0.0

func _physics_process(delta: float) -> void:
	if is_simulation_authority() and not _death_resolved:
		attack_cooldown_remaining = maxf(0.0, attack_cooldown_remaining - delta)
		# Hops and leaps own their horizontal speed; anything else on the ground
		# (a knockback, an interrupted hop) is braked so the frog never slides.
		if is_grounded() and current_state_id != &"hop" and current_state_id != &"attack":
			velocity.x = move_toward(velocity.x, 0.0, GROUND_BRAKE * delta)
	super._physics_process(delta)
	_since_floor = 0.0 if is_on_floor() else _since_floor + delta

## is_on_floor() flickers for a body resting without downward velocity, so
## grounded means "touched the floor within the last few ticks".
func is_grounded() -> bool:
	return _since_floor <= GROUND_GRACE_SECONDS

func has_target() -> bool:
	return _valid_target(player)

func target_direction() -> float:
	if not has_target():
		return facing
	var offset := player.global_position.x - global_position.x
	return facing if is_zero_approx(offset) else signf(offset)

func target_offset() -> Vector2:
	return player.global_position - global_position if has_target() else Vector2.INF

func target_in_attack_reach() -> bool:
	var offset := target_offset()
	return offset.is_finite() and offset.length() <= definition.attack_range and absf(offset.y) <= attack_vertical_reach

func target_in_contact() -> bool:
	var offset := target_offset()
	return offset.is_finite() and absf(offset.x) <= attack_contact_distance and absf(offset.y) <= attack_vertical_reach

func distance_from_origin() -> float:
	return absf(global_position.x - patrol_origin.x)

func target_inside_leash() -> bool:
	return has_target() and absf(player.global_position.x - patrol_origin.x) <= leash_distance

func face(direction: float) -> void:
	if not is_zero_approx(direction):
		facing = signf(direction)

## Horizontal distance a hop with these speeds covers on level ground.
func hop_reach(speed: float, lift: float) -> float:
	return speed * 2.0 * lift / GRAVITY

## True when a hop in this direction would come down on terrain no lower than
## max_drop and is not walled off at body height.
func can_hop_toward(direction: float, speed: float, lift: float) -> bool:
	if is_zero_approx(direction) or not is_inside_tree():
		return false
	var space := get_world_2d().direct_space_state
	var reach := hop_reach(speed, lift) * signf(direction)
	var wall := PhysicsRayQueryParameters2D.create(global_position, global_position + Vector2(reach * 0.5, 0.0), collision_mask, [get_rid()])
	var wall_hit := space.intersect_ray(wall)
	if not wall_hit.is_empty() and not wall_hit.collider is CharacterBody2D:
		# A low step can still be cleared; a wall taller than the hop cannot.
		var over := PhysicsRayQueryParameters2D.create(global_position + Vector2(0.0, -lift * lift / (2.0 * GRAVITY) * 0.8),
			global_position + Vector2(reach * 0.5, -lift * lift / (2.0 * GRAVITY) * 0.8), collision_mask, [get_rid()])
		var over_hit := space.intersect_ray(over)
		if not over_hit.is_empty() and not over_hit.collider is CharacterBody2D:
			return false
	for share in [0.5, 1.0]:
		var top := global_position + Vector2(reach * share, -lift * lift / (2.0 * GRAVITY))
		var down := PhysicsRayQueryParameters2D.create(top, Vector2(top.x, global_position.y + max_drop + 24.0), collision_mask, [get_rid()])
		if space.intersect_ray(down).is_empty():
			return false
	return true

## Queues one hop. The Prepare state crouches, then launches it.
func request_hop(direction: float, speed: float, lift: float, resume_state: StringName) -> StringName:
	hop_direction = signf(direction) if not is_zero_approx(direction) else facing
	hop_speed = maxf(speed, 0.0)
	hop_lift = maxf(lift, 0.0)
	hop_resume_state = resume_state
	return &"prepare"
