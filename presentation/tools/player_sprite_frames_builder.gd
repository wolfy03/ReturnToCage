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

## Everything a committed SpriteFrames must still agree on after the manifest is
## rebuilt from source. Stronger than [method describe] in one way that matters
## for a repository check: it records which texture resource each frame came
## from, so swapping `old_run.png` for `new_run.png` at the same size is caught
## rather than looking identical.
##
## Per-frame duration is recorded for the same reason. A clip's fps lives on the
## animation, but Godot stores a multiplier on every individual frame and the
## editor will happily let someone retime a single one by hand. That edit does
## not come from the manifest, so a rebuild would not reproduce it: recording it
## is what turns it into a stale-resource failure instead of a silent drift.
##
## Pixel content is deliberately not hashed. Repainting a PNG in place changes
## nothing about how it is sliced, so the generated resource is still correct and
## a content hash would only produce churn.
static func production_signature(frames: SpriteFrames) -> Array:
	var signature: Array = []
	if frames == null:
		return signature
	var names := frames.get_animation_names()
	names.sort()
	for name in names:
		var animation := StringName(name)
		var entries: Array = []
		for index in frames.get_frame_count(animation):
			var duration := frames.get_frame_duration(animation, index)
			var atlas := frames.get_frame_texture(animation, index) as AtlasTexture
			if atlas == null or atlas.atlas == null:
				entries.append({
					"region": Rect2(),
					"source": "",
					"atlas_size": Vector2i.ZERO,
					"duration": duration,
				})
				continue
			entries.append({
				"region": atlas.region,
				"source": atlas.atlas.resource_path,
				"atlas_size": Vector2i(atlas.atlas.get_width(), atlas.atlas.get_height()),
				"duration": duration,
			})
		signature.append({
			"name": String(animation),
			"speed": frames.get_animation_speed(animation),
			"loop": frames.get_animation_loop(animation),
			"frame_count": frames.get_frame_count(animation),
			"frames": entries,
		})
	return signature

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
