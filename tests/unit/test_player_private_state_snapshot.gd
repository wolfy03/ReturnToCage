extends RefCounted

const PLAYER_B := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLAYER_C := &"player_cccccccccccccccccccccccccccccccc"

func run(t: Node) -> void:
	_test_build_validate_apply(t)
	_test_malformed_payloads(t)
	_test_client_sync_gate(t)
	_test_private_sync_failure_blocks_readiness(t)
	_test_spawn_sync_failure_blocks_readiness(t)
	_test_owner_scope(t)
	NetworkManager.leave_game()
	GameSession.activate_offline_local_identity()

func _test_build_validate_apply(t: Node) -> void:
	var start := GameSession.get_start_definition()
	var source := _make_state(start)
	var effect := ContentRegistry.get_definition(&"quick_paws") as EffectDefinition
	source.stats.set_base(&"move_speed", 247.0)
	source.stats.set_base(&"attack_power", 17.0)
	source.survival.restore({"hunger": 31.0, "thirst": 42.0, "progression_reduction": 0.2})
	source.effects.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	source.effects.active_effects[&"quick_paws"].remaining = 23.5
	source.effects.active_effects[&"quick_paws"].tick_elapsed = 0.25
	source.last_safe_position = Vector2(321.5, 432.25)
	var built := PlayerPrivateStateSnapshot.from_state(PLAYER_B, source)
	var parsed := PlayerPrivateStateSnapshot.from_payload(built.to_payload(), ContentRegistry, start, PLAYER_B)
	t.assert_true(parsed.error_message.is_empty(), "valid owner-private state snapshot passes validation")

	var mirror := _make_state(start)
	var vest := ItemStack.new(&"leaf_vest", 1)
	vest.instance_id = "private_snapshot_vest"
	vest.durability = 40
	mirror.equipment.equip(vest)
	var private_signals := [0]
	var callback := func() -> void: private_signals[0] += 1
	mirror.private_state_changed.connect(callback)
	t.assert_true(mirror.apply_private_network_mirror(parsed, start, ContentRegistry), "validated private snapshot applies atomically")
	_assert_private_match(t, mirror, source, "first apply")
	var first_speed := mirror.stats.value(&"move_speed")
	var first_defense := mirror.stats.value(&"defense")
	var first_effect_count := mirror.effects.active_effects.size()
	t.assert_true(mirror.apply_private_network_mirror(parsed, start, ContentRegistry), "private snapshot reapply is idempotent")
	_assert_private_match(t, mirror, source, "second apply")
	t.assert_equal(mirror.stats.value(&"move_speed"), first_speed, "reapply does not stack effect stat modifiers")
	t.assert_equal(mirror.stats.value(&"defense"), first_defense, "reapply does not stack equipment stat modifiers")
	t.assert_equal(mirror.effects.active_effects.size(), first_effect_count, "reapply replaces rather than appends active effects")
	t.assert_equal(private_signals[0], 2, "one presentation signal emits per successful private apply")
	t.assert_true(not mirror.effects.paused, "attached client private effects resume after apply")
	var before_rejected_apply := _private_view(mirror)
	var invalid_direct := PlayerPrivateStateSnapshot.new()
	invalid_direct.player_id = PLAYER_B
	invalid_direct.stats = parsed.stats.duplicate(true)
	invalid_direct.survival = parsed.survival.duplicate(true)
	invalid_direct.survival["hunger"] = "invalid"
	invalid_direct.effects = parsed.effects.duplicate(true)
	invalid_direct.last_safe_position = parsed.last_safe_position
	t.assert_true(not mirror.apply_private_network_mirror(invalid_direct, start, ContentRegistry), "invalid private apply is rejected before live mutation")
	t.assert_equal(_private_view(mirror), before_rejected_apply, "rejected private apply leaves every live private domain unchanged")
	mirror.private_state_changed.disconnect(callback)

func _test_malformed_payloads(t: Node) -> void:
	var start := GameSession.get_start_definition()
	var valid := PlayerPrivateStateSnapshot.from_state(PLAYER_B, _make_state(start)).to_payload()
	for field in ["player_id", "stats", "survival", "effects", "last_safe_position"]:
		var missing := valid.duplicate(true)
		missing.erase(field)
		t.assert_true(not PlayerPrivateStateSnapshot.from_payload(missing, ContentRegistry, start, PLAYER_B).error_message.is_empty(), "private snapshot requires %s" % field)
	t.assert_true(not PlayerPrivateStateSnapshot.from_payload(valid, ContentRegistry, start, PLAYER_C).error_message.is_empty(), "private snapshot rejects a different owner identity")
	var invalid_stats := valid.duplicate(true)
	invalid_stats["stats"]["move_speed"] = "fast"
	t.assert_true(not PlayerPrivateStateSnapshot.from_payload(invalid_stats, ContentRegistry, start, PLAYER_B).error_message.is_empty(), "private snapshot rejects invalid base stats")
	var invalid_survival := valid.duplicate(true)
	invalid_survival["survival"]["hunger"] = 100000.0
	t.assert_true(not PlayerPrivateStateSnapshot.from_payload(invalid_survival, ContentRegistry, start, PLAYER_B).error_message.is_empty(), "private snapshot rejects out-of-range survival state")
	var invalid_effect := valid.duplicate(true)
	invalid_effect["effects"] = [{"effect_id": "missing_effect", "remaining": 5.0, "stacks": 1, "food_slot": 0, "source_id": "", "applied_by": "effect", "tick_elapsed": 0.0}]
	t.assert_true(not PlayerPrivateStateSnapshot.from_payload(invalid_effect, ContentRegistry, start, PLAYER_B).error_message.is_empty(), "private snapshot rejects unknown effects")
	var invalid_position := valid.duplicate(true)
	invalid_position["last_safe_position"] = [INF, 0.0]
	t.assert_true(not PlayerPrivateStateSnapshot.from_payload(invalid_position, ContentRegistry, start, PLAYER_B).error_message.is_empty(), "private snapshot rejects non-finite safe positions")

func _test_client_sync_gate(t: Node) -> void:
	NetworkManager.leave_game()
	var local_id := NetworkManager.local_profile_player_id()
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._local_peer_id = 42
	var synchronized := [0]
	var callback := func() -> void: synchronized[0] += 1
	NetworkManager.session_synchronized.connect(callback)
	NetworkManager._receive_session_snapshot({
		"protocol_version": NetworkProtocol.VERSION,
		"session_id": "private-sync-test",
		"phase": GameSession.Phase.SETTLEMENT,
		"difficulty_id": "normal",
		"players": [
			{"peer_id": 1, "player_id": "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
			{"peer_id": 42, "player_id": String(local_id)},
		],
	})
	t.assert_true(NetworkManager._received_session_snapshot and not NetworkManager._session_entered, "session snapshot alone does not complete client synchronization")
	t.assert_equal(synchronized[0], 0, "session_synchronized waits for owner-private state")
	var server_state := _make_state(GameSession.get_start_definition())
	server_state.stats.set_base(&"move_speed", 266.0)
	server_state.survival.hunger = 27.0
	server_state.last_safe_position = Vector2(91, 123)
	var private_snapshot := PlayerPrivateStateSnapshot.from_state(local_id, server_state)
	NetworkManager._receive_private_player_state(private_snapshot.to_payload())
	t.assert_true(NetworkManager._received_private_player_state and not NetworkManager._session_entered, "private apply still waits for authoritative spawn")
	t.assert_equal(synchronized[0], 0, "session_synchronized waits for the spawn assignment")
	t.assert_equal(GameSession.player.stats.to_dict(), server_state.stats.to_dict(), "sync gate installs authoritative private base stats")
	t.assert_equal(GameSession.player.survival.to_dict(), server_state.survival.to_dict(), "sync gate installs authoritative private survival")
	t.assert_equal(GameSession.player.last_safe_position, server_state.last_safe_position, "sync gate installs authoritative private safe position")
	var spawn := PlayerSpawnAssignment.create(
		"private-sync-test", local_id, PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION,
		Vector2(91, 123)
	)
	NetworkManager._receive_spawn_assignment(spawn.to_payload())
	t.assert_true(NetworkManager._received_spawn_assignment and NetworkManager._session_entered, "spawn assignment completes the client synchronization gate")
	t.assert_equal(synchronized[0], 1, "session_synchronized emits once after all three snapshots")
	NetworkManager._receive_private_player_state(private_snapshot.to_payload())
	t.assert_equal(synchronized[0], 1, "duplicate private RPC cannot emit duplicate session readiness")
	NetworkManager.session_synchronized.disconnect(callback)
	NetworkManager.leave_game()

func _test_owner_scope(t: Node) -> void:
	GameSession.start_new_game()
	var state_b := GameSession.attach_player(42, PLAYER_B)
	var state_c := GameSession.attach_player(43, PLAYER_C)
	state_b.stats.set_base(&"attack_power", 42.0)
	state_c.stats.set_base(&"attack_power", 84.0)
	var snapshot_b := PlayerPrivateStateSnapshot.from_state(PLAYER_B, state_b)
	var snapshot_c := PlayerPrivateStateSnapshot.from_state(PLAYER_C, state_c)
	t.assert_equal(snapshot_b.player_id, PLAYER_B, "B private snapshot is scoped to B")
	t.assert_equal(snapshot_c.player_id, PLAYER_C, "C private snapshot is scoped to C")
	t.assert_equal(snapshot_b.stats["attack_power"], 42.0, "B payload contains B canonical state")
	t.assert_true(not snapshot_b.to_payload().has(String(PLAYER_C)), "B payload contains no C private record")
	GameSession.detach_player(42)
	GameSession.detach_player(43)

func _test_private_sync_failure_blocks_readiness(t: Node) -> void:
	NetworkManager.leave_game()
	var local_id := NetworkManager.local_profile_player_id()
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._local_peer_id = 42
	NetworkManager._receive_session_snapshot({
		"protocol_version": NetworkProtocol.VERSION,
		"session_id": "private-sync-failure-test",
		"phase": GameSession.Phase.SETTLEMENT,
		"difficulty_id": "normal",
		"players": [
			{"peer_id": 1, "player_id": "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
			{"peer_id": 42, "player_id": String(local_id)},
		],
	})
	var invalid := PlayerPrivateStateSnapshot.from_state(local_id, _make_state(GameSession.get_start_definition())).to_payload()
	invalid["last_safe_position"] = [NAN, 0.0]
	NetworkManager._receive_private_player_state(invalid)
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "malformed private snapshot closes the incomplete client session")
	t.assert_true(not NetworkManager._session_entered and not NetworkManager._received_session_snapshot \
			and not NetworkManager._received_private_player_state and not NetworkManager._received_spawn_assignment, "private validation failure cannot leave any readiness gate open")
	t.assert_true(NetworkManager.last_error.contains("Invalid player private snapshot"), "private synchronization failure exposes a concrete validation error")

func _test_spawn_sync_failure_blocks_readiness(t: Node) -> void:
	NetworkManager.leave_game()
	var local_id := NetworkManager.local_profile_player_id()
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._local_peer_id = 42
	NetworkManager._receive_session_snapshot({
		"protocol_version": NetworkProtocol.VERSION,
		"session_id": "spawn-sync-failure-test",
		"phase": GameSession.Phase.SETTLEMENT,
		"difficulty_id": "normal",
		"players": [
			{"peer_id": 1, "player_id": "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
			{"peer_id": 42, "player_id": String(local_id)},
		],
	})
	var private_snapshot := PlayerPrivateStateSnapshot.from_state(
		local_id, _make_state(GameSession.get_start_definition())
	)
	NetworkManager._receive_private_player_state(private_snapshot.to_payload())
	var stale_spawn := PlayerSpawnAssignment.create(
		"stale-session", local_id, PlayerSpawnAssignment.SpawnKind.FRESH_SLOT,
		Vector2(160, 520)
	)
	NetworkManager._receive_spawn_assignment(stale_spawn.to_payload())
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "stale-session spawn assignment closes the incomplete client session")
	t.assert_true(not NetworkManager._received_spawn_assignment and NetworkManager._spawn_assignments.is_empty(), "invalid spawn assignment cannot poison the next session cache")

func _make_state(start: GameStartDefinition) -> PlayerState:
	var state := PlayerState.new(Callable(ContentRegistry, "get_item"))
	state.reset(start, ContentRegistry)
	return state

func _assert_private_match(t: Node, actual: PlayerState, expected: PlayerState, label: String) -> void:
	t.assert_equal(actual.stats.to_dict(), expected.stats.to_dict(), "%s preserves base stats" % label)
	t.assert_equal(actual.survival.to_dict(), expected.survival.to_dict(), "%s preserves survival state" % label)
	t.assert_equal(actual.effects.to_array(), expected.effects.to_array(), "%s preserves active effects" % label)
	t.assert_equal(actual.last_safe_position, expected.last_safe_position, "%s preserves last safe position" % label)

func _private_view(state: PlayerState) -> Dictionary:
	return {
		"stats": state.stats.to_dict(),
		"survival": state.survival.to_dict(),
		"effects": state.effects.to_array(),
		"last_safe_position": state.last_safe_position,
	}
