class_name EnemyAnimationProfile
extends Resource
## Presentation-only animation map for one enemy kind. It stays outside
## data/content and is referenced by path, so ContentRegistry and the headless
## server runtime never load enemy textures.

@export var sprite_frames: SpriteFrames

@export var idle_animation: StringName = &"idle"
@export var move_animation: StringName = &"move"
@export var attack_animation: StringName = &"attack"
@export var hurt_animation: StringName = &"hurt"
@export var death_animation: StringName = &"death"
## Optional airborne clips. Leave empty for enemies that never leave the ground.
@export var jump_start_animation: StringName = &""
@export var jump_animation: StringName = &""
@export var fall_animation: StringName = &""
@export var land_animation: StringName = &""

@export var faces_right_by_default: bool = true
## Applied to the visual child only, never to the actor, its body or hurtbox.
@export var visual_scale: Vector2 = Vector2.ONE
@export var visual_offset: Vector2 = Vector2.ZERO
## Sampling for the sprite only. Nearest suits the small placeholder sheets;
## hand-drawn production sheets that are scaled down need a linear filter.
@export var texture_filter: CanvasItem.TextureFilter = CanvasItem.TEXTURE_FILTER_NEAREST
## First attack frame that shows the strike. The gameplay hit time is owned by
## the enemy's attack state; a test keeps this frame aligned with it.
@export_range(0, 64, 1) var attack_hit_frame: int = 0
## Vertical speed above which the actor is drawn airborne.
@export_range(1.0, 400.0, 1.0) var airborne_speed: float = 30.0
## Horizontal speed above which a grounded actor is drawn moving.
@export_range(0.0, 400.0, 1.0) var move_speed_threshold: float = 8.0

func required_animations() -> Array[StringName]:
	return [idle_animation, move_animation, attack_animation, hurt_animation, death_animation]

func airborne_animations() -> Array[StringName]:
	return [jump_start_animation, jump_animation, fall_animation, land_animation]

func has_animation(animation: StringName) -> bool:
	return sprite_frames != null and not animation.is_empty() and sprite_frames.has_animation(animation)

## Seconds from the start of a clip to the start of the given frame.
func frame_start_seconds(animation: StringName, frame: int) -> float:
	if not has_animation(animation):
		return 0.0
	var speed := sprite_frames.get_animation_speed(animation)
	if speed <= 0.0:
		return 0.0
	var total := 0.0
	for index in mini(frame, sprite_frames.get_frame_count(animation)):
		total += sprite_frames.get_frame_duration(animation, index) / speed
	return total

func animation_seconds(animation: StringName) -> float:
	return frame_start_seconds(animation, sprite_frames.get_frame_count(animation)) if has_animation(animation) else 0.0

func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	if sprite_frames == null:
		errors.append("sprite_frames is missing")
		return errors
	if not is_finite(visual_scale.x) or not is_finite(visual_scale.y) or visual_scale.x <= 0.0 or visual_scale.y <= 0.0:
		errors.append("visual_scale must be positive and finite")
	if not is_finite(visual_offset.x) or not is_finite(visual_offset.y):
		errors.append("visual_offset must be finite")
	for animation in required_animations():
		if not has_animation(animation):
			errors.append("missing required animation: %s" % animation)
	for animation in airborne_animations():
		if not animation.is_empty() and not sprite_frames.has_animation(animation):
			errors.append("missing airborne animation: %s" % animation)
	for animation in sprite_frames.get_animation_names():
		if sprite_frames.get_frame_count(animation) <= 0 or sprite_frames.get_animation_speed(animation) <= 0.0:
			errors.append("animation has no frames or speed: %s" % animation)
			continue
		for index in sprite_frames.get_frame_count(animation):
			if sprite_frames.get_frame_texture(animation, index) == null:
				errors.append("animation %s frame %d has no texture" % [animation, index])
	for animation in [idle_animation, move_animation, jump_animation, fall_animation]:
		if has_animation(animation) and not sprite_frames.get_animation_loop(animation):
			errors.append("held animation must loop: %s" % animation)
	for animation in [attack_animation, hurt_animation, death_animation, jump_start_animation, land_animation]:
		if has_animation(animation) and sprite_frames.get_animation_loop(animation):
			errors.append("one-shot animation must not loop: %s" % animation)
	if has_animation(attack_animation) and attack_hit_frame >= sprite_frames.get_frame_count(attack_animation):
		errors.append("attack_hit_frame is outside the attack animation")
	return errors
