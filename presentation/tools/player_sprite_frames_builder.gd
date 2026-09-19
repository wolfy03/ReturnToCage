class_name PlayerSpriteFramesBuilder
extends RefCounted
## Turns a [PlayerSpriteManifest] into the [SpriteFrames] the game ships.
##
## Build-time only. Slicing PNGs on every player spawn would put texture work on
## the gameplay path and give a headless server a reason to load art, so the
## result is generated once and committed as a resource.
##
## The build is deterministic: the same manifest always yields the same
## animation order, frame order, regions, speeds and loop flags. That is what
## makes "regenerate and diff" a meaningful check after an art re-export.

## Builds the frames, or returns null when the manifest does not validate.
## Callers that want to know why should ask the manifest.
static func build(manifest: PlayerSpriteManifest) -> SpriteFrames:
	if manifest == null or not manifest.validation_errors().is_empty():
		return null
	var frames := SpriteFrames.new()
	# A fresh SpriteFrames ships with a "default" clip. Dropping it keeps the
	# output exactly the set of clips the manifest authored.
	if frames.has_animation(&"default"):
		frames.remove_animation(&"default")
	for animation in manifest.animations:
		_add_animation(frames, animation)
	return frames

## A compact, comparable description of a built resource: what two builds of the
## same manifest must agree on, and what a regenerated resource is diffed
## against. Regions are included because a shifted grid is the failure that is
## hardest to see by eye.
static func describe(frames: SpriteFrames) -> Array:
	var description: Array = []
	if frames == null:
		return description
	var names := frames.get_animation_names()
	names.sort()
	for name in names:
		var animation := StringName(name)
		var regions: Array = []
		for index in frames.get_frame_count(animation):
			var texture := frames.get_frame_texture(animation, index)
			var atlas := texture as AtlasTexture
			regions.append(atlas.region if atlas != null else Rect2())
		description.append({
			"name": String(animation),
			"speed": frames.get_animation_speed(animation),
			"loop": frames.get_animation_loop(animation),
			"regions": regions,
		})
	return description

static func _add_animation(frames: SpriteFrames, entry: PlayerSpriteAnimationEntry) -> void:
	if entry == null or entry.semantic_name.is_empty():
		return
	var animation := entry.semantic_name
	if not frames.has_animation(animation):
		frames.add_animation(animation)
	frames.set_animation_speed(animation, entry.fps)
	frames.set_animation_loop(animation, entry.loop)
	for index in entry.frame_count:
		var atlas := AtlasTexture.new()
		atlas.atlas = entry.texture
		atlas.region = entry.region_for(index)
		frames.add_frame(animation, atlas)
