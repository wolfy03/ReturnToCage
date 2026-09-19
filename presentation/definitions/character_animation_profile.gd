class_name CharacterAnimationProfile
extends Resource
## Reusable presentation-only semantic animation map. This stays outside
## data/content so a headless server never discovers or loads visual assets via
## ContentRegistry.

@export var sprite_frames: SpriteFrames

@export var idle_animation: StringName = &"idle"
@export var run_animation: StringName = &"run"
@export var jump_animation: StringName = &"jump"
@export var fall_animation: StringName = &"fall"
@export var climb_animation: StringName = &"climb"
@export var climb_idle_animation: StringName = &"climb_idle"
@export var dodge_animation: StringName = &"dodge"
@export var hurt_animation: StringName = &"hurt"
@export var death_animation: StringName = &"death"

@export var faces_right_by_default: bool = true
@export var climb_ignores_facing: bool = true
@export var attack_bindings: Array[AttackAnimationBinding] = []
@export var allow_placeholder: bool = true

func attack_binding(presentation_key: StringName) -> AttackAnimationBinding:
	for binding in attack_bindings:
		if binding != null and binding.presentation_key == presentation_key:
			return binding
	return null

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var seen: Dictionary[StringName, bool] = {}
	for index in attack_bindings.size():
		var binding := attack_bindings[index]
		if binding == null:
			errors.append("attack animation binding %d is null" % index)
			continue
		errors.append_array(binding.validation_errors(
			sprite_frames,
			StringName("attack binding %d" % index)
		))
		if not binding.presentation_key.is_empty():
			if seen.has(binding.presentation_key):
				errors.append("duplicate attack presentation key '%s'" % binding.presentation_key)
			seen[binding.presentation_key] = true
	if sprite_frames == null:
		if not allow_placeholder:
			errors.append("sprite_frames is required when placeholder presentation is disabled")
		return errors
	for entry in [
		["idle", idle_animation],
		["run", run_animation],
		["jump", jump_animation],
		["fall", fall_animation],
		["climb", climb_animation],
		["climb_idle", climb_idle_animation],
		["dodge", dodge_animation],
		["hurt", hurt_animation],
		["death", death_animation],
	]:
		var semantic: String = entry[0]
		var animation: StringName = entry[1]
		if animation.is_empty():
			errors.append("%s animation name must not be empty" % semantic)
		elif not sprite_frames.has_animation(animation):
			errors.append("%s animation '%s' is missing" % [semantic, animation])
		elif sprite_frames.get_frame_count(animation) <= 0:
			errors.append("%s animation '%s' must contain frames" % [semantic, animation])
	return errors

