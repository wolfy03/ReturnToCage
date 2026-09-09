extends RefCounted

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	# Unit tests model hosting without opening a socket; the separate localhost
	# probe covers the actual ENet transport with a process timeout.
	NetworkManager.state = NetworkManager.ConnectionState.HOSTING
	NetworkManager._set_identity(1, &"player_1")
	NetworkManager.players[1] = NetworkPlayerInfo.new(1, &"player_1", "Host", true)
	t.assert_true(NetworkManager.is_server(), "lifecycle test models authoritative hosting")
	t.assert_true(GameSession.start_new_game(), "host creates the authoritative session")
	var host_id := GameSession.get_local_peer_id()
	var host_state := GameSession.get_player(host_id)
	NetworkManager._set_identity(42, &"player_2")
	NetworkManager._set_identity(43, &"player_3")
	var peer_b := GameSession.register_player(42)
	var peer_c := GameSession.register_player(43)
	var life_b := GameSession.arm_player_life(42)
	var life_c := GameSession.arm_player_life(43)
	var context := GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(context != null and GameSession.phase == GameSession.Phase.ADVENTURE, "multiplayer lifecycle test enters adventure")
	var active_adventure := GameSession.adventure.active_session
	active_adventure.unsecured_loot.add_item(&"berry", 2)
	var shared_loot_before := active_adventure.unsecured_loot.count(&"berry")
	var effect := ContentRegistry.get_definition(&"quick_paws") as EffectDefinition
	host_state.effects.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	peer_b.effects.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	var host_before := host_state.to_save_dict()
	var host_effect_before: float = host_state.effects.active_effects[&"quick_paws"].remaining
	var peer_b_effect_before: float = peer_b.effects.active_effects[&"quick_paws"].remaining
	var death_b := GameSession.handle_player_death(42, Vector2(320, 420), life_b)
	t.assert_true(death_b.success, "server resolves a remote player death")
	t.assert_equal(GameSession.get_player_death_result(42), death_b, "remote death result is peer-specific")
	t.assert_equal(GameSession.get_player_life_phase(42), PlayerRuntimeState.LifePhase.RESPAWNING, "only dead peer enters respawning life phase")
	t.assert_equal(GameSession.phase, GameSession.Phase.ADVENTURE, "remote death does not change session phase")
	t.assert_equal(GameSession.adventure.active_session, active_adventure, "remote death keeps the party adventure active")
	t.assert_equal(active_adventure.unsecured_loot.count(&"berry"), shared_loot_before, "individual death does not consume shared unsecured loot")
	t.assert_equal(host_state.to_save_dict(), host_before, "remote death does not mutate host player state")
	t.assert_true(peer_b.effects.paused and not host_state.effects.paused and not peer_c.effects.paused, "only dead peer pauses effects")
	GameSession._process(1.0)
	t.assert_true(host_state.effects.active_effects[&"quick_paws"].remaining < host_effect_before, "alive peer effects continue ticking")
	t.assert_equal(peer_b.effects.active_effects[&"quick_paws"].remaining, peer_b_effect_before, "respawning peer effects remain paused")

	var death_c := GameSession.handle_player_death(43, Vector2(360, 420), life_c)
	t.assert_true(death_c.success and death_c != death_b, "simultaneous deaths keep independent results")
	t.assert_equal(GameSession.get_player_life_id(42), life_b, "peer B life id remains independent")
	t.assert_equal(GameSession.get_player_life_id(43), life_c, "peer C life id remains independent")
	var next_life_b := GameSession.arm_player_life(42)
	t.assert_true(next_life_b > life_b and GameSession.get_player_death_result(42) == null, "respawn advances only that peer life")
	t.assert_true(not GameSession.handle_player_death(42, Vector2.ZERO, life_b).success, "stale actor death callback is rejected")
	t.assert_equal(GameSession.get_player_death_result(43), death_c, "stale peer B callback cannot alter peer C lifecycle")
	t.assert_true(not SaveManager.can_save().success, "host cannot save an active multiplayer session")
	t.assert_true(not SaveManager.can_load().success, "host cannot load an active multiplayer session")
	var retained_personal_b := GameSession.progression.get_personal_progression(&"player_2")
	GameSession.unregister_player(42)
	t.assert_equal(GameSession.progression.get_personal_progression(&"player_2"), retained_personal_b, "peer disconnect does not delete stable personal progression")
	t.assert_true(GameSession.progression.get_personal_progression(&"player_3") != null, "disconnect leaves other personal progression unchanged")

	NetworkManager.leave_game()
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "leave returns transport to offline")
	t.assert_equal(NetworkManager.players.size(), 0, "leave clears network peer registry")
	t.assert_equal(GameSession.players.size(), 1, "leave retains only the offline local player")
	t.assert_true(GameSession.player == GameSession.players[GameSession.LOCAL_SINGLEPLAYER_PEER_ID], "offline compatibility facade remains canonical")
	t.assert_true(GameSession.get_player_runtime(42) == null and GameSession.get_player_runtime(43) == null, "leave clears remote lifecycle state")
	t.assert_true(GameSession.start_new_game() and SaveManager.can_save().success, "offline restart and save policy remain available")

	_test_runtime_snapshot_validation(t)
	await _test_remote_health_presentation(t)
	await _test_main_menu_session_lifecycle(t)
	_test_spawn_slot_exhaustion(t)
	NetworkManager.leave_game()
	GameSession.start_new_game()

func _test_runtime_snapshot_validation(t: Node) -> void:
	var valid := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": 40.0, "max_health": 100.0,
		"life_id": 7, "life_phase": PlayerRuntimeState.LifePhase.ALIVE, "facing": -1.0,
	})
	t.assert_true(valid.error_message.is_empty() and valid.health == 40.0, "runtime snapshot accepts validated presentation state")
	var nan_health := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": NAN, "max_health": 100.0,
		"life_id": 7, "life_phase": PlayerRuntimeState.LifePhase.ALIVE, "facing": 1.0,
	})
	t.assert_true(not nan_health.error_message.is_empty(), "runtime snapshot rejects NaN health")
	var invalid_phase := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": 40.0, "max_health": 100.0,
		"life_id": 7, "life_phase": 99, "facing": 1.0,
	})
	t.assert_true(not invalid_phase.error_message.is_empty(), "runtime snapshot rejects invalid life phase")

func _test_remote_health_presentation(t: Node) -> void:
	var remote_state := GameSession.register_player(42)
	remote_state.stats.set_base(&"max_health", 50.0)
	var inventory_before := remote_state.inventory.to_array()
	var equipment_before := remote_state.equipment.to_dict()
	var effects_before := remote_state.effects.to_array()
	var stats_before := remote_state.stats.to_dict()
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	t.assert_true(not SaveManager.can_save().success and not SaveManager.can_load().success, "client cannot save or load an active multiplayer session")
	var layer := Node2D.new()
	t.add_child(layer)
	var actor := PLAYER_SCENE.instantiate() as PlayerActor
	actor.setup_player(42)
	layer.add_child(actor)
	await t.get_tree().process_frame
	var snapshot := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": 40.0, "max_health": 100.0,
		"life_id": 1, "life_phase": PlayerRuntimeState.LifePhase.ALIVE, "facing": -1.0,
	})
	var health_events: Array[Array] = []
	var health_callback := func(peer_id: int, current: float, maximum: float) -> void: health_events.append([peer_id, current, maximum])
	GameSession.player_health_changed.connect(health_callback)
	t.assert_true(GameSession.apply_player_runtime_snapshot(snapshot), "client accepts server runtime presentation snapshot")
	actor.apply_runtime_presentation(snapshot)
	t.assert_equal(remote_state.health, 40.0, "client PlayerState mirrors server runtime health")
	t.assert_equal(actor.health.current_health, 40.0, "remote actor displays server health")
	t.assert_equal(health_events.size(), 1, "client runtime health emits one domain relay without feedback")
	var dead_snapshot := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": 45.0, "max_health": 100.0,
		"life_id": 1, "life_phase": PlayerRuntimeState.LifePhase.DEAD, "facing": -1.0,
	})
	t.assert_true(GameSession.apply_player_runtime_snapshot(dead_snapshot), "client mirrors dead-life server health")
	actor.apply_runtime_presentation(dead_snapshot)
	t.assert_equal(remote_state.health, 45.0, "PlayerState retains the authoritative dead-life health mirror")
	t.assert_equal(actor.health.current_health, 0.0, "dead actor presentation remains at zero health")
	var respawning_snapshot := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": 75.0, "max_health": 100.0,
		"life_id": 1, "life_phase": PlayerRuntimeState.LifePhase.RESPAWNING, "facing": 1.0,
	})
	t.assert_true(GameSession.apply_player_runtime_snapshot(respawning_snapshot), "client mirrors respawning server health")
	actor.apply_runtime_presentation(respawning_snapshot)
	t.assert_equal(remote_state.health, 75.0, "replicated health uses snapshot max without rewriting stats")
	t.assert_equal(actor.health.current_health, 0.0, "respawning old actor does not flash restored health")
	var alive_snapshot := PlayerRuntimeSnapshot.from_payload({
		"peer_id": 42, "health": 75.0, "max_health": 100.0,
		"life_id": 2, "life_phase": PlayerRuntimeState.LifePhase.ALIVE, "facing": 1.0,
	})
	t.assert_true(GameSession.apply_player_runtime_snapshot(alive_snapshot), "new life snapshot is accepted")
	actor.apply_runtime_presentation(alive_snapshot)
	t.assert_equal(actor.health.current_health, remote_state.health, "alive actor and PlayerState use the same snapshot health")
	t.assert_true(not GameSession.apply_player_runtime_snapshot(dead_snapshot), "previous-life health snapshot is rejected")
	t.assert_equal(health_events.size(), 4, "each accepted runtime snapshot emits exactly one health relay")
	t.assert_equal(remote_state.stats.to_dict(), stats_before, "runtime health mirror does not rewrite stats")
	t.assert_equal(remote_state.inventory.to_array(), inventory_before, "runtime health mirror does not change inventory")
	t.assert_equal(remote_state.equipment.to_dict(), equipment_before, "runtime health mirror does not change equipment")
	t.assert_equal(remote_state.effects.to_array(), effects_before, "runtime health mirror does not change effects")
	GameSession.player_health_changed.disconnect(health_callback)
	layer.queue_free()
	await t.get_tree().process_frame

func _test_main_menu_session_lifecycle(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var app := (load("res://core/boot.tscn") as PackedScene).instantiate()
	t.add_child(app)
	await t.get_tree().process_frame
	var app_menu := app.get_node("%MainMenu") as Control
	var app_world_layer := app.get_node("%WorldLayer") as Node
	var end_reasons: Array[String] = []
	var end_callback := func(reason: String) -> void: end_reasons.append(reason)
	NetworkManager.multiplayer_session_ended.connect(end_callback)

	NetworkManager.state = NetworkManager.ConnectionState.HOSTING
	NetworkManager._session_entered = true
	NetworkManager._set_identity(1, &"player_1")
	NetworkManager.players[1] = NetworkPlayerInfo.new(1, &"player_1", "Host", true)
	GameSession.start_new_game()
	GameSession.register_player(42)
	app_menu.visible = false
	var host_world := Node.new()
	app_world_layer.add_child(host_world)
	NetworkManager.leave_game()
	t.assert_equal(end_reasons.back(), NetworkManager.END_REASON_MANUAL, "host manual leave emits one session-end reason")
	t.assert_true(app_menu.visible and host_world.get_parent() == null, "host leave removes world and returns Main Menu")
	_assert_clean_menu_state(t, "host leave")
	await t.get_tree().process_frame

	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._session_entered = true
	NetworkManager._set_identity(42, &"player_2")
	NetworkManager.players[42] = NetworkPlayerInfo.new(42, &"player_2", "Client", true)
	GameSession.register_player(42)
	app_menu.visible = false
	var client_world := Node.new()
	app_world_layer.add_child(client_world)
	NetworkManager.leave_game()
	t.assert_true(app_menu.visible and client_world.get_parent() == null, "client manual leave removes world and returns Main Menu")
	_assert_clean_menu_state(t, "client leave")
	await t.get_tree().process_frame

	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._session_entered = true
	NetworkManager._set_identity(42, &"player_2")
	NetworkManager.players[42] = NetworkPlayerInfo.new(42, &"player_2", "Client", true)
	GameSession.register_player(42)
	app_menu.visible = false
	var disconnected_world := Node.new()
	app_world_layer.add_child(disconnected_world)
	NetworkManager._on_server_disconnected()
	t.assert_equal(end_reasons.back(), NetworkManager.END_REASON_SERVER_DISCONNECTED, "unexpected server disconnect emits session-end reason")
	t.assert_true(app_menu.visible and disconnected_world.get_parent() == null, "server disconnect removes world and returns Main Menu")
	_assert_clean_menu_state(t, "server disconnect")
	await t.get_tree().process_frame

	var ended_count := end_reasons.size()
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTING
	NetworkManager._session_entered = false
	NetworkManager._on_connection_failed()
	t.assert_equal(end_reasons.size(), ended_count, "pre-session connection failure avoids a redundant session-end transition")
	t.assert_true(app_menu.visible, "connection failure remains on Main Menu")
	NetworkManager.multiplayer_session_ended.disconnect(end_callback)
	app.queue_free()
	await t.get_tree().process_frame

func _assert_clean_menu_state(t: Node, context: String) -> void:
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "%s resets network state" % context)
	t.assert_true(NetworkManager.players.is_empty() and NetworkManager.world_ready_peers.is_empty(), "%s clears network registries" % context)
	t.assert_true(GameSession.players.size() == 1 and GameSession.phase == GameSession.Phase.MENU, "%s leaves one offline player in menu phase" % context)
	t.assert_equal(GameSession.session_id, "", "%s clears session id" % context)

func _test_spawn_slot_exhaustion(t: Node) -> void:
	var manager := PlayerSpawnManager.new()
	for peer_id in range(1, NetworkManager.MAX_PLAYERS + 1):
		t.assert_true(manager._assign_slot(peer_id), "spawn slot %d is assigned once" % peer_id)
	t.assert_true(not manager._assign_slot(NetworkManager.MAX_PLAYERS + 1), "spawn manager rejects slot exhaustion")
	manager.free()
