extends "res://tests/editor/field_runtime_probe.gd"
## Rendered walk through the Forest Trail. It drives the real input actions,
## records which clips each enemy presenter actually played and saves
## screenshots for a human to look at. It proves the presentation path runs in
## a window; it does not judge how the art looks.
##
##   godot --path . res://tests/editor/forest_visual_probe.tscn -- --screenshots <directory>

const BEETLE_CLIPS: Array[StringName] = [&"idle", &"move", &"attack", &"hurt", &"death"]
const FROG_CLIPS: Array[StringName] = [&"idle", &"jump_start", &"jump", &"fall", &"land", &"attack", &"hurt", &"death"]

var _layer: Node2D
var _directory := ""
var _clips: Dictionary[StringName, Dictionary] = {}
var _watched: Array[EnemyAgent] = []
var _shots := 0

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var at := args.find("--screenshots")
	if at < 0 or at + 1 >= args.size() or DisplayServer.get_name() == "headless":
		print("FOREST VISUAL PROBE FAIL: needs a window and --screenshots <directory>")
		get_tree().quit(1)
		return
	_directory = args[at + 1]
	DirAccess.make_dir_recursive_absolute(_directory)
	var region := ContentRegistry.get_definition(&"forest_region") as RegionDefinition
	var context := _create_context(region)
	_layer = Node2D.new()
	add_child(_layer)
	SceneRouter.register_world_layer(_layer)
	if context == null or not SceneRouter.go_to_adventure(context):
		print("FOREST VISUAL PROBE FAIL: could not enter the forest")
		get_tree().quit(1)
		return
	await _frames(30)
	var scene := _layer.get_child(0)
	var player := (scene.get_node("PlayerSpawnManager") as PlayerSpawnManager).get_actor(GameSession.get_local_peer_id())
	var enemies: Array[EnemyAgent] = []
	for node in get_tree().get_nodes_in_group(&"enemy"):
		enemies.append(node as EnemyAgent)
	var ok := player != null and enemies.size() == 4
	for enemy in enemies:
		ok = ok and enemy.animation_presenter != null and enemy.animation_presenter.sprite.visible \
			and not (enemy.get_node("Visual") as CanvasItem).visible
		_watched.append(enemy)
	if not ok:
		print("FOREST VISUAL PROBE FAIL: player or enemy presentation missing")
		get_tree().quit(1)
		return
	await _shot("01_trailhead")
	# Walk right with the real input action so the parallax layers scroll.
	Input.action_press("move_right")
	await _frames(90)
	Input.action_release("move_right")
	await _shot("02_walk")
	# Undisturbed enemies: patrol, hop, land.
	player.health.god_mode = true
	for index in enemies.size():
		player.global_position = enemies[index].global_position + Vector2(-420.0, -40.0)
		await _frames(150)
		await _shot("03_patrol_%s_%d" % [enemies[index].definition.id, index])
	# Fights: stand next to each enemy, let it attack, then strike it down.
	for index in enemies.size():
		var enemy := enemies[index]
		var id := "%s_%d" % [enemy.definition.id, index]
		player.global_position = enemy.global_position + Vector2(-90.0, -30.0)
		player.velocity = Vector2.ZERO
		var shot_attack := false
		for frame in 240:
			await get_tree().physics_frame
			_record()
			if not shot_attack and is_instance_valid(enemy) and enemy.current_state_id == &"attack":
				shot_attack = true
				await _shot("04_attack_%s" % id)
		for swing in 30:
			if not is_instance_valid(enemy):
				break
			# Only the positioning is synthetic: an enemy that was knocked back or
			# hopped away is approached again. Facing and the swing use real input.
			if absf(enemy.global_position.x - player.global_position.x) > 48.0 or absf(enemy.global_position.y - player.global_position.y) > 40.0:
				player.global_position = enemy.global_position + Vector2(-34.0, -12.0)
				player.velocity = Vector2.ZERO
				await _frames(4)
			var side := "move_right" if enemy.global_position.x >= player.global_position.x else "move_left"
			Input.action_press(side)
			await _frames(2)
			Input.action_release(side)
			var press := InputEventAction.new()
			press.action = &"primary_attack"
			press.pressed = true
			Input.parse_input_event(press)
			await _frames(3)
			var release := InputEventAction.new()
			release.action = &"primary_attack"
			Input.parse_input_event(release)
			await _frames(30)
			if swing == 0:
				await _shot("05_fight_%s" % id)
		await _frames(40)
		await _shot("06_after_%s" % id)
	var missing: Array[String] = []
	for clip in BEETLE_CLIPS:
		if not _clips.get(&"sewer_beetle", {}).has(clip):
			missing.append("sewer_beetle/" + clip)
	for clip in FROG_CLIPS:
		if not _clips.get(&"frog", {}).has(clip):
			missing.append("frog/" + clip)
	var alive := 0
	for node in get_tree().get_nodes_in_group(&"enemy"):
		var left := node as EnemyAgent
		alive += 1
		print("FOREST VISUAL ENEMY LEFT ", left.definition.id, " at ", left.global_position, " health ", left.health.current_health, " state ", left.current_state_id)
	print("FOREST VISUAL CLIPS ", _clips)
	print("FOREST VISUAL SCREENSHOTS ", _shots, " in ", _directory)
	SceneRouter.clear_presented_world()
	SceneRouter.register_world_layer(null)
	GameSession.start_new_game()
	await _frames(2)
	if missing.is_empty() and alive == 0:
		print("FOREST VISUAL PROBE PASS")
		get_tree().quit()
	else:
		print("FOREST VISUAL PROBE FAIL: missing clips ", missing, ", enemies left ", alive)
		get_tree().quit(1)

func _frames(count: int) -> void:
	for frame in count:
		await get_tree().physics_frame
		_record()

func _record() -> void:
	for enemy in _watched:
		if is_instance_valid(enemy) and enemy.animation_presenter != null:
			var seen: Dictionary = _clips.get_or_add(enemy.definition.id, {})
			seen[enemy.animation_presenter.current_animation] = true

func _shot(label: String) -> void:
	await RenderingServer.frame_post_draw
	if get_viewport().get_texture().get_image().save_png(_directory.path_join(label + ".png")) == OK:
		_shots += 1
