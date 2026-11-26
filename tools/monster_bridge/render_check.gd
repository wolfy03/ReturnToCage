extends Node
## Draws a staged monster with the real renderer and saves what was drawn.
##
##   godot --path <staging copy> res://tools/monster_bridge/render_check.tscn -- --request <request.json>
##
## Run WITHOUT --headless: a headless engine has no renderer and this scene then
## reports NOT_EVALUATED instead of pretending. Like every writing part of the
## monster bridge it only runs in a staging copy whose marker carries the
## request's staging session, and it writes exactly: the result file, and PNG
## screenshots into the output folder the editor created for this run.
##
## What is drawn is the real thing, not a reconstruction: a registered enemy
## actor (the "carrier"), readied with the staged EnemyAnimationProfile, so the
## sprite is the one EnemyAnimationPresenter builds, with the profile's scale,
## offset, facing rule and texture filter. The actor's simulation is off; this
## scene only chooses which clip, frame and facing are on screen.
##
## The optional collision overlay draws shapes from the *document*. It is a
## verification aid. The game does not use the document's hitboxes or per-frame
## hurtboxes in MONSTER-STEP 3, and a drawn overlay does not mean it does.

const Inspector := preload("res://tools/monster_bridge/monster_inspector.gd")
const Stager := preload("res://tools/monster_bridge/monster_stager.gd")
const PROTOCOL := 1
const MAX_SHOTS := 256
const KIND_COLORS := {"body": Color("5aa9e6"), "hurtbox": Color("7fd18b"), "override": Color("d9a03f"), "hitbox": Color("e0605f")}

var _request: Dictionary = {}
var _viewport: SubViewport
var _actor: EnemyAgent
var _overlay: Node2D

class Overlay extends Node2D:
	var shapes: Array = []
	var facing := 1.0

	func _draw() -> void:
		for row: Variant in shapes:
			var shape: Dictionary = row.shape
			var color: Color = KIND_COLORS.get(String(row.get("kind", "")), Color.WHITE)
			var center := Vector2(float(shape.center[0]) * facing, float(shape.center[1]))
			if String(shape.type) == "circle":
				draw_arc(center, float(shape.radius), 0.0, TAU, 48, color, 1.0)
			else:
				var size := Vector2(float(shape.size[0]), float(shape.size[1]))
				draw_rect(Rect2(center - size / 2.0, size), color, false, 1.0)

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--request":
		push_error("render check needs: --request <request.json>")
		get_tree().quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	if not parsed is Dictionary or not parsed.get("result_path") is String or not parsed.get("request_id") is String:
		push_error("render check request is malformed")
		get_tree().quit(2)
		return
	_request = parsed
	if int(_request.get("protocol", 0)) != PROTOCOL:
		_finish({}, "PROTOCOL_MISMATCH", "render check speaks protocol %d" % PROTOCOL)
		return
	var refusal: Variant = Stager._session_refusal(_request)
	if refusal != null:
		_finish({}, String(refusal.error_code), String(refusal.message))
		return
	if DisplayServer.get_name() == "headless":
		_finish({}, "NO_RENDERER", "the engine was started headless; nothing can be rendered")
		return
	var problem := _validate()
	if not problem.is_empty():
		_finish({}, "INVALID_REQUEST", problem)
		return
	await _run()

func _validate() -> String:
	if not Stager._valid_id(_request.get("monster_id")):
		return "monster_id is not a valid ID"
	if not _request.get("output_dir") is String or not DirAccess.dir_exists_absolute(_request.output_dir):
		return "output_dir does not exist"
	var size: Variant = _request.get("size")
	if not size is Array or size.size() != 2 or not Stager._is_whole(size[0], 32, 2048) or not Stager._is_whole(size[1], 32, 2048):
		return "size is not two whole numbers in [32, 2048]"
	if not Stager._is_number(_request.get("zoom")) or float(_request.zoom) <= 0.0 or float(_request.zoom) > 64.0:
		return "zoom is not a number in (0, 64]"
	if _request.has("carrier") and not _request.carrier is String:
		return "carrier is not a monster ID"
	var shots: Variant = _request.get("shots")
	if not shots is Array or shots.is_empty() or shots.size() > MAX_SHOTS:
		return "shots must list between 1 and %d shots" % MAX_SHOTS
	for shot: Variant in shots:
		if not shot is Dictionary or not Stager._valid_id(shot.get("name")) or not Stager._valid_id(shot.get("clip")) \
				or not Stager._is_whole(shot.get("frame"), 0, 255) or not Stager._is_number(shot.get("facing")) \
				or absf(float(shot.facing)) != 1.0:
			return "a shot is malformed"
		if shot.has("shapes") and not _shapes_ok(shot.shapes):
			return "a shot has malformed overlay shapes"
	for timing: Variant in _request.get("timings", []):
		if not timing is Dictionary or not Stager._valid_id(timing.get("clip")) or not Stager._is_number(timing.get("seconds")) \
				or float(timing.seconds) <= 0.0 or float(timing.seconds) > 20.0:
			return "a timing request is malformed"
	return ""

func _shapes_ok(shapes: Variant) -> bool:
	if not shapes is Array or shapes.size() > 128:
		return false
	for row: Variant in shapes:
		if not row is Dictionary or not row.get("shape") is Dictionary:
			return false
		var shape: Dictionary = row.shape
		var center: Variant = Stager._pair(shape.get("center"))
		if center == null:
			return false
		if shape.get("type") == "circle":
			if not Stager._is_number(shape.get("radius")) or float(shape.radius) <= 0.0:
				return false
		elif shape.get("type") == "rectangle":
			var size: Variant = Stager._pair(shape.get("size"))
			if size == null or size.x <= 0.0 or size.y <= 0.0:
				return false
		else:
			return false
	return true

func _run() -> void:
	var monster_id := String(_request.monster_id)
	var profile_path := "%s/animation_profile.tres" % Stager._output_folder(monster_id)
	if not FileAccess.file_exists(profile_path):
		_finish({}, "RESOURCE_MISSING", "%s was not staged" % profile_path)
		return
	var carrier := String(_request.get("carrier", ""))
	var definition: EnemyDefinition = null
	for candidate in Inspector.enemy_definitions():
		if candidate.actor_scene != null and (carrier.is_empty() or String(candidate.id) == carrier):
			definition = candidate
			break
	if definition == null:
		_finish({}, "UNKNOWN_MONSTER", "no registered enemy actor named '%s' to carry the profile" % carrier)
		return

	var size := Vector2i(int(_request.size[0]), int(_request.size[1]))
	var zoom := float(_request.zoom)
	_viewport = SubViewport.new()
	_viewport.size = size
	_viewport.world_2d = World2D.new()            # its own canvas and physics space
	_viewport.transparent_bg = true               # the screenshot keeps alpha; the editor composes the background
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_viewport.snap_2d_transforms_to_pixel = false
	_viewport.canvas_transform = Transform2D(0.0, Vector2(zoom, zoom), 0.0, Vector2(size) / 2.0)   # actor origin = centre
	add_child(_viewport)

	_actor = definition.actor_scene.instantiate() as EnemyAgent
	if _actor == null:
		_finish({}, "UNKNOWN_MONSTER", "%s has no EnemyAgent actor" % definition.id)
		return
	_actor.setup_enemy(definition, 1, false, &"", true)       # not simulated: nothing moves it but this scene
	_actor.animation_profile_path = profile_path
	_viewport.add_child(_actor)
	_actor.position = Vector2.ZERO
	_actor.set_physics_process(false)
	var presenter := _actor.animation_presenter
	if presenter == null or presenter.sprite == null:
		_finish({}, "EXPORT_FAILED", "the carrier built no animation presenter from the staged profile")
		return
	var sprite := presenter.sprite
	var profile := presenter.profile

	# ---- which clip the real presenter picks for each state it knows
	var selection := _role_selection(presenter)
	presenter.set_process(false)                  # from here on this scene decides what is shown

	_overlay = Overlay.new()
	_overlay.z_index = 100
	_viewport.add_child(_overlay)

	var results: Array[Dictionary] = []
	for shot: Dictionary in _request.shots:
		var clip := StringName(String(shot.clip))
		var row := {"name": String(shot.name), "clip": String(shot.clip), "frame": int(shot.frame), "facing": int(shot.facing)}
		if not sprite.sprite_frames.has_animation(clip) or int(shot.frame) >= sprite.sprite_frames.get_frame_count(clip):
			row["error"] = "the staged SpriteFrames has no such clip or frame"
			results.append(row)
			continue
		_actor.facing = float(shot.facing)
		presenter._apply_facing()                 # the presenter's own rule, including art that faces left
		sprite.animation = clip
		sprite.frame = int(shot.frame)
		sprite.pause()
		_overlay.shapes = []
		_overlay.queue_redraw()
		await _rendered()
		row["image"] = "%s.png" % shot.name
		row["saved"] = _viewport.get_texture().get_image().save_png("%s/%s" % [_request.output_dir, row.image]) == OK
		row.merge(_describe(sprite, presenter, clip, int(shot.frame)))
		if shot.has("shapes") and not shot.shapes.is_empty():
			_overlay.shapes = shot.shapes
			_overlay.facing = float(shot.facing)
			_overlay.queue_redraw()
			await _rendered()
			row["overlay_image"] = "%s_overlay.png" % shot.name
			row["overlay_saved"] = _viewport.get_texture().get_image().save_png(
				"%s/%s" % [_request.output_dir, row.overlay_image]) == OK
		results.append(row)

	# ---- real playback: which frame AnimatedSprite2D shows after how long
	_overlay.shapes = []
	_overlay.queue_redraw()
	var timings: Array[Dictionary] = []
	for timing: Dictionary in _request.get("timings", []):
		var clip := StringName(String(timing.clip))
		if not sprite.sprite_frames.has_animation(clip):
			timings.append({"clip": String(timing.clip), "error": "no such clip"})
			continue
		sprite.play(clip)
		sprite.set_frame_and_progress(0, 0.0)
		var elapsed := 0.0
		var samples: Array = []
		var largest := 0.0
		while elapsed < float(timing.seconds):
			await get_tree().process_frame
			var delta := get_process_delta_time()
			elapsed += delta
			largest = maxf(largest, delta)
			samples.append([elapsed, sprite.frame, sprite.is_playing()])
		timings.append({"clip": String(timing.clip), "samples": samples, "largest_delta": largest,
				"loop": sprite.sprite_frames.get_animation_loop(clip)})
		sprite.pause()

	_finish({
		"monster_id": monster_id,
		"staging_session": Stager.staging_session(),
		"carrier": String(definition.id),
		"size": [size.x, size.y],
		"zoom": zoom,
		"profile_path": profile_path,
		"texture_filter": int(sprite.texture_filter),
		"profile_texture_filter": int(profile.texture_filter),
		"role_selection": selection,
		"shots": results,
		"timings": timings,
	})

## Two drawn frames: the first applies the change, the second is guaranteed to show it.
func _rendered() -> void:
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw

## Where the frame is on the screenshot, straight from the scene tree.
func _describe(sprite: AnimatedSprite2D, presenter: Node2D, clip: StringName, frame: int) -> Dictionary:
	var texture := sprite.sprite_frames.get_frame_texture(clip, frame)
	var extent := texture.get_size()
	var to_screen := _viewport.canvas_transform * sprite.get_global_transform()
	var corners: Array = []
	for corner: Vector2 in [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]:
		var point := to_screen * (corner * extent)          # AnimatedSprite2D is centred on its origin
		corners.append([point.x, point.y])
	var atlas := texture as AtlasTexture
	return {
		"frame_size": [extent.x, extent.y],
		"corners": corners,                               # top-left, top-right, bottom-right, bottom-left of the frame
		"region": [atlas.region.position.x, atlas.region.position.y, atlas.region.size.x, atlas.region.size.y] if atlas != null \
			else [0.0, 0.0, extent.x, extent.y],
		"texture_path": atlas.atlas.resource_path if atlas != null and atlas.atlas != null else texture.resource_path,
		"sprite_position": [sprite.position.x, sprite.position.y],
		"presenter_scale": [presenter.scale.x, presenter.scale.y],
		"flip_h": sprite.flip_h,
		"centered": sprite.centered,
	}

## Asks the real EnemyAnimationPresenter which clip it shows for each situation it can tell apart.
## jump_start and land depend on timers inside the presenter and are not forced here.
func _role_selection(presenter: EnemyAnimationPresenter) -> Dictionary:
	var chosen := {}
	var cases := [
		["idle", &"idle", Vector2.ZERO], ["move", &"idle", Vector2(200.0, 0.0)], ["attack", &"attack", Vector2.ZERO],
		["hurt", &"hurt", Vector2.ZERO], ["jump", &"idle", Vector2(0.0, -300.0)], ["fall", &"idle", Vector2(0.0, 300.0)],
		["death", &"dead", Vector2.ZERO],             # last: death is never replaced afterwards
	]
	for row: Array in cases:
		_actor.current_state_id = row[1]
		_actor.velocity = row[2]
		presenter._airborne = false
		presenter._land_remaining = 0.0
		presenter._process(0.0)
		chosen[row[0]] = String(presenter.sprite.animation)
	_actor.velocity = Vector2.ZERO
	return chosen

func _finish(data: Dictionary, error_code: String = "", message: String = "") -> void:
	var result := Inspector.environment()
	result["protocol"] = PROTOCOL
	result["request_id"] = _request.get("request_id", "")
	result["operation"] = "render_check"
	result["project_path"] = ProjectSettings.globalize_path("res://")
	result["status"] = "PASS" if error_code.is_empty() else "FAIL"
	result["error_code"] = error_code
	result["message"] = message
	result["data"] = data
	result["renderer"] = {
		"display_server": DisplayServer.get_name(),
		"rendering_method": RenderingServer.get_current_rendering_method(),
		"rendering_driver": RenderingServer.get_current_rendering_driver_name(),
		"video_adapter": RenderingServer.get_video_adapter_name(),
		"video_adapter_vendor": RenderingServer.get_video_adapter_vendor(),
	}
	var file := FileAccess.open(String(_request.result_path), FileAccess.WRITE)
	if file == null:
		push_error("render check cannot write %s" % _request.result_path)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("MONSTER RENDER CHECK %s" % result.status)
	# Leave the tree before quitting, so the actor is freed like any other node.
	if _viewport != null:
		_viewport.queue_free()
	await get_tree().process_frame
	get_tree().quit(0 if error_code.is_empty() else 3)
