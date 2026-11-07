extends RefCounted

var app: AppRoot

func run(t: Node) -> void:
	await _test_menu_mouse_input(t)
	await _test_adventure_cleanup(t)
	await _test_pending_menu_input(t)
	await _test_stale_transport_events(t)
	await _test_retired_hud_bindings(t)

func _spawn(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.activate_offline_local_identity()
	app = (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	t.add_child(app)
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _host(t: Node) -> void:
	var port := 26000 + randi_range(0, 5000)
	t.assert_equal(NetworkManager.host_game(port, 2), OK, "disconnect fixture opens an actual host transport")
	t.assert_true(GameSession.start_new_game(), "disconnect fixture starts host domain")
	app.menu.visible = false
	t.assert_true(app._present_local_world_assignment(), "disconnect fixture presents host Settlement")
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _free(t: Node) -> void:
	NetworkManager.leave_game()
	app.get_parent().remove_child(app)
	app.queue_free()
	SceneRouter.register_world_layer(null)
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _mouse_click(t: Node, button: Button) -> void:
	var position := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	button.get_viewport().push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.position = position
	down.global_position = position
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.pressed = true
	button.get_viewport().push_input(down, true)
	await t.get_tree().process_frame
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	up.button_mask = 0
	button.get_viewport().push_input(up, true)
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_menu_mouse_input(t: Node) -> void:
	await _spawn(t)
	var pressed: Array[bool] = []
	app.new_game_button.pressed.connect(func() -> void: pressed.append(true))
	await _mouse_click(t, app.new_game_button)
	t.assert_equal(pressed.size(), 1, "baseline menu New Game receives real GUI mouse events")
	await _host(t)
	var hud := app.get_node("UILayer/GameHUD")
	t.assert_true(hud.visible, "active host game shows HUD")
	await _mouse_click(t, app.multiplayer_panel.disconnect_button)
	t.assert_true(app.menu.visible and GameSession.phase == GameSession.Phase.MENU, "mouse Disconnect returns to menu")
	t.assert_true(not hud.visible, "Disconnect hides HUD before menu can receive input")
	t.assert_true(hud.bound_player == null, "menu HUD releases the previous PlayerActor reference")
	t.assert_true(app.identity_gate_state == AppRoot.IdentityGateState.READY \
		and not app.new_game_button.disabled and not app.load_game_button.disabled, "identity gate and menu buttons are ready after cleanup")
	var count := pressed.size()
	await _mouse_click(t, app.new_game_button)
	t.assert_equal(pressed.size(), count + 1, "post-Disconnect New Game receives real mouse clicks through GUI hit testing")
	t.assert_true(not app.menu.visible and GameSession.phase == GameSession.Phase.SETTLEMENT \
		and SceneRouter.current_world_id() == &"settlement", "mouse New Game starts offline simulation without restarting process")
	t.assert_true(hud.visible and NetworkManager.is_authoritative_simulation(), "new offline game restores HUD and simulation authority")
	await _free(t)

func _test_adventure_cleanup(t: Node) -> void:
	await _spawn(t)
	await _host(t)
	GameSession.begin_player_adventure(1, &"sewer_gate", &"sewer_region")
	GameSession.collect_adventure_loot_for_peer(&"rusty_scrap", 2, 1)
	app._present_local_world_assignment()
	await t.get_tree().process_frame
	var local_id := GameSession.get_local_player_id()
	var inventory := GameSession.player.inventory.to_array()
	var saved_session_id := GameSession.session_id
	app._leave_game()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	t.assert_true(GameSession.adventure.active_session == null and GameSession._adventure_sessions_by_world.is_empty(), "Disconnect retires the host-local Adventure facade and all world sessions")
	t.assert_true(SaveManager.can_load().success, "an old Adventure cannot block Load Game from menu")
	t.assert_true(SceneRouter.current_world_id().is_empty() and SceneRouter._assignment_session_id.is_empty() \
		and SceneRouter._assignment_revision == 0, "Disconnect clears old presentation world and assignment revision")
	t.assert_true(app.world_layer.get_child_count() == 0, "menu contains no old scene presentation actors")
	t.assert_true(NetworkManager.players.is_empty() and NetworkManager.peer_to_player.is_empty() \
		and NetworkManager.player_to_peer.is_empty() and NetworkManager.world_ready_peers.is_empty() \
		and NetworkManager._pending_world_transitions.is_empty() and NetworkManager._spawn_assignments.is_empty(), "Disconnect clears transport attachment and world caches")
	t.assert_true(GameSession.players.size() == 1 and GameSession.session_id.is_empty() \
		and GameSession.get_local_player_id() == local_id, "offline Menu retains exactly the persistent local player")
	t.assert_equal(GameSession.player.inventory.to_array(), inventory, "Disconnect preserves carried local possessions")
	# A Save v5 host restore may reuse its saved session ID with a lower revision.
	NetworkManager.host_game(26000 + randi_range(0, 5000), 2)
	GameSession.start_new_game()
	GameSession.session_id = saved_session_id
	app.menu.visible = false
	t.assert_true(app._present_local_world_assignment(), "rehosting a saved session can present a fresh assignment revision")
	await _free(t)

func _test_pending_menu_input(t: Node) -> void:
	await _spawn(t)
	await _host(t)
	app._leave_game()
	# A synchronous signal consumer can try to start before deferred cleanup ends.
	app.new_game_button.pressed.emit()
	t.assert_true(GameSession.phase == GameSession.Phase.MENU and GameSession.session_id.is_empty(), "menu actions cannot run while old scene cleanup is pending")
	app._return_to_menu()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	t.assert_true(not app._menu_transition_pending and not app.new_game_button.disabled \
		and not app.multiplayer_panel.host_button.disabled, "duplicate end signals finish one cleanup and restore menu actions")
	await _free(t)

func _test_stale_transport_events(t: Node) -> void:
	await _spawn(t)
	await _host(t)
	app._leave_game()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	app._start_new_game()
	var session_id := GameSession.session_id
	t.assert_true(not session_id.is_empty() and GameSession.phase == GameSession.Phase.SETTLEMENT, "stale-callback fixture has a genuinely new offline game")
	NetworkManager._on_server_disconnected()
	NetworkManager._on_connection_failed()
	t.assert_true(GameSession.session_id == session_id and GameSession.phase == GameSession.Phase.SETTLEMENT \
		and not app.menu.visible, "retired transport callbacks cannot close a new offline game")
	await _free(t)

func _test_retired_hud_bindings(t: Node) -> void:
	await _spawn(t)
	await _host(t)
	var hud := app.get_node("UILayer/GameHUD")
	var actor := hud.bound_player as PlayerActor
	t.assert_true(actor != null, "HUD binding fixture resolves the local presentation actor")
	if actor != null:
		hud._bind_player(null)
		actor.interaction_prompt_changed.emit("retired actor event")
		actor.return_channel_changed.emit(true, 0.5)
		t.assert_true(hud.prompt_label.text != "retired actor event" and not hud.return_bar.visible, "unbound actor signals cannot update the next session's HUD")
	await _free(t)
