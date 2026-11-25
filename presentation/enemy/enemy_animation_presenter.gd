class_name EnemyAnimationPresenter
extends Node2D
## Draws an EnemyAgent from state it already owns or mirrors (state id,
## velocity, facing, health). It never changes gameplay: no hit, damage, state
## or physics decision reads a clip or a frame. The same rules run for the
## authoritative actor and for a replicated one, so no extra network data is
## needed.

## Presentation-only settle time after touching down.
const LAND_SECONDS := 0.16
## Vertical speed must stay low this long before an airborne actor is drawn grounded.
const GROUNDED_CONFIRM_SECONDS := 0.07

var agent: EnemyAgent
var profile: EnemyAnimationProfile
var sprite: AnimatedSprite2D
var current_animation: StringName = &""
## Counts real clip starts; tests use it to prove a clip is not restarted every frame.
var play_count: int = 0
var _airborne: bool = false
var _rising: bool = false
var _grounded_time: float = 0.0
var _land_remaining: float = 0.0
var _death_started: bool = false
var _last_health: float = 0.0

func setup(p_agent: EnemyAgent, p_profile: EnemyAnimationProfile) -> void:
	agent = p_agent
	profile = p_profile
	sprite = AnimatedSprite2D.new()
	sprite.name = "Sprite"
	sprite.sprite_frames = profile.sprite_frames
	sprite.texture_filter = profile.texture_filter
	sprite.position = profile.visual_offset
	add_child(sprite)
	_last_health = agent.health.current_health
	agent.health.health_changed.connect(_on_health_changed)
	_apply_facing()
	_play(profile.idle_animation, false)

func _process(delta: float) -> void:
	if agent == null or profile == null:
		return
	_apply_facing()
	_update_airborne(delta)
	_play(_wanted_animation(), false)

func _wanted_animation() -> StringName:
	var state := agent.current_state_id
	if state == &"dead" or _death_started:
		return profile.death_animation
	if state == &"hurt":
		return profile.hurt_animation
	if state == &"attack":
		return profile.attack_animation
	if _airborne:
		var airborne := profile.jump_animation if _rising else profile.fall_animation
		if profile.has_animation(airborne):
			return airborne
	if _land_remaining > 0.0 and profile.has_animation(profile.land_animation):
		return profile.land_animation
	if _is_preparing(state) and profile.has_animation(profile.jump_start_animation):
		return profile.jump_start_animation
	return profile.move_animation if absf(agent.velocity.x) > profile.move_speed_threshold else profile.idle_animation

## The authority knows its Prepare state by name. A replica only mirrors the
## coarse snapshot state, where a hopper that is "moving" yet standing on the
## ground can only be crouching for its next hop.
func _is_preparing(state: StringName) -> bool:
	if state == &"prepare":
		return true
	return not agent.is_simulation_authority() and state == &"chase" \
		and absf(agent.velocity.x) <= profile.move_speed_threshold

## Replicated actors do not run physics, so "airborne" is read from the vertical
## velocity both sides have. The short confirmation time hides the apex, where
## the speed passes through zero.
func _update_airborne(delta: float) -> void:
	_land_remaining = maxf(0.0, _land_remaining - delta)
	if absf(agent.velocity.y) > profile.airborne_speed:
		_airborne = true
		# Decided only by a clear vertical speed, so the apex keeps the rising clip.
		_rising = agent.velocity.y < 0.0
		_grounded_time = 0.0
	elif _airborne:
		_grounded_time += delta
		if _grounded_time >= GROUNDED_CONFIRM_SECONDS:
			_airborne = false
			_land_remaining = LAND_SECONDS

func _play(animation: StringName, restart: bool) -> void:
	if animation.is_empty() or not profile.has_animation(animation):
		return
	if animation == profile.death_animation:
		# Death plays exactly once and nothing replaces it afterwards.
		if _death_started:
			return
		_death_started = true
	elif _death_started:
		return
	elif animation == current_animation and not restart:
		return
	current_animation = animation
	play_count += 1
	sprite.play(animation)
	sprite.set_frame_and_progress(0, 0.0)

func _apply_facing() -> void:
	var direction := -1.0 if agent.facing < 0.0 else 1.0
	if not profile.faces_right_by_default:
		direction = -direction
	scale = Vector2(profile.visual_scale.x * direction, profile.visual_scale.y)

func _on_health_changed(current: float, _maximum: float) -> void:
	# A second hit while already hurt does not change the state id, so the lost
	# health is what restarts the reaction.
	if current < _last_health and current_animation == profile.hurt_animation and agent.current_state_id == &"hurt":
		_play(profile.hurt_animation, true)
	_last_health = current
