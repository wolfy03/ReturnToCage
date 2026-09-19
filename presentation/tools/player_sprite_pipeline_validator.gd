class_name PlayerSpritePipelineValidator
extends RefCounted
## Checks that the repository's three sprite artefacts agree with each other:
## the authored manifest, the generated SpriteFrames, and the shipped profile.
##
## Each of them can be committed without the others, and every one of those
## half-states looks fine to a normal test run. A manifest updated without
## regenerating leaves the game shipping yesterday's frames; a profile pointed at
## art whose source was never committed cannot be rebuilt by anyone else. This
## validator exists to make those states loud.
##
## Having no art at all is not one of those states. It is where the project is
## now, and it passes.

const MANIFEST_PATH := "res://assets/characters/player_hamster/player_hamster_sprite_manifest.tres"
const GENERATED_FRAMES_PATH := "res://assets/characters/player_hamster/player_hamster_sprite_frames.tres"
const SHIPPED_PROFILE_PATH := "res://presentation/player/player_animation_profile.tres"

## Loads whatever is actually committed and evaluates it.
static func validate_repository() -> PackedStringArray:
	var manifest: PlayerSpriteManifest = null
	if ResourceLoader.exists(MANIFEST_PATH):
		manifest = ResourceLoader.load(MANIFEST_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as PlayerSpriteManifest
		if manifest == null:
			return PackedStringArray(["%s is not a PlayerSpriteManifest" % MANIFEST_PATH])
	var generated: SpriteFrames = null
	if ResourceLoader.exists(GENERATED_FRAMES_PATH):
		generated = ResourceLoader.load(GENERATED_FRAMES_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as SpriteFrames
		if generated == null:
			return PackedStringArray(["%s is not a SpriteFrames" % GENERATED_FRAMES_PATH])
	var profile := ResourceLoader.load(SHIPPED_PROFILE_PATH, "", ResourceLoader.CACHE_MODE_IGNORE) as CharacterAnimationProfile
	return state_errors(manifest, generated, GENERATED_FRAMES_PATH, profile)

## Pure evaluation, so every state can be exercised without committing art.
## A null [param manifest] or [param generated] means that file is absent;
## [param generated_path] is where the generated resource is expected to live.
static func state_errors(
	manifest: PlayerSpriteManifest,
	generated: SpriteFrames,
	generated_path: String,
	profile: CharacterAnimationProfile
) -> PackedStringArray:
	var errors := PackedStringArray()
	if profile == null:
		errors.append("the shipped animation profile is missing")
		return errors
	for error in profile.validation_errors():
		errors.append("shipped profile: %s" % error)

	var has_manifest := manifest != null
	var has_generated := generated != null
	var profile_uses_art := profile.sprite_frames != null

	if has_manifest:
		for error in manifest.validation_errors():
			errors.append("manifest: %s" % error)
			# A manifest that does not even parse cleanly makes every downstream
			# comparison meaningless, so stop rather than pile on.
		if not errors.is_empty() and not manifest.validation_errors().is_empty():
			return errors

	var production_ready := has_manifest and manifest.production_readiness_errors().is_empty()

	# Generated art nobody can rebuild.
	if has_generated and not has_manifest:
		errors.append("%s exists with no manifest to regenerate it from" % generated_path)
	# A preview artefact parked on the shipped path.
	if has_generated and has_manifest and not production_ready:
		errors.append(
			"%s exists but its manifest is incomplete (missing %s); a preview build must not write the production path"
				% [generated_path, ", ".join(manifest.missing_required_semantics())]
		)
	# Finished source that was never baked.
	if production_ready and not has_generated:
		errors.append("the manifest is complete but %s was not regenerated and committed" % generated_path)
	# Finished art that was never switched on, or switched on halfway.
	if production_ready and has_generated and not profile_uses_art:
		errors.append("production art is committed but the shipped profile still has no sprite_frames")
	if production_ready and has_generated and profile_uses_art and profile.allow_placeholder:
		errors.append("production art is active but the shipped profile still allows the placeholder")
	# A profile switched on without the sources behind it.
	if profile_uses_art and not (production_ready and has_generated):
		errors.append("the shipped profile references sprite_frames without a complete manifest and generated resource behind it")

	if not (production_ready and has_generated and profile_uses_art):
		return errors
	errors.append_array(_production_errors(manifest, generated, generated_path, profile))
	return errors

static func _production_errors(
	manifest: PlayerSpriteManifest,
	generated: SpriteFrames,
	generated_path: String,
	profile: CharacterAnimationProfile
) -> PackedStringArray:
	var errors := PackedStringArray()
	# The profile must use the resource the manifest produces, not some other
	# SpriteFrames that happens to satisfy the animation names.
	if profile.sprite_frames.resource_path != generated_path:
		errors.append(
			"the shipped profile points at '%s' instead of the generated %s"
				% [profile.sprite_frames.resource_path, generated_path]
		)
	# Rebuild from source and compare. This is what catches a manifest or a
	# source sheet that changed without the generated resource being refreshed.
	var rebuilt := PlayerSpriteFramesBuilder.build(manifest)
	if rebuilt == null:
		errors.append("the manifest no longer builds")
	elif PlayerSpriteFramesBuilder.production_signature(rebuilt) \
			!= PlayerSpriteFramesBuilder.production_signature(generated):
		errors.append(
			"%s is stale: rebuilding the manifest produces different clips, regions or source sheets"
				% generated_path
		)
	for semantic in PlayerSpriteManifest.REQUIRED_SEMANTICS:
		if not generated.has_animation(semantic):
			errors.append("the generated resource is missing the '%s' clip" % semantic)
		elif generated.get_frame_count(semantic) <= 0:
			errors.append("generated clip '%s' has no frames" % semantic)
	errors.append_array(frame_integrity_errors(generated))
	for binding in profile.attack_bindings:
		if binding == null or binding.animation_name.is_empty():
			continue
		var count := generated.get_frame_count(binding.animation_name)
		if count <= 0:
			continue
		# The authored partitions were written against a synthetic frame count
		# once; production poses have to be checked against the real one.
		if binding.startup_end_frame <= 0 or binding.startup_end_frame >= binding.active_end_frame:
			errors.append("attack '%s' has no real ACTIVE range" % binding.presentation_key)
		if binding.active_end_frame >= count:
			errors.append(
				"attack '%s' leaves no RECOVERY frames in a %d-frame clip" % [binding.presentation_key, count]
			)
	return errors

## Region sanity shared by the repository check and the presentation tests.
static func frame_integrity_errors(frames: SpriteFrames) -> PackedStringArray:
	var errors := PackedStringArray()
	if frames == null:
		return errors
	var canvas := Vector2.ZERO
	for name in frames.get_animation_names():
		var animation := StringName(name)
		for index in frames.get_frame_count(animation):
			var texture := frames.get_frame_texture(animation, index)
			if texture == null:
				errors.append("'%s' frame %d has no texture" % [animation, index])
				continue
			var atlas := texture as AtlasTexture
			if atlas == null:
				continue
			if atlas.atlas == null:
				errors.append("'%s' frame %d has no source sheet" % [animation, index])
				continue
			if atlas.region.size.x <= 0.0 or atlas.region.size.y <= 0.0:
				errors.append("'%s' frame %d has an empty region" % [animation, index])
				continue
			if atlas.region.position.x < 0.0 or atlas.region.position.y < 0.0 \
					or atlas.region.end.x > float(atlas.atlas.get_width()) \
					or atlas.region.end.y > float(atlas.atlas.get_height()):
				errors.append("'%s' frame %d falls outside its sheet" % [animation, index])
				continue
			if canvas == Vector2.ZERO:
				canvas = atlas.region.size
			elif atlas.region.size != canvas:
				errors.append(
					"'%s' frame %d uses a %dx%d canvas where the rest use %dx%d"
						% [animation, index, atlas.region.size.x, atlas.region.size.y, canvas.x, canvas.y]
				)
	return errors
