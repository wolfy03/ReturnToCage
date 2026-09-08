extends RefCounted

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	# Unit tests model hosting without opening a socket; the separate localhost
	# probe covers the actual ENet transport with a process timeout.
	NetworkManager.state = NetworkManager.ConnectionState.HOSTING
	NetworkManager.players[1] = NetworkPlayerInfo.new(1, "Host", true)
	t.assert_true(NetworkManager.is_server(), "lifecycle test models authoritative hosting")
	t.assert_true(GameSession.start_new_game(), "host creates the authoritative session")
	var host_id := GameSession.get_local_peer_id()
	var host_state := GameSession.get_player(host_id)
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

	NetworkManager.leave_game()
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "leave returns transport to offline")
	t.assert_equal(NetworkManager.players.size(), 0, "leave clears network peer registry")
	t.assert_equal(GameSession.players.size(), 1, "leave retains only the offline local player")
	t.assert_true(GameSession.player == GameSession.players[GameSession.LOCAL_SINGLEPLAYER_PEER_ID], "offline compatibility facade remains canonical")
	t.assert_true(GameSession.get_player_runtime(42) == null and GameSession.get_player_runtime(43) == null, "leave clears remote lifecycle state")
	t.assert_true(GameSession.start_new_game() and SaveManager.can_save().success, "offline restart and save policy remain available")

	_test_runtime_snapshot_validation(t)
	await _test_remote_health_presentation(t)
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
	var canonical_health := remote_state.health
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
	t.assert_true(GameSession.apply_player_runtime_snapshot(snapshot), "client accepts server runtime presentation snapshot")
	actor.apply_runtime_presentation(snapshot)
	t.assert_equal(actor.health.current_health, 40.0, "remote actor displays server health")
	t.assert_equal(remote_state.health, canonical_health, "remote health callback cannot mutate client PlayerState")
	layer.queue_free()
	await t.get_tree().process_frame

func _test_spawn_slot_exhaustion(t: Node) -> void:
	var manager := PlayerSpawnManager.new()
	for peer_id in range(1, NetworkManager.MAX_PLAYERS + 1):
		t.assert_true(manager._assign_slot(peer_id), "spawn slot %d is assigned once" % peer_id)
	t.assert_true(not manager._assign_slot(NetworkManager.MAX_PLAYERS + 1), "spawn manager rejects slot exhaustion")
	manager.free()
