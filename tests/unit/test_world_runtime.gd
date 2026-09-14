extends RefCounted

const PLAYER_B: StringName = &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLAYER_C: StringName = &"player_cccccccccccccccccccccccccccccccc"
const SEWER: StringName = &"adventure:sewer_region"

func run(t: Node) -> void:
	_test_model_and_entity_scope(t)
	await _test_authoritative_hurt_world_transition_guard(t)
	await _test_runtime_lifecycle_and_physics_isolation(t)
	_test_interest_and_revision_guards(t)

func _test_model_and_entity_scope(t: Node) -> void:
	var settlement := WorldRuntime.new(
		PlayerWorldState.SETTLEMENT_WORLD_ID, PlayerWorldState.WorldKind.SETTLEMENT
	)
	var sewer := WorldRuntime.new(SEWER, PlayerWorldState.WorldKind.ADVENTURE, &"sewer_region")
	t.assert_true(settlement.is_valid() and sewer.is_valid(), "world runtime models validate canonical world identities")
	t.assert_true(not WorldRuntime.new(&"adventure:wrong", PlayerWorldState.WorldKind.ADVENTURE, &"sewer_region").is_valid(), "world runtime rejects a mismatched Adventure world identity")

	var registry := NetworkEntityRegistry.new()
	var settlement_entity := Node.new()
	var sewer_entity := Node.new()
	t.assert_true(registry.register_remote_entity_in_world(&"settlement", 1, settlement_entity), "Settlement may register entity 1")
	t.assert_true(registry.register_remote_entity_in_world(SEWER, 1, sewer_entity), "Sewer may independently register entity 1")
	t.assert_true(registry.get_entity_in_world(&"settlement", 1) == settlement_entity, "world-scoped lookup returns the Settlement entity")
	t.assert_true(registry.get_entity_in_world(SEWER, 1) == sewer_entity, "world-scoped lookup returns the Sewer entity")
	var duplicate_entity := Node.new()
	t.assert_true(not registry.register_remote_entity_in_world(SEWER, 1, duplicate_entity), "duplicate entity IDs remain invalid inside one world")
	duplicate_entity.free()
	settlement_entity.free()
	sewer_entity.free()
	registry.free()

func _test_authoritative_hurt_world_transition_guard(t: Node) -> void:
	NetworkManager.leave_game()
	var port := 24000 + randi_range(0, 1000)
	t.assert_equal(NetworkManager.host_game(port, 2), OK, "HURT world-transition fixture opens a ready host")
	t.assert_true(GameSession.start_new_game(), "HURT world-transition fixture starts a fresh session")
	var root := ServerWorldRoot.new()
	t.add_child(root)
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	NetworkManager.mark_peer_world_ready(1)
	var settlement := root.runtime(PlayerWorldState.SETTLEMENT_WORLD_ID)
	var actor := settlement.player_manager().get_actor(1) if settlement != null else null
	t.assert_true(actor != null and actor.is_simulation_authority(), "fixture resolves the authoritative Settlement actor")
	if actor == null:
		root.queue_free()
		await t.get_tree().process_frame
		NetworkManager.leave_game()
		return

	var settlement_world := GameSession.get_peer_world(1)
	var settlement_spawn := NetworkManager.spawn_assignment_for_peer(1)
	t.assert_true(actor.hurt.begin_hurt(), "Settlement authority enters HURT before region request")
	var rejected_enter := NetworkManager._begin_player_world_transition(1, &"sewer_gate", &"sewer_region")
	var after_rejected_enter := GameSession.get_peer_world(1)
	t.assert_true(not rejected_enter.success and rejected_enter.message.contains("hurt"), "HURT rejects authoritative enter-region mutation")
	t.assert_true(after_rejected_enter.world_id == settlement_world.world_id \
			and after_rejected_enter.revision == settlement_world.revision, "rejected enter-region preserves world and revision")
	t.assert_true(not NetworkManager._pending_world_transitions.has(1), "rejected enter-region creates no pending transition")
	t.assert_true(NetworkManager.spawn_assignment_for_peer(1) == settlement_spawn, "rejected enter-region preserves spawn assignment")

	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	var accepted_enter := NetworkManager._begin_player_world_transition(1, &"sewer_gate", &"sewer_region")
	t.assert_true(accepted_enter.success, "enter-region is re-enabled immediately after HURT")
	var adventure_world := GameSession.get_peer_world(1)
	t.assert_true(adventure_world.world_id == SEWER \
			and adventure_world.revision == settlement_world.revision + 1, "post-HURT enter-region commits one world revision")
	NetworkManager.mark_peer_world_ready(1)
	await t.get_tree().process_frame
	var sewer := root.runtime(SEWER)
	actor = sewer.player_manager().get_actor(1) if sewer != null else null
	t.assert_true(actor != null and actor.is_simulation_authority(), "fixture resolves the authoritative Adventure actor")
	if actor == null:
		root.queue_free()
		await t.get_tree().process_frame
		NetworkManager.leave_game()
		return

	var session := GameSession.adventure_session_for_world(SEWER)
	var participation := session.get_player_adventure(1) if session != null else null
	var adventure_spawn := NetworkManager.spawn_assignment_for_peer(1)
	t.assert_true(actor.hurt.begin_hurt(), "Adventure authority enters HURT before escape request")
	var rejected_return := NetworkManager._return_player_to_settlement(1, AdventureSession.Result.NORMAL_ESCAPE)
	var after_rejected_return := GameSession.get_peer_world(1)
	t.assert_true(not rejected_return.success and rejected_return.message.contains("hurt"), "HURT rejects authoritative return-to-Settlement mutation")
	t.assert_true(after_rejected_return.world_id == adventure_world.world_id \
			and after_rejected_return.revision == adventure_world.revision, "rejected return preserves world and revision")
	t.assert_true(session != null and session.get_player_adventure(1) == participation \
			and session.result == AdventureSession.Result.ACTIVE, "rejected return preserves Adventure participation/result")
	t.assert_true(not NetworkManager._pending_world_transitions.has(1), "rejected return creates no pending transition")
	t.assert_true(NetworkManager.spawn_assignment_for_peer(1) == adventure_spawn, "rejected return preserves spawn assignment")

	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	var accepted_return := NetworkManager._return_player_to_settlement(1, AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(accepted_return.success, "return-to-Settlement is re-enabled immediately after HURT")
	var returned_world := GameSession.get_peer_world(1)
	t.assert_true(returned_world.world_id == PlayerWorldState.SETTLEMENT_WORLD_ID \
			and returned_world.revision == adventure_world.revision + 1, "post-HURT return commits one world revision")
	t.assert_true(session.get_player_adventure(1) == null, "successful post-HURT return finishes Adventure participation")
	NetworkManager.mark_peer_world_ready(1)
	root.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	NetworkManager.leave_game()

func _test_runtime_lifecycle_and_physics_isolation(t: Node) -> void:
	NetworkManager.leave_game()
	var port := 26000 + randi_range(0, 2000)
	t.assert_equal(NetworkManager.host_game(port, 3), OK, "runtime lifecycle fixture opens a ready host")
	t.assert_true(GameSession.start_new_game(), "runtime lifecycle fixture starts a fresh session")
	var root := ServerWorldRoot.new()
	t.add_child(root)
	await t.get_tree().process_frame
	var settlement := root.runtime(&"settlement")
	t.assert_true(settlement != null and root.runtime_count() == 1, "first Settlement participant creates one server runtime")

	GameSession.attach_player(42, PLAYER_B)
	GameSession.begin_player_adventure(42, &"sewer_gate", &"sewer_region")
	var sewer := root.runtime(SEWER)
	t.assert_true(sewer != null and root.runtime_count() == 2, "first Sewer participant creates a background runtime")
	t.assert_true(settlement._viewport.world_2d != sewer._viewport.world_2d, "server worlds own isolated World2D physics spaces")
	GameSession.attach_player(43, PLAYER_C)
	GameSession.begin_player_adventure(43, &"sewer_gate", &"sewer_region")
	t.assert_true(root.runtime(SEWER) == sewer, "second Sewer participant reuses the existing runtime")
	GameSession.finish_player_adventure(42, AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(root.runtime(SEWER) == sewer, "one remaining participant retains the Sewer runtime")
	GameSession.finish_player_adventure(43, AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(root.runtime(SEWER) == null and root.runtime_count() == 1, "last participant exit removes the Sewer runtime")
	GameSession.begin_player_adventure(42, &"sewer_gate", &"sewer_region")
	t.assert_true(root.runtime(SEWER) != null and root.runtime(SEWER) != sewer, "re-entry after cleanup creates exactly one fresh runtime")
	root.queue_free()
	await t.get_tree().process_frame
	NetworkManager.leave_game()

func _test_interest_and_revision_guards(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	GameSession.attach_player(42, PLAYER_B)
	GameSession.attach_player(43, PLAYER_C)
	GameSession.begin_player_adventure(42, &"sewer_gate", &"sewer_region")
	GameSession.begin_player_adventure(43, &"sewer_gate", &"sewer_region")
	NetworkManager.players[1] = NetworkPlayerInfo.new(1, GameSession.get_player_id(1), "A", true)
	NetworkManager.players[42] = NetworkPlayerInfo.new(42, PLAYER_B, "B", true)
	NetworkManager.players[43] = NetworkPlayerInfo.new(43, PLAYER_C, "C", true)
	NetworkManager.world_ready_peers[1] = PeerWorldReadyState.new(&"settlement", GameSession.get_peer_world(1).revision)
	NetworkManager.world_ready_peers[42] = PeerWorldReadyState.new(SEWER, GameSession.get_peer_world(42).revision)
	NetworkManager.world_ready_peers[43] = PeerWorldReadyState.new(SEWER, GameSession.get_peer_world(43).revision)
	NetworkManager._replication_ready_after_msec[42] = 0
	NetworkManager._replication_ready_after_msec[43] = 0
	t.assert_equal(NetworkManager.replication_ready_remote_peer_ids(SEWER), [42, 43], "Sewer interest query selects only ready Sewer peers")
	t.assert_equal(NetworkManager.replication_ready_remote_peer_ids(&"settlement"), [], "Settlement interest query excludes Sewer peers and the local host")

	NetworkManager._local_peer_id = 42
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._session_entered = true
	t.assert_true(NetworkManager._accept_current_world_packet(SEWER, GameSession.get_peer_world(42).revision), "current-world packet passes exact revision validation")
	t.assert_true(not NetworkManager._accept_current_world_packet(SEWER, GameSession.get_peer_world(42).revision - 1), "stale world revision is rejected")
	t.assert_true(not NetworkManager._accept_current_world_packet(&"settlement", GameSession.get_peer_world(42).revision), "packet from another world is rejected")
	NetworkManager._local_peer_id = 1
	NetworkManager.state = NetworkManager.ConnectionState.OFFLINE
	NetworkManager._session_entered = false
	NetworkManager.players.clear()
	NetworkManager.world_ready_peers.clear()
	NetworkManager._replication_ready_after_msec.clear()
	GameSession.detach_player(42)
	GameSession.detach_player(43)
	GameSession.remove_player_state(PLAYER_B)
	GameSession.remove_player_state(PLAYER_C)
	GameSession.start_new_game()
