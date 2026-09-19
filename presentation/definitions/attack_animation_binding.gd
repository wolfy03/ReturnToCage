class_name AttackAnimationBinding
extends Resource
## Presentation-only mapping from an AttackDefinition semantic key to one
## SpriteFrames clip and its gameplay-phase frame partitions.

@export var presentation_key: StringName
@export var animation_name: StringName
@export_range(1, 128, 1) var startup_end_frame: int = 1
@export_range(2, 128, 1) var active_end_frame: int = 2

func validation_errors(sprite_frames: SpriteFrames = null, owner_id: StringName = &"") -> PackedStringArray:
	var errors := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	if presentation_key.is_empty():
		errors.append("%sattack animation presentation_key must not be empty" % prefix)
	if animation_name.is_empty():
		errors.append("%sattack animation_name must not be empty" % prefix)
	if startup_end_frame <= 0:
		errors.append("%sattack startup frame range must not be empty" % prefix)
	if active_end_frame <= startup_end_frame:
		errors.append("%sattack active frame range must not be empty" % prefix)
	if sprite_frames == null or animation_name.is_empty():
		return errors
	if not sprite_frames.has_animation(animation_name):
		errors.append("%sattack animation '%s' is missing" % [prefix, animation_name])
		return errors
	var frame_count := sprite_frames.get_frame_count(animation_name)
	if frame_count <= 0:
		errors.append("%sattack animation '%s' must contain frames" % [prefix, animation_name])
	elif active_end_frame >= frame_count:
		errors.append("%sattack recovery frame range must not be empty" % prefix)
	return errors

