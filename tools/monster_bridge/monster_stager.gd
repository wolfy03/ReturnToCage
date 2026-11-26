extends RefCounted
## Builds the presentation resources of one monster document: a SpriteFrames and
## an EnemyAnimationProfile, written with ResourceSaver.
##
## This is the only part of the monster bridge that writes, and it writes only
## inside a staging copy of the project. The editor makes that copy and puts a
## marker file in it that carries the ID of its staging session. A request is
## refused before anything is created unless the project has that marker *and*
## the request names the same session, so neither the real project nor some
## other copy can be staged into by mistake. All output goes under
## res://monster_stage/<monster_id>/ and nowhere else.
##
## The request comes from another program, so every value is checked here as
## well: a wrong type, NaN, a fraction where a whole number belongs or a path
## that leaves the project ends as INVALID_REQUEST, not as a script error.
##
## Nothing here knows a particular monster. The document says which images,
## clips and roles exist; the carrier actor used for the attach check is any
## registered enemy the caller names.

const Inspector := preload("res://tools/monster_bridge/monster_inspector.gd")
const MARKER := "res://.rtc_monster_staging"
const OUTPUT_ROOT := "res://monster_stage"
const ROLES := ["idle", "move", "attack", "hurt", "death", "jump_start", "jump", "fall", "land"]
const MAX_CLIPS := 128
const MAX_FRAMES := 256
const MAX_IMAGES := 256
const MAX_IMAGE_EXTENT := 8192
const MAX_FPS := 120.0
const MAX_DURATION := 100.0

static func is_staging_project() -> bool:
	return FileAccess.file_exists(MARKER)

## The session ID written into the marker by the editor, or "" when the marker is missing or unreadable.
static func staging_session() -> String:
	if not is_staging_project():
		return ""
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(MARKER))
	if parsed is Dictionary and parsed.get("session") is String:
		return parsed.session
	return ""

static func _fail(code: String, message: String) -> Dictionary:
	return {"error_code": code, "message": message}

static func _valid_id(value: Variant) -> bool:
	if not value is String or value.is_empty() or value.length() > 64:
		return false
	var pattern := RegEx.new()
	pattern.compile("^[a-z][a-z0-9_]*$")
	return pattern.search(value) != null

static func _is_number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

## A whole number in [low, high]. JSON has only one number type, so 3.0 is whole and 3.5 is not.
static func _is_whole(value: Variant, low: int, high: int) -> bool:
	return _is_number(value) and float(value) == floorf(float(value)) and float(value) >= low and float(value) <= high

static func _pair(value: Variant) -> Variant:
	if value is Array and value.size() == 2 and _is_number(value[0]) and _is_number(value[1]):
		return Vector2(float(value[0]), float(value[1]))
	return null

## null when this project may be staged into by this request, else the refusal.
static func _session_refusal(request: Variant) -> Variant:
	if not is_staging_project():
		return _fail("NOT_A_STAGING_PROJECT", "stage operations only run in a staging copy made by the editor")
	var session := staging_session()
	if session.is_empty():
		return _fail("NOT_A_STAGING_PROJECT", "the staging marker carries no session ID")
	if not request is Dictionary or not request.get("staging_session") is String or request.staging_session != session:
		return _fail("STAGING_NOT_OWNED", "the request does not belong to this staging copy's session")
	return null

static func _output_folder(monster_id: String) -> String:
	return "%s/%s" % [OUTPUT_ROOT, monster_id]

## Returns the response data, or {"error_code", "message"} when nothing usable was built.
## ``host`` is a node in the tree; the attach check needs one to ready an actor.
static func stage(monster_id: String, request: Variant, host: Node) -> Dictionary:
	var refusal: Variant = _session_refusal(request)
	if refusal != null:
		return refusal
	if not _valid_id(monster_id):
		return _fail("INVALID_REQUEST", "monster_id is not a valid ID")
	if not request.get("clips") is Array or not request.get("images") is Dictionary \
			or not request.get("presentation") is Dictionary:
		return _fail("INVALID_REQUEST", "stage needs images, clips and presentation")
	var presentation: Dictionary = request.presentation
	var clips: Array = request.clips
	if clips.is_empty() or clips.size() > MAX_CLIPS:
		return _fail("INVALID_REQUEST", "stage needs between 1 and %d clips" % MAX_CLIPS)
	if request.images.size() > MAX_IMAGES:
		return _fail("INVALID_REQUEST", "stage accepts at most %d images" % MAX_IMAGES)
	if request.has("carrier") and not request.carrier is String:
		return _fail("INVALID_REQUEST", "carrier is not a monster ID")

	var textures := {}
	for image_id: Variant in request.images:
		var relative: Variant = request.images[image_id]
		if not _valid_id(image_id):
			return _fail("INVALID_REQUEST", "image ID %s is not a valid ID" % str(image_id))
		if not relative is String or relative.is_empty() or relative.contains("..") or relative.begins_with("/") \
				or relative.contains(":") or relative.contains("\\") or relative.contains("//") \
				or not relative.to_lower().ends_with(".png"):
			return _fail("INVALID_REQUEST", "image %s has an unusable path" % str(image_id))
		var texture := ResourceLoader.load("res://" + relative, "Texture2D") as Texture2D
		if texture == null:
			return _fail("RESOURCE_MISSING", "Godot cannot load res://%s as a texture" % relative)
		textures[image_id] = texture

	var frames := SpriteFrames.new()
	for existing in frames.get_animation_names():
		frames.remove_animation(existing)
	for clip: Variant in clips:
		if not clip is Dictionary or not _valid_id(clip.get("id")) or not clip.get("frames") is Array \
				or not _is_number(clip.get("fps")) or not clip.get("loop") is bool:
			return _fail("INVALID_REQUEST", "a clip is malformed")
		var name := StringName(String(clip.id))
		if frames.has_animation(name) or clip.frames.is_empty() or clip.frames.size() > MAX_FRAMES \
				or float(clip.fps) <= 0.0 or float(clip.fps) > MAX_FPS:
			return _fail("INVALID_REQUEST", "clip %s is duplicated, empty or has no usable fps" % clip.id)
		frames.add_animation(name)
		frames.set_animation_speed(name, float(clip.fps))
		frames.set_animation_loop(name, clip.loop)
		for frame: Variant in clip.frames:
			if not frame is Dictionary or not frame.get("image") is String or not textures.has(frame.image) \
					or not _is_number(frame.get("duration")) or float(frame.duration) <= 0.0 \
					or float(frame.duration) > MAX_DURATION:
				return _fail("INVALID_REQUEST", "clip %s has a malformed frame" % clip.id)
			var source: Texture2D = textures[frame.image]
			var picture: Texture2D = source
			var rect: Variant = frame.get("rect")
			if rect != null:
				if not rect is Array or rect.size() != 4:
					return _fail("INVALID_REQUEST", "clip %s has a malformed frame rect" % clip.id)
				for value: Variant in rect:
					# Pixels are whole numbers. A fraction would be drawn, but not as the document says.
					if not _is_whole(value, 0, MAX_IMAGE_EXTENT):
						return _fail("INVALID_REQUEST", "clip %s has a frame rect that is not whole pixels" % clip.id)
				var region := Rect2(float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]))
				if region.size.x <= 0.0 or region.size.y <= 0.0 \
						or region.end.x > source.get_width() or region.end.y > source.get_height():
					return _fail("INVALID_REQUEST", "clip %s has a frame outside its image" % clip.id)
				var atlas := AtlasTexture.new()
				atlas.atlas = source
				atlas.region = region
				picture = atlas
			frames.add_frame(name, picture, float(frame.duration))

	# Everything about the profile is checked before the first file is written.
	var roles: Variant = presentation.get("roles")
	if not roles is Dictionary:
		return _fail("INVALID_REQUEST", "presentation.roles is missing")
	for role: String in ROLES:
		var clip_id: Variant = roles.get(role, "")
		if not clip_id is String or (not clip_id.is_empty() and not frames.has_animation(StringName(clip_id))):
			return _fail("INVALID_REQUEST", "role %s does not name a staged clip" % role)
	var scale: Variant = _pair(presentation.get("visual_scale"))
	var offset: Variant = _pair(presentation.get("visual_offset"))
	if scale == null or offset == null or scale.x <= 0.0 or scale.y <= 0.0 \
			or not presentation.get("faces_right_by_default") is bool:
		return _fail("INVALID_REQUEST", "presentation has no usable scale, offset or facing")
	if not _is_whole(presentation.get("attack_hit_frame", 0), 0, 64):
		return _fail("INVALID_REQUEST", "attack_hit_frame is not a whole number in [0, 64]")
	for key: String in ["airborne_speed", "move_speed_threshold"]:
		if presentation.has(key) and (not _is_number(presentation[key]) or float(presentation[key]) < 0.0):
			return _fail("INVALID_REQUEST", "%s is not a usable speed" % key)
	var filter: Variant = request.get("texture_filter")
	if filter != null and not _is_whole(filter, 0, CanvasItem.TEXTURE_FILTER_MAX - 1):
		return _fail("INVALID_REQUEST", "texture_filter is not a CanvasItem.TextureFilter value")

	var folder := _output_folder(monster_id)
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder)) != OK:
		return _fail("EXPORT_FAILED", "cannot create %s" % folder)
	var frames_path := folder + "/sprite_frames.tres"
	var profile_path := folder + "/animation_profile.tres"
	# An earlier attempt may have died half-way. Its files must not be mistaken for this run's.
	for stale: String in [frames_path, profile_path]:
		if FileAccess.file_exists(stale) and DirAccess.remove_absolute(ProjectSettings.globalize_path(stale)) != OK:
			return _fail("EXPORT_FAILED", "cannot replace %s" % stale)
	if ResourceSaver.save(frames, frames_path) != OK:
		return _fail("EXPORT_FAILED", "cannot save %s" % frames_path)

	var profile := EnemyAnimationProfile.new()
	# Loaded back from the file just written, so the profile references it instead of embedding a copy.
	profile.sprite_frames = ResourceLoader.load(frames_path, "SpriteFrames", ResourceLoader.CACHE_MODE_REPLACE) as SpriteFrames
	if profile.sprite_frames == null:
		return _fail("EXPORT_FAILED", "the saved SpriteFrames does not load")
	for role: String in ROLES:
		profile.set(role + "_animation", StringName(String(roles.get(role, ""))))
	profile.visual_scale = scale
	profile.visual_offset = offset
	profile.faces_right_by_default = presentation.faces_right_by_default
	profile.attack_hit_frame = int(presentation.get("attack_hit_frame", 0))
	profile.airborne_speed = float(presentation.get("airborne_speed", profile.airborne_speed))
	profile.move_speed_threshold = float(presentation.get("move_speed_threshold", profile.move_speed_threshold))
	if filter != null:
		profile.texture_filter = int(filter) as CanvasItem.TextureFilter
	if ResourceSaver.save(profile, profile_path) != OK:
		return _fail("EXPORT_FAILED", "cannot save %s" % profile_path)

	return {
		"monster_id": monster_id,
		"staging_session": staging_session(),
		"sprite_frames_path": frames_path,
		"profile_path": profile_path,
		"profile": Inspector.profile(profile_path),
		"attach": _attach(profile_path, String(request.get("carrier", "")), host),
	}

## Reads a staged profile back from the files. The editor runs this in a process
## of its own, after the one that built the resources has exited, so what is
## described is what is on disk.
static func read_back(monster_id: String, request: Variant) -> Dictionary:
	var refusal: Variant = _session_refusal(request)
	if refusal != null:
		return refusal
	if not _valid_id(monster_id):
		return _fail("INVALID_REQUEST", "monster_id is not a valid ID")
	var folder := _output_folder(monster_id)
	var frames_path := folder + "/sprite_frames.tres"
	var profile_path := folder + "/animation_profile.tres"
	for path: String in [frames_path, profile_path]:
		if not FileAccess.file_exists(path):
			return _fail("RESOURCE_MISSING", "%s was not staged" % path)
	return {
		"monster_id": monster_id,
		"staging_session": staging_session(),
		"profile": Inspector.profile(profile_path),
		"resources": {frames_path: FileAccess.get_sha256(frames_path), profile_path: FileAccess.get_sha256(profile_path)},
	}

## Readies a registered enemy actor with the staged profile and reports what it drew with,
## then the same actor as the server runtime creates it, which must build no visual at all.
static func _attach(profile_path: String, carrier: String, host: Node) -> Dictionary:
	var definition: EnemyDefinition = null
	for candidate in Inspector.enemy_definitions():
		if candidate.actor_scene != null and (carrier.is_empty() or String(candidate.id) == carrier):
			definition = candidate
			break
	if definition == null:
		return {"evaluated": false, "reason": "no registered enemy actor to carry the profile"}
	var result := {"evaluated": true, "carrier": String(definition.id)}
	for mode: String in ["presentation", "server"]:
		var actor := definition.actor_scene.instantiate() as EnemyAgent
		if actor == null:
			return {"evaluated": false, "reason": "%s has no EnemyAgent actor" % definition.id}
		actor.setup_enemy(definition, 1, false, &"", mode == "presentation")
		actor.animation_profile_path = profile_path
		host.add_child(actor)
		var presenter := actor.animation_presenter
		var row := {"has_presenter": presenter != null}
		if presenter != null and presenter.sprite != null:
			var sprite := presenter.sprite
			var animation := sprite.animation
			row["sprite_frames_path"] = sprite.sprite_frames.resource_path if sprite.sprite_frames != null else ""
			row["animation"] = String(animation)
			row["frame_has_texture"] = sprite.sprite_frames != null and sprite.sprite_frames.has_animation(animation) \
				and sprite.sprite_frames.get_frame_count(animation) > 0 \
				and sprite.sprite_frames.get_frame_texture(animation, 0) != null
			row["sprite_position"] = [sprite.position.x, sprite.position.y]
			row["presenter_scale"] = [presenter.scale.x, presenter.scale.y]
			row["texture_filter"] = int(sprite.texture_filter)
		result[mode] = row
		host.remove_child(actor)
		actor.free()
	return result
