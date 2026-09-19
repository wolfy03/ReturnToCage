class_name PlayerAnimationPresenter
extends Node2D
## Read-only adapter from PlayerActor gameplay/network presentation signals to
## visual state. It never changes combat, movement, damage, stamina or physics.

enum Transient { NONE, ATTACK, DODGE, HURT }

const RUN_VELOCITY_THRESHOLD := 5.0
const PRESENTATION_EPSILON := 0.0001

@export var profile: CharacterAnimationProfile
@onready var sprite: AnimatedSprite2D = %Sprite
@onready var placeholder: Node2D = %PlaceholderVisual

var actor: PlayerActor
var _current_animation: StringName
var _current_frame: int = 0
var _remote_transient: Transient = Transient.NONE
var _remote_elapsed: float = 0.0
var _remote_duration: float = 0.0
var _attack_key: StringName
var _attack_combo_step: int = 0
var _attack_facing: float = 1.0
var _attack_startup: float = 0.0
var _attack_active: float = 0.0
var _attack_recovery: float = 0.0
var _dodge_direction: float = 1.0
var _restart_requested: bool = false
var _base_scale_x: float = 1.0
var _warned_missing: Dictionary[StringName, bool] = {}

func configure(p_actor: PlayerActor) -> void:
	_disconnect_actor()
	actor = p_actor
	_base_scale_x = maxf(absf(scale.x), PRESENTATION_EPSILON)
	_apply_profile()
	if actor == null:
		set_process(false)
		return
	actor.attack_presented.connect(_on_attack_presented)
	actor.dodge_presented.connect(_on_dodge_presented)
	actor.hurt_presented.connect(_on_hurt_presented)
	set_process(true)
	refresh(0.0)

func _exit_tree() -> void:
	_disconnect_actor()

func _disconnect_actor() -> void:
	if actor == null:
		return
	if actor.attack_presented.is_connected(_on_attack_presented):
		actor.attack_presented.disconnect(_on_attack_presented)
	if actor.dodge_presented.is_connected(_on_dodge_presented):
		actor.dodge_presented.disconnect(_on_dodge_presented)
	if actor.hurt_presented.is_connected(_on_hurt_presented):
		actor.hurt_presented.disconnect(_on_hurt_presented)

func _process(delta: float) -> void:
	refresh(delta)

## Public deterministic entry point used by tests and by the render callback.
func refresh(delta: float = 0.0) -> void:
	if actor == null or profile == null:
		return
	if not actor.is_simulation_authority():
		_advance_remote_transient(delta)
	_resolve_presentation()

func current_animation() -> StringName:
	return _current_animation

func current_frame() -> int:
	return _current_frame

func current_transient() -> Transient:
	if _is_dead():
		return Transient.NONE
	if actor != null and actor.is_simulation_authority():
		if actor.combat_action.is_hurt():
			return Transient.HURT
		if actor.combat_action.is_dodging():
			return Transient.DODGE
		if actor.combat_action.is_attacking():
			return Transient.ATTACK
	return _remote_transient

func current_combo_step() -> int:
	return _attack_combo_step

func _apply_profile() -> void:
	if sprite == null or placeholder == null:
		return
	var has_frames := profile != null and profile.sprite_frames != null
	sprite.visible = has_frames
	placeholder.visible = not has_frames
	if has_frames:
		sprite.sprite_frames = profile.sprite_frames

func _resolve_presentation() -> void:
	if _is_dead():
		_apply_animation(profile.death_animation, false, 0)
		_apply_facing(actor.facing)
		return
	if actor.is_simulation_authority():
		if actor.combat_action.is_hurt():
			var hurt_elapsed := actor.hurt.elapsed_seconds()
			_apply_timed_animation(profile.hurt_animation, hurt_elapsed, actor.hurt.duration_seconds)
			_apply_facing(actor.facing)
			return
		if actor.combat_action.is_dodging():
			_apply_timed_animation(profile.dodge_animation, actor.dodge.elapsed, actor.dodge.total_duration())
			_apply_facing(actor.dodge.direction)
			return
		if actor.combat_action.is_attacking():
			_apply_attack(actor.combat.attack_elapsed())
			_apply_facing(actor.combat.current_attack_facing())
			return
	else:
		match _remote_transient:
			Transient.HURT:
				_apply_timed_animation(profile.hurt_animation, _remote_elapsed, _remote_duration)
				_apply_facing(actor.facing)
				return
			Transient.DODGE:
				_apply_timed_animation(profile.dodge_animation, _remote_elapsed, _remote_duration)
				_apply_facing(_dodge_direction)
				return
			Transient.ATTACK:
				_apply_attack(_remote_elapsed)
				_apply_facing(_attack_facing)
				return
	_apply_locomotion()

func _apply_locomotion() -> void:
	var animation := profile.idle_animation
	var ignore_facing := false
	match actor.movement.mode:
		MovementComponent.Mode.CLIMB:
			ignore_facing = profile.climb_ignores_facing
			animation = profile.climb_animation if absf(actor.velocity.y) > PRESENTATION_EPSILON \
					else profile.climb_idle_animation
		MovementComponent.Mode.AIR:
			animation = profile.jump_animation if actor.velocity.y < 0.0 else profile.fall_animation
		MovementComponent.Mode.GROUND:
			animation = profile.run_animation if absf(actor.velocity.x) > RUN_VELOCITY_THRESHOLD \
					else profile.idle_animation
	_apply_animation(animation, false, 0)
	_apply_facing(1.0 if ignore_facing and profile.faces_right_by_default else actor.facing)

func _apply_attack(elapsed: float) -> void:
	var key := _attack_key
	var startup := _attack_startup
	var active := _attack_active
	var recovery := _attack_recovery
	if actor.is_simulation_authority():
		var definition := actor.combat.current_attack_definition()
		if definition != null:
			key = definition.presentation_key
			startup = definition.startup_seconds
			active = definition.active_seconds
			recovery = definition.recovery_seconds
	var binding := profile.attack_binding(key)
	if binding == null:
		_warn_missing(key)
		_apply_animation(profile.idle_animation, false, 0)
		return
	if profile.sprite_frames == null:
		_apply_animation(binding.animation_name, true, 0)
		return
	var frame_count := _frame_count(binding.animation_name)
	if frame_count <= 0:
		_warn_missing(binding.animation_name)
		_apply_animation(profile.idle_animation, false, 0)
		return
	_apply_animation(
		binding.animation_name,
		true,
		attack_frame(elapsed, startup, active, recovery, binding, frame_count)
	)

func _apply_timed_animation(animation: StringName, elapsed: float, duration: float) -> void:
	var frame_count := _frame_count(animation)
	var frame := timed_frame(elapsed, duration, frame_count) if frame_count > 0 else 0
	_apply_animation(animation, true, frame)

func _apply_animation(animation: StringName, timed: bool, frame: int) -> void:
	var changed := animation != _current_animation
	_current_animation = animation
	_current_frame = maxi(0, frame)
	if sprite == null or profile.sprite_frames == null:
		_restart_requested = false
		return
	var resolved := animation
	if resolved.is_empty() or not profile.sprite_frames.has_animation(resolved) \
			or profile.sprite_frames.get_frame_count(resolved) <= 0:
		_warn_missing(resolved)
		resolved = profile.idle_animation
	if resolved.is_empty() or not profile.sprite_frames.has_animation(resolved) \
			or profile.sprite_frames.get_frame_count(resolved) <= 0:
		sprite.visible = false
		placeholder.visible = true
		_restart_requested = false
		return
	if changed or _restart_requested or sprite.animation != resolved:
		sprite.play(resolved)
	if timed:
		sprite.pause()
		sprite.frame = mini(_current_frame, profile.sprite_frames.get_frame_count(resolved) - 1)
	elif changed or _restart_requested:
		sprite.play(resolved)
	_restart_requested = false

func _apply_facing(committed_facing: float) -> void:
	if not is_finite(committed_facing) or committed_facing == 0.0:
		return
	var faces_right := committed_facing > 0.0
	var normal := faces_right == profile.faces_right_by_default
	scale.x = _base_scale_x if normal else -_base_scale_x

func _advance_remote_transient(delta: float) -> void:
	if _remote_transient == Transient.NONE or delta <= 0.0:
		return
	_remote_elapsed += delta
	if _remote_elapsed + PRESENTATION_EPSILON >= _remote_duration:
		_remote_transient = Transient.NONE
		_remote_elapsed = 0.0
		_remote_duration = 0.0

func _on_attack_presented(
	_sequence: int,
	facing: float,
	combo_step: int,
	presentation_key: StringName,
	startup_seconds: float,
	active_seconds: float,
	recovery_seconds: float
) -> void:
	if not actor.is_simulation_authority() and _remote_transient > Transient.ATTACK:
		return
	_attack_facing = facing
	_attack_combo_step = combo_step
	_attack_key = presentation_key
	_attack_startup = startup_seconds
	_attack_active = active_seconds
	_attack_recovery = recovery_seconds
	_remote_elapsed = 0.0
	_remote_duration = startup_seconds + active_seconds + recovery_seconds
	if not actor.is_simulation_authority():
		_remote_transient = Transient.ATTACK
	_restart_requested = true

func _on_dodge_presented(_sequence: int, direction: float, duration_seconds: float) -> void:
	if not actor.is_simulation_authority() and _remote_transient > Transient.DODGE:
		return
	_dodge_direction = direction
	_remote_elapsed = 0.0
	_remote_duration = duration_seconds
	if not actor.is_simulation_authority():
		_remote_transient = Transient.DODGE
	_restart_requested = true

func _on_hurt_presented(_sequence: int, duration_seconds: float) -> void:
	_remote_elapsed = 0.0
	_remote_duration = duration_seconds
	if not actor.is_simulation_authority():
		_remote_transient = Transient.HURT
	_restart_requested = true

func _is_dead() -> bool:
	return actor != null and (actor.is_death_handled() or actor.health.current_health <= 0.0)

func _frame_count(animation: StringName) -> int:
	if profile == null or profile.sprite_frames == null or animation.is_empty() \
			or not profile.sprite_frames.has_animation(animation):
		return 0
	return profile.sprite_frames.get_frame_count(animation)

func _warn_missing(key: StringName) -> void:
	if key.is_empty() or _warned_missing.has(key):
		return
	_warned_missing[key] = true
	print("[PRESENTATION] Missing player animation mapping: %s" % key)

static func timed_frame(elapsed: float, duration: float, frame_count: int) -> int:
	if frame_count <= 1 or not is_finite(elapsed) or not is_finite(duration) or duration <= 0.0:
		return 0
	return _frame_in_range(elapsed / duration, 0, frame_count)

static func attack_frame(
	elapsed: float,
	startup: float,
	active: float,
	recovery: float,
	binding: AttackAnimationBinding,
	frame_count: int
) -> int:
	if binding == null or frame_count <= 0 or not is_finite(elapsed) \
			or startup <= 0.0 or active <= 0.0 or recovery <= 0.0:
		return 0
	if elapsed < startup:
		return _frame_in_range(elapsed / startup, 0, binding.startup_end_frame)
	if elapsed < startup + active:
		return _frame_in_range(
			(elapsed - startup) / active,
			binding.startup_end_frame,
			binding.active_end_frame
		)
	return _frame_in_range(
		(elapsed - startup - active) / recovery,
		binding.active_end_frame,
		frame_count
	)

static func _frame_in_range(progress: float, start: int, end_exclusive: int) -> int:
	var count := end_exclusive - start
	if count <= 0:
		return maxi(0, start)
	var bounded := clampf(progress, 0.0, 0.999999)
	return start + mini(int(floor(bounded * count)), count - 1)
