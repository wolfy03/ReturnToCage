extends Node
## Opt-in release verification through the normal Boot scene and network paths.
## Test profile and native user directory isolation is owned by the launcher.

var _app: Node
var _mode: String
var _result_path: String
var _port: int = NetworkManager.DEFAULT_PORT
var _release_path: String
var _report: Dictionary = {}
var _finished: bool = false

func configure(app: Node) -> void:
	_app = app
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--export-validation="):
			_mode = argument.trim_prefix("--export-validation=")
		elif argument.begins_with("--export-result="):
			_result_path = argument.trim_prefix("--export-result=")
		elif argument.begins_with("--export-port="):
			_port = int(argument.trim_prefix("--export-port="))
		elif argument.begins_with("--export-release="):
			_release_path = argument.trim_prefix("--export-release=")

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var ids: Array[String] = []
	var difficulties: Array[String] = []
	for definition in ContentRegistry.all_definitions():
		ids.append(String(definition.id))
		if definition is DifficultyDefinition:
			difficulties.append(String(definition.id))
	ids.sort()
	difficulties.sort()
	_report = {"mode": _mode, "editor": OS.has_feature("editor"), "debug": OS.is_debug_build(),
		"engine": Engine.get_version_info().get("string"), "content_ids": ids, "difficulty_ids": difficulties,
		"physical_start_files": DirAccess.get_files_at("res://data/content/game_start"),
		"logical_start_files": ResourceLoader.list_directory("res://data/content/game_start"),
		"protocol": NetworkProtocol.VERSION, "save": SaveManager.CURRENT_VERSION,
		"profile": LocalPlayerProfile.PROFILE_VERSION, "user_path": OS.get_user_data_dir()}
	_report["display_server"] = DisplayServer.get_name()
	_report["rendering_method"] = RenderingServer.get_current_rendering_method()
	var errors := ContentRegistry.validate_all()
	if not ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) is GameStartDefinition:
		errors.append("Missing GameStartDefinition: %s" % GameSession.DEFAULT_START_ID)
	if not ContentRegistry.get_definition(&"normal") is DifficultyDefinition:
		errors.append("Missing DifficultyDefinition: normal")
	if not errors.is_empty():
		_fail("Content initialization failed: %s" % "; ".join(errors))
		return
	if not NetworkManager.has_valid_local_profile() or not NetworkManager.is_local_identity_activated() \
			or GameSession.get_local_player() == null:
		_fail("GameSession or local profile initialization failed")
		return
	_report["player_id"] = String(GameSession.get_local_player_id())
	_report["content_valid"] = true
	print("EXPORT CONTENT PASS ids=%d start=FOUND difficulties=%s" % [ids.size(), difficulties])
	if _mode == "lifecycle":
		var probe := preload("res://core/validation/session_recovery_probe.gd").new()
		probe.configure(_app as AppRoot, _report)
		get_tree().root.add_child(probe)
		return
	if _mode == "content":
		# Network modes deliberately leave the Settlement preset cold so their
		# normal threaded load also exercises binary resource remapping.
		for path in ["res://world/environment/presets/settlement_environment.tres",
				"res://world/environment/presets/sewer_environment.tres",
				"res://presentation/player/player_visual.tscn",
				"res://ui/inventory/inventory_window.tscn",
				"res://ui/inventory/equipment_window.tscn",
				"res://ui/inventory/item_slot_view.tscn",
				"res://ui/inventory/item_tooltip.tscn",
				"res://ui/inventory/item_placeholder.svg",
				LootActor.VISUAL_SCENE_PATH]:
			if ResourceLoader.load(path) == null:
				_fail("Missing dynamically loaded resource: %s" % path)
				return
		var loot_textures: Array[String] = []
		for path: String in LootActor.DISPLAY_TEXTURE_PATHS.values():
			var texture := ResourceLoader.load(path) as Texture2D
			if texture == null or texture.get_size() != Vector2(32, 32):
				_fail("Missing or invalid loot texture: %s" % path)
				return
			if DisplayServer.get_name() != "headless":
				var image := texture.get_image()
				if image == null or image.detect_alpha() == Image.ALPHA_NONE:
					_fail("Loot texture has no transparency: %s" % path)
					return
			loot_textures.append(path)
		_report["loot_textures"] = loot_textures
		if not _verify_authored_loot_icon():
			_fail("The packed item icon could not be displayed as field loot")
			return
		_report["authored_loot_icon"] = true
		if not await _verify_loot_animation():
			_fail("Packed loot throw, floating handoff or pickup cleanup failed")
			return
		_report["loot_animation"] = true
		await get_tree().process_frame
		await get_tree().process_frame
		_pass()
		return
	NetworkManager.connection_failed.connect(func() -> void: _fail(NetworkManager.last_error))
	if _mode == "host":
		if NetworkManager.host_game(_port, 2) != OK or not GameSession.start_new_game() \
				or not _app._present_local_world_assignment():
			_fail("Host startup failed: %s / %s" % [NetworkManager.last_error, GameSession.last_message])
			return
		_app.menu.visible = false
		_report["status"] = "listening"
		_write_report()
		if not await _wait(func() -> bool:
			return NetworkManager.players.size() == 2 and _all_ready()
		):
			_fail("Host never received a world-ready client")
			return
	elif _mode == "client":
		if NetworkManager.join_game("127.0.0.1", _port) != OK:
			_fail("Client transport could not start: %s" % NetworkManager.last_error)
			return
		if not await _wait(func() -> bool:
			return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == &"settlement"
		):
			_fail("Client sync failed: %s" % NetworkManager.last_error)
			return
		if not NetworkManager._received_session_snapshot or not NetworkManager._received_private_player_state \
				or not NetworkManager._received_world_assignment or not NetworkManager._received_spawn_assignment:
			_fail("Client initialization skipped a required authoritative snapshot")
			return
		_report["session_snapshot"] = true
		_report["private_snapshot"] = true
		_report["world_assignment"] = true
	else:
		_fail("Unknown export validation mode: %s" % _mode)
		return
	if SceneRouter.current_world_id() != &"settlement" or _app.world_layer.get_child_count() != 1:
		_fail("Settlement presentation did not load")
		return
	var environment := _app.world_layer.get_child(0).get("environment_presenter") as EnvironmentPresenter
	if environment == null or not await _wait(func() -> bool:
		return not environment.is_loading() and environment.definition != null and environment.layer_count() > 0
	):
		_fail("Settlement environment did not finish loading from the exported pack")
		return
	_report["environment_loaded"] = true
	_report["settlement_loaded"] = true
	_report["player_id"] = String(GameSession.get_local_player_id())
	_report["session_id"] = GameSession.session_id
	_report["status"] = "ready"
	_write_report()
	print("EXPORT ENET READY %s protocol=%d" % [_mode, NetworkProtocol.VERSION])
	if not await _wait(func() -> bool: return FileAccess.file_exists(_release_path)):
		_fail("Launcher never released the probe")
		return
	_pass()

func _verify_authored_loot_icon() -> bool:
	# Reuse a packaged, oversized texture as a test-only item icon.
	var icon := ResourceLoader.load("res://icon.svg") as Texture2D
	if icon == null:
		return false
	var original := ContentRegistry.get_item(&"berry")
	var fixture := original.duplicate() as ItemDefinition
	fixture.icon = icon
	ContentRegistry._definitions[fixture.id] = fixture
	var actor := preload("res://gameplay/actors/loot/loot_actor.tscn").instantiate() as LootActor
	actor.configure(1, ItemStack.new(fixture.id, 1), null)
	add_child(actor)
	ContentRegistry._definitions[original.id] = original
	var visual := actor.get_node_or_null("Visual") as Sprite2D
	var valid := visual != null and visual.texture == icon \
		and (icon.get_size() * visual.scale).is_equal_approx(Vector2(32, 32))
	actor.free()
	return valid

func _verify_loot_animation() -> bool:
	if not GameSession.start_new_game() or not SceneRouter.go_to_settlement():
		return false
	_app.menu.hide()
	var player := NetworkManager.authoritative_actor(1)
	var world: Node = _app.world_layer.get_child(0)
	var manager := world.get_node_or_null("LootSpawnManager") as LootSpawnManager
	if player == null or manager == null:
		return false
	var origin := player.item_throw_origin()
	var landing := player.item_drop_point.global_position
	var id := manager.spawn_loot(ItemStack.new(&"berry", 1), landing, Callable(), origin)
	var loot := manager.get_loot(id)
	var visual := loot.get_node_or_null("Visual") as Sprite2D if loot != null else null
	if visual == null or visual.texture == null or loot._throw_tween == null \
			or not visual.global_position.is_equal_approx(origin):
		return false
	if not await _wait(func() -> bool: return loot._throw_tween == null) \
			or not loot.global_position.is_equal_approx(landing) \
			or visual.get_instance_shader_parameter(&"float_weight") != 1.0:
		return false
	var bag := GameSession.get_local_player().inventory
	var before := bag.count(&"berry")
	if not manager.server_try_pickup(1, id).success or manager.get_loot(id) != null \
			or visual.get_parent() != world or bag.count(&"berry") != before + 1:
		return false
	var visual_path := visual.get_path()
	return await _wait(func() -> bool: return get_node_or_null(visual_path) == null)

func _all_ready() -> bool:
	for peer in NetworkManager.players:
		if not NetworkManager.is_peer_world_ready(peer):
			return false
	return true

func _wait(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 20000
	while not _finished and Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false

func _write_report() -> void:
	var file := FileAccess.open(_result_path, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write export validation report: %s" % _result_path)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(_report, "\t"))
	file.close()

func _pass() -> void:
	if _finished:
		return
	_finished = true
	_report["rendered_frames"] = Engine.get_frames_drawn()
	_report["status"] = "pass"
	_write_report()
	print("EXPORT VALIDATION PASS %s" % _mode)
	get_tree().quit(0)

func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	_report["status"] = "fail"
	_report["error"] = message
	_write_report()
	push_error("EXPORT VALIDATION FAIL: %s" % message)
	get_tree().quit(1)
