extends Node

const GUI := preload("res://tests/integration/test_disconnect_recovery.gd")
var app: AppRoot
var role: String
var port: int
var command_path: String
var result_path: String
var _last_sequence: int = 0
var _busy: bool = false
var _failed: bool = false
var _deadline: int
var _player_id: StringName
var _profile_hash: String
var _save_hash: String = ""
var _save_session_id: String = ""
var _retired_generation: int = -1

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--command="):
			command_path = argument.trim_prefix("--command=")
		elif argument.begins_with("--result="):
			result_path = argument.trim_prefix("--result=")
	_deadline = Time.get_ticks_msec() + 60000
	app = (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	add_child(app)
	# Keep the production button handlers, supplying only an isolated test port.
	app.multiplayer_panel.host_requested.disconnect(app._host_game)
	app.multiplayer_panel.host_requested.connect(func() -> void: app._host_game(port))
	app.multiplayer_panel.host_saved_requested.disconnect(app._host_saved_game)
	app.multiplayer_panel.host_saved_requested.connect(func() -> void: app._host_saved_game("", port, 2))
	app.multiplayer_panel.join_requested.disconnect(app._join_game)
	app.multiplayer_panel.join_requested.connect(func(address: String) -> void: app._join_game(address, port))
	await get_tree().process_frame
	await get_tree().process_frame
	_player_id = GameSession.get_local_player_id()
	_profile_hash = FileAccess.get_file_as_string("user://local_player_profile.json").sha256_text()
	if not _menu_clean():
		_fail("initial menu is not ready")
		return
	_write("ready")

func _process(_delta: float) -> void:
	if _failed:
		return
	if Time.get_ticks_msec() > _deadline:
		_fail("timeout role=%s sequence=%d" % [role, _last_sequence])
		return
	if _busy or not FileAccess.file_exists(command_path):
		return
	var text := FileAccess.get_file_as_string(command_path)
	var parser := JSON.new()
	if text.is_empty() or parser.parse(text) != OK:
		return
	var raw: Variant = parser.data
	if not raw is Dictionary or int(raw.get("sequence", 0)) <= _last_sequence:
		return
	_last_sequence = int(raw["sequence"])
	_busy = true
	_deadline = Time.get_ticks_msec() + 60000
	_execute(raw)

func _execute(command: Dictionary) -> void:
	var action := String(command.get("action", ""))
	match action:
		"seed_save":
			if not await _click(app.new_game_button) or not await _wait(_settlement_ready):
				_fail("cannot create offline Save fixture through New Game")
				return
			GameSession.player.inventory.add_item(&"rusty_scrap", 3)
			if not SaveManager.save_game():
				_fail("cannot write isolated Save v5 fixture")
				return
			_save_hash = FileAccess.get_file_as_string(SaveManager.SAVE_PATH).sha256_text()
			_save_session_id = GameSession.session_id
			app._leave_game()
			if not await _wait(_menu_clean):
				_fail("Save fixture cleanup did not reach menu")
				return
		"host", "host_saved":
			var button := app.multiplayer_panel.host_button if action == "host" else app.multiplayer_panel.host_saved_button
			if not await _click(button) or not await _wait(func() -> bool:
				return NetworkManager.is_host_session_ready() and NetworkManager.is_local_world_ready() and _settlement_ready()
			):
				_fail("Host button did not start a ready Settlement: %s" % action)
				return
			if action == "host_saved" and (GameSession.session_id != _save_session_id or GameSession.player.inventory.count(&"rusty_scrap") != 3):
				_fail("Host Save did not restore the existing Save v5")
				return
		"join":
			app.multiplayer_panel.address_edit.text = String(command.get("address", "127.0.0.1"))
			if not await _click(app.multiplayer_panel.join_button) or not await _wait(func() -> bool:
				return NetworkManager.is_local_world_ready() and _settlement_ready()
			):
				_fail("Join button failed: %s" % NetworkManager.last_error)
				return
		"adventure":
			var actor := NetworkManager.authoritative_actor(NetworkManager.local_peer_id())
			if actor == null:
				_fail("authoritative host actor unavailable")
				return
			actor.position = Vector2(865, 510)
			var entered := NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region")
			if not entered.success or not await _wait(func() -> bool:
				return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == &"adventure:sewer_region"
			):
				_fail("Adventure setup failed before Disconnect")
				return
			GameSession.collect_adventure_loot_for_peer(&"rusty_scrap", 2, NetworkManager.local_peer_id())
		"disconnect":
			var possessions := GameSession.player.inventory.to_array()
			var storage := GameSession.settlement.to_save_dict()
			_retired_generation = NetworkManager._transport_generation
			if not await _click(app.multiplayer_panel.disconnect_button) or not await _wait(_menu_clean):
				_fail("GUI Disconnect did not restore a clean menu")
				return
			if GameSession.player.inventory.to_array() != possessions or GameSession.settlement.to_save_dict() != storage:
				_fail("Disconnect changed carried possessions or secured unsecured loot")
				return
		"check_menu":
			if not await _wait(_menu_clean):
				_fail("remote Host disconnect did not restore Client menu")
				return
		"new_game", "load_game":
			var button := app.new_game_button if action == "new_game" else app.load_game_button
			if not await _click(button) or not await _wait(_settlement_ready):
				_fail("real menu mouse click failed: %s" % action)
				return
			if not NetworkManager.is_authoritative_simulation() or NetworkManager.is_multiplayer_active():
				_fail("offline simulation authority did not recover")
				return
			if action == "load_game" and (GameSession.session_id != _save_session_id or GameSession.player.inventory.count(&"rusty_scrap") != 3):
				_fail("Load Game did not restore Save v5 data")
				return
		"to_menu":
			app._leave_game() # Fixture cleanup after an offline New/Load action.
			if not await _wait(_menu_clean):
				_fail("offline fixture cleanup failed")
				return
		"stale_callbacks":
			var session_id := GameSession.session_id
			var events: Array[int] = []
			var listener := func(peer: int) -> void: events.append(peer)
			NetworkManager.peer_world_ready.connect(listener)
			NetworkManager._on_server_disconnected()
			NetworkManager._on_connection_failed()
			NetworkManager._emit_peer_world_ready(NetworkManager.local_peer_id(), &"settlement", 1, _retired_generation)
			NetworkManager.peer_world_ready.disconnect(listener)
			if GameSession.session_id != session_id or app.menu.visible or not events.is_empty():
				_fail("retired transport event changed the new game/host")
				return
		"quit":
			app._leave_game()
			if not await _wait(_menu_clean):
				_fail("final scene cleanup did not complete")
				return
			var coordinator := get_tree().root.get_node_or_null(NodePath(String(EnvironmentLoadCoordinator.NODE_NAME))) as EnvironmentLoadCoordinator
			if coordinator != null and not await _wait(func() -> bool: return coordinator.pending_path_count() == 0):
				_fail("background resource loads did not finish before process teardown")
				return
			_write("pass")
			print("DISCONNECT RECOVERY PROBE PASS %s" % role)
			get_tree().quit(0)
			return
		_:
			_fail("unknown command: %s" % action)
			return
	if GameSession.get_local_player_id() != _player_id \
			or FileAccess.get_file_as_string("user://local_player_profile.json").sha256_text() != _profile_hash:
		_fail("Disconnect/restart changed persistent local profile identity")
		return
	if not _save_hash.is_empty() and FileAccess.get_file_as_string(SaveManager.SAVE_PATH).sha256_text() != _save_hash:
		_fail("menu recovery changed the existing Save file")
		return
	_write("pass")
	_busy = false

func _click(button: Button) -> bool:
	var received := [false]
	var listener := func() -> void: received[0] = true
	button.pressed.connect(listener, CONNECT_ONE_SHOT)
	await GUI.new()._mouse_click(self, button)
	if button.pressed.is_connected(listener):
		button.pressed.disconnect(listener)
	return received[0]

func _settlement_ready() -> bool:
	return GameSession.phase == GameSession.Phase.SETTLEMENT and not app.menu.visible \
		and SceneRouter.current_world_id() == &"settlement" and app.world_layer.get_child_count() == 1 \
		and app.get_node("UILayer/GameHUD").visible

func _menu_clean() -> bool:
	var hud := app.get_node("UILayer/GameHUD")
	return NetworkManager.state == NetworkManager.ConnectionState.OFFLINE \
		and NetworkManager.players.is_empty() and NetworkManager.world_ready_peers.is_empty() \
		and NetworkManager.peer_to_player.is_empty() and NetworkManager.player_to_peer.is_empty() \
		and NetworkManager._pending_world_transitions.is_empty() and NetworkManager._spawn_assignments.is_empty() \
		and NetworkManager._replication_ready_after_msec.is_empty() and NetworkManager._returning_peers.is_empty() \
		and not NetworkManager._received_session_snapshot and not NetworkManager._received_private_player_state \
		and not NetworkManager._received_world_assignment and not NetworkManager._received_spawn_assignment \
		and GameSession.phase == GameSession.Phase.MENU and GameSession.session_id.is_empty() \
		and GameSession.players.size() == 1 and GameSession.get_local_player_id() == _player_id \
		and GameSession.adventure.active_session == null and GameSession._adventure_sessions_by_world.is_empty() \
		and SceneRouter.current_world_id().is_empty() and SceneRouter._assignment_session_id.is_empty() \
		and SceneRouter._assignment_revision == 0 and not app._menu_transition_pending \
		and app.get_node("ServerWorldRoot").runtime_count() == 0 \
		and app.menu.visible and app.world_layer.get_child_count() == 0 and not hud.visible \
		and hud.bound_player == null and not get_tree().paused \
		and not app.new_game_button.disabled and not app.load_game_button.disabled \
		and not app.multiplayer_panel.host_button.disabled and not app.multiplayer_panel.host_saved_button.disabled \
		and not app.multiplayer_panel.join_button.disabled and app.multiplayer_panel.disconnect_button.disabled

func _wait(predicate: Callable) -> bool:
	var deadline := Time.get_ticks_msec() + 15000
	while not _failed and Time.get_ticks_msec() < deadline:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false

func _write(status: String, error: String = "") -> void:
	var result := {"sequence": _last_sequence, "status": status, "role": role, "error": error,
		"player_id": String(GameSession.get_local_player_id()), "session_id": GameSession.session_id,
		"profile_id": String(_player_id), "generation": NetworkManager._transport_generation,
		"save_session_id": _save_session_id, "phase": int(GameSession.phase), "menu": app.menu.visible,
		"protocol": NetworkProtocol.VERSION, "save": SaveManager.CURRENT_VERSION,
		"profile": LocalPlayerProfile.PROFILE_VERSION, "display_server": DisplayServer.get_name()}
	var file := FileAccess.open(result_path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(result, "\t"))
	file.close()
	DirAccess.rename_absolute(result_path + ".tmp", result_path)

func _fail(message: String) -> void:
	_failed = true
	_write("fail", message)
	push_error("DISCONNECT RECOVERY PROBE FAIL %s: %s" % [role, message])
	get_tree().quit(1)
