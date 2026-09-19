class_name PlayerSpriteManifest
extends Resource
## The authored import contract for one character's sprite sheets.
##
## This, not the PNG file names, is the source of truth for what each sheet
## means. A build tool may emit `player_run.png` or `run_v3.png`; the manifest
## says which clip it is. Presentation-only and never registered in
## [ContentRegistry] — gameplay must not be able to reach a texture through it.
##
## The manifest is an editor/build-time input. It produces a [SpriteFrames] once,
## which is what ships; nothing slices PNGs at spawn time.

## Every clip the presenter needs before production art can replace the
## placeholder. Partial art keeps the placeholder: half a hamster and half a
## polygon is worse than either.
const REQUIRED_SEMANTICS: Array[StringName] = [
	&"idle", &"run", &"jump", &"fall", &"climb", &"climb_idle",
	&"dodge", &"hurt", &"death", &"attack_1", &"attack_2", &"attack_3",
]

@export var animations: Array[PlayerSpriteAnimationEntry] = []
## Which way the source art faces. The presenter flips only the visual child.
@export var faces_right_by_default: bool = true
## Applied by the presentation layer alone. Production sprite pixels and the
## placeholder polygon are wildly different sizes, and that difference must never
## reach collision, hitbox or hurtbox geometry.
@export var visual_scale: Vector2 = Vector2.ONE
@export var visual_position: Vector2 = Vector2.ZERO

func entry(semantic: StringName) -> PlayerSpriteAnimationEntry:
	for animation in animations:
		if animation != null and animation.semantic_name == semantic:
			return animation
	return null

func has_semantic(semantic: StringName) -> bool:
	return entry(semantic) != null

## Which required clips are still missing, in the canonical order above.
func missing_required_semantics() -> Array[StringName]:
	var missing: Array[StringName] = []
	for semantic in REQUIRED_SEMANTICS:
		if not has_semantic(semantic):
			missing.append(semantic)
	return missing

## Whether what is authored here is internally consistent and buildable. A
## manifest with only three clips is structurally valid — it just is not ready
## to ship, which [method production_readiness_errors] answers separately.
func validation_errors() -> PackedStringArray:
	var errors := PackedStringArray()
	var seen: Dictionary[StringName, bool] = {}
	if animations.is_empty():
		errors.append("sprite manifest must author at least one animation")
	for index in animations.size():
		var animation := animations[index]
		if animation == null:
			errors.append("sprite manifest entry %d is null" % index)
			continue
		var owner_id := animation.semantic_name if not animation.semantic_name.is_empty() \
				else StringName("entry %d" % index)
		errors.append_array(animation.validation_errors(owner_id))
		if animation.semantic_name.is_empty():
			continue
		if seen.has(animation.semantic_name):
			errors.append("duplicate sprite manifest semantic '%s'" % animation.semantic_name)
		seen[animation.semantic_name] = true
	if not is_finite(visual_scale.x) or not is_finite(visual_scale.y) \
			or visual_scale.x <= 0.0 or visual_scale.y <= 0.0:
		errors.append("sprite manifest visual_scale must be positive and finite")
	if not is_finite(visual_position.x) or not is_finite(visual_position.y):
		errors.append("sprite manifest visual_position must be finite")
	return errors

## Everything [method validation_errors] checks, plus the completeness a shipped
## profile needs. Activating production art with clips missing is what this
## exists to prevent.
func production_readiness_errors() -> PackedStringArray:
	var errors := validation_errors()
	for semantic in missing_required_semantics():
		errors.append("sprite manifest is missing the required '%s' clip" % semantic)
	return errors

## Advisory notes about sheets that cut evenly but not into the production
## canvas. Never fatal; surfaced by the build tool and the asset checklist.
func preferred_layout_warnings() -> PackedStringArray:
	var warnings := PackedStringArray()
	for animation in animations:
		if animation == null:
			continue
		var owner_id := animation.semantic_name if not animation.semantic_name.is_empty() else &"entry"
		warnings.append_array(animation.preferred_layout_warnings(owner_id))
	return warnings
