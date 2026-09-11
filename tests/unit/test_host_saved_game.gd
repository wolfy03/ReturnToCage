extends RefCounted

const REMOTE_B := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const REMOTE_C := &"player_cccccccccccccccccccccccccccccccc"
const FRESH_D := &"player_dddddddddddddddddddddddddddddddd"

func run(t: Node) -> void:
	NetworkManager.leave_game()
	t.assert_true(GameSession.activate_offline_local_identity(), "saved-host tests begin with an activated offline identity")
	_test_non_host_authority_truth_table(t)
	var local_id := NetworkManager.local_profile_player_id()
	var token := "%s_%s" % [Time.get_ticks_usec(), randi()]
	var path := "user://host_saved_game_%s.json" % token
	var corrupt_path := "user://host_saved_game_corrupt_%s.json" % token
	var saved_state := _build_saved_fixture(t, local_id)
	_write_json(path, {"format_version": SaveManager.CURRENT_VERSION, "saved_at": "host-restore-test"}.merged(saved_state))
	_write(corrupt_path, "{corrupt")

	_test_detached_staging(t, path, local_id)
	_test_bind_failure_does_not_apply(t, path, local_id)
	_test_gated_transport_and_restore(t, path, local_id)
	await _test_app_root_orchestration(t, path, corrupt_path, local_id)
	_test_fresh_host_authority(t)

	_cleanup(path)
	_cleanup(corrupt_path)
	if NetworkManager.is_multiplayer_active():
		NetworkManager.leave_game()
	t.assert_true(GameSession.activate_offline_local_identity(), "saved-host tests restore the offline identity")

func _test_non_host_authority_truth_table(t: Node) -> void:
	t.assert_true(not NetworkManager.is_server() and not NetworkManager.is_session_connected(), "OFFLINE has no server role or connected session")
	t.assert_true(NetworkManager.is_authoritative_simulation(), "OFFLINE retains local gameplay authority")
	t.assert_true(not NetworkManager.is_host_session_ready(), "OFFLINE is not a ready host session")
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTING
	t.assert_true(not NetworkManager.is_server() and not NetworkManager.is_session_connected() \
			and not NetworkManager.is_authoritative_simulation(), "CONNECTING has no server role, ready session, or gameplay authority")
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	t.assert_true(not NetworkManager.is_server() and NetworkManager.is_session_connected() \
			and not NetworkManager.is_authoritative_simulation(), "CONNECTED client has connectivity without gameplay authority")
	NetworkManager.state = NetworkManager.ConnectionState.OFFLINE

func _build_saved_fixture(t: Node, local_id: StringName) -> Dictionary:
	t.assert_true(GameSession.start_new_game(), "saved-host fixture starts a canonical session")
	GameSession.session_id = "saved-host-session"
	GameSession.play_time_seconds = 321.5
	GameSession.get_player_state_by_player_id(local_id).set_health(83.0)
	var remote_b := GameSession.attach_player(42, REMOTE_B)
	var remote_c := GameSession.attach_player(43, REMOTE_C)
	t.assert_true(remote_b != null and remote_c != null, "saved-host fixture creates remote canonical players")
	remote_b.set_health(37.0)
	remote_b.stats.set_base(&"move_speed", 244.0)
	remote_b.survival.hunger = 34.0
	remote_b.survival.thirst = 45.0
	remote_b.effects.apply_effect(ContentRegistry.get_definition(&"quick_paws") as EffectDefinition, ItemDefinition.FoodSlot.SNACK)
	remote_b.last_safe_position = Vector2(345, 456)
	remote_b.inventory.initialize([ItemStack.new(&"berry", 4)])
	remote_c.set_health(61.0)
	remote_c.protected_inventory.initialize([ItemStack.new(&"return_seed", 1)])
	GameSession.detach_player(42)
	GameSession.detach_player(43)
	var result := GameSession.export_persistent_state()
	t.assert_equal(GameSession.persistent_player_count(), 3, "fixture contains host and two detached players")
	t.assert_equal(GameSession.players.size(), 1, "fixture attaches only the host")
	return result

func _test_detached_staging(t: Node, path: String, local_id: StringName) -> void:
	t.assert_true(GameSession.start_new_game(), "staging test installs a distinct live session")
	var live_before := GameSession.export_persistent_state()
	var prepared := SaveManager.prepare_load(path, local_id)
	t.assert_true(prepared.success, "Host Saved Game performs full Save staging")
	t.assert_equal(GameSession.export_persistent_state(), live_before, "Save staging does not mutate live GameSession")
	var snapshot: SessionSnapshot = prepared.snapshot
	t.assert_equal(snapshot.local_player_id, local_id, "staging selects the current persistent profile identity")
	t.assert_equal(snapshot.players_by_id.size(), 3, "staging restores every canonical player record")
	t.assert_true(snapshot.players_by_id.has(REMOTE_B) and snapshot.players_by_id.has(REMOTE_C), "staging retains saved remote identities")

func _test_bind_failure_does_not_apply(t: Node, path: String, local_id: StringName) -> void:
	var prepared := SaveManager.prepare_load(path, local_id)
	t.assert_true(prepared.success, "bind failure test has a valid detached snapshot")
	var live_before := GameSession.export_persistent_state()
	var port := 21000 + randi_range(0, 2000)
	NetworkManager._host_transport_error_for_test = ERR_CANT_CREATE
	var open_error := NetworkManager.begin_host_restore(port, 3)
	t.assert_equal(open_error, ERR_CANT_CREATE, "Host Saved Game reports a deterministic port bind failure")
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "port bind failure leaves transport offline")
	t.assert_true(NetworkManager.players.is_empty() and not NetworkManager.is_accepting_handshakes(), "port bind failure creates no active network roster")
	t.assert_equal(GameSession.export_persistent_state(), live_before, "port bind failure never applies the staged snapshot")

func _test_gated_transport_and_restore(t: Node, path: String, local_id: StringName) -> void:
	t.assert_true(GameSession.start_new_game(), "gated restore starts from a distinct offline session")
	var live_before := GameSession.export_persistent_state()
	var prepared := SaveManager.prepare_load(path, local_id)
	var ready_signals := [0]
	var ready_callback := func() -> void: ready_signals[0] += 1
	NetworkManager.hosting_started.connect(ready_callback)
	var port := 22000 + randi_range(0, 1000)
	t.assert_equal(NetworkManager.begin_host_restore(port, 3), OK, "valid staging permits gated server transport open")
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.HOSTING_RESTORING, "server transport exposes an explicit restoring state")
	t.assert_true(NetworkManager.is_server() and not NetworkManager.is_session_connected(), "restoring host has the transport server role but no ready session")
	t.assert_true(not NetworkManager.is_authoritative_simulation() and not NetworkManager.is_host_session_ready(), "restoring host has no gameplay authority")
	t.assert_true(not NetworkManager.is_accepting_handshakes(), "restoring transport keeps the handshake gate closed")
	t.assert_true(not SaveManager.can_load().success and not SaveManager.can_save().success, "restoring host rejects competing Save and Load operations")
	t.assert_equal(ready_signals[0], 0, "transport open does not emit hosting_started")
	t.assert_true(NetworkManager.players.is_empty() and NetworkManager.peer_to_player.is_empty(), "gated transport has no partial host or remote roster")
	t.assert_equal(GameSession.export_persistent_state(), live_before, "gated transport open does not mutate GameSession")
	var restoring_phase := GameSession.phase
	var restoring_session_id := GameSession.session_id
	var restoring_play_time := GameSession.play_time_seconds
	t.assert_true(not GameSession.start_new_game(), "direct New Game is rejected while host restoration is pending")
	GameSession._process(5.0)
	t.assert_equal(GameSession.export_persistent_state(), live_before, "rejected New Game and restoring tick leave canonical state unchanged")
	t.assert_equal(GameSession.phase, restoring_phase, "restoring command rejection preserves phase")
	t.assert_equal(GameSession.session_id, restoring_session_id, "restoring command rejection preserves session ID")
	t.assert_equal(GameSession.play_time_seconds, restoring_play_time, "restoring authoritative tick remains frozen")
	t.assert_true(NetworkManager.players.is_empty() and NetworkManager.peer_to_player.is_empty(), "rejected gameplay command creates no network mapping")
	var canonical_before := GameSession.persistent_player_count()
	NetworkManager._request_handshake(NetworkProtocol.VERSION, REMOTE_B, "B")
	t.assert_equal(GameSession.persistent_player_count(), canonical_before, "handshake before ready cannot attach canonical state")
	t.assert_true(NetworkManager.players.is_empty() and NetworkManager.peer_to_player.is_empty(), "handshake before ready leaves active network mappings empty")

	var snapshot: SessionSnapshot = prepared.snapshot
	t.assert_true(GameSession.apply_persistent_snapshot(snapshot), "staged Save applies after transport open")
	t.assert_equal(GameSession.persistent_player_count(), 3, "apply restores all canonical player states")
	t.assert_equal(GameSession.players.size(), 1, "apply attaches only the saved local host")
	t.assert_true(not NetworkManager.is_accepting_handshakes() and not NetworkManager.is_authoritative_simulation(), "snapshot apply alone opens neither handshake nor gameplay authority")
	t.assert_equal(NetworkManager.finalize_host_restore(), OK, "validated host attachment finalizes restore")
	t.assert_equal(ready_signals[0], 1, "host-ready signal emits once after finalization")
	t.assert_true(NetworkManager.is_accepting_handshakes() and NetworkManager.is_host_session_ready(), "finalization opens the ready host boundary")
	t.assert_true(NetworkManager.is_authoritative_simulation(), "finalization enables gameplay authority")
	t.assert_equal(NetworkManager.players.size(), 1, "finalization creates only the host network roster")
	t.assert_equal(NetworkManager.player_id_for_peer(1), local_id, "finalization maps host peer 1 to the saved profile")
	NetworkManager.hosting_started.disconnect(ready_callback)
	NetworkManager.leave_game()
	t.assert_true(not NetworkManager.is_server() and NetworkManager.is_authoritative_simulation(), "abort/leave returns to authoritative offline semantics")

func _test_app_root_orchestration(t: Node, path: String, corrupt_path: String, local_id: StringName) -> void:
	var app := (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	t.add_child(app)
	await t.get_tree().process_frame
	var live_before := GameSession.export_persistent_state()
	var invalid_port := 23000 + randi_range(0, 1000)
	app._host_saved_game(corrupt_path, invalid_port, 3)
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "invalid Save opens no server transport")
	t.assert_equal(GameSession.export_persistent_state(), live_before, "invalid Save leaves the live session unchanged")
	t.assert_true(app.menu.visible and app.error_label.visible, "invalid Saved Host remains on the menu with an error")

	var rollback_prepared := SaveManager.prepare_load(path, local_id)
	var rollback_port := 23500 + randi_range(0, 400)
	app._set_host_restore_busy(true)
	t.assert_equal(NetworkManager.begin_host_restore(rollback_port, 3), OK, "rollback fixture opens gated transport")
	t.assert_true(GameSession.apply_persistent_snapshot(rollback_prepared.snapshot), "rollback fixture applies its staged snapshot")
	GameSession.detach_player(1)
	t.assert_true(NetworkManager.finalize_host_restore() != OK, "invalid restored host attachment prevents finalization")
	t.assert_true(NetworkManager.is_server() and not NetworkManager.is_authoritative_simulation(), "failed finalization retains transport role without gameplay authority")
	app._rollback_host_restore(NetworkManager.last_error)
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "finalization failure closes host transport")
	t.assert_true(not NetworkManager.is_server() and NetworkManager.is_authoritative_simulation(), "rollback restores offline authority semantics")
	t.assert_true(NetworkManager.is_local_identity_activated(), "finalization failure restores the offline local identity")
	t.assert_equal(GameSession.persistent_player_ids(), [local_id], "finalization failure removes restored remote session state")
	t.assert_true(not app._host_restore_pending and not app.multiplayer_panel.host_saved_button.disabled, "rollback clears lifecycle busy state")

	var ready_signals := [0]
	var ready_callback := func() -> void: ready_signals[0] += 1
	NetworkManager.hosting_started.connect(ready_callback)
	var port := 24000 + randi_range(0, 1000)
	app._host_saved_game(path, port, 3)
	t.assert_equal(ready_signals[0], 1, "hosting_started emits only after restore finalization")
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.HOSTING, "Saved Host becomes ready after snapshot apply")
	t.assert_true(not app.menu.visible and app.world_layer.get_child_count() == 1, "Saved Host enters Settlement only after readiness")
	t.assert_true(NetworkManager.is_accepting_handshakes(), "Saved Host enables handshakes only when ready")
	t.assert_equal(GameSession.session_id, "saved-host-session", "Saved Host retains the persisted session ID")
	t.assert_true(absf(GameSession.play_time_seconds - 321.5) < 0.01, "Saved Host retains persisted play time")
	t.assert_equal(GameSession.persistent_player_count(), 3, "Saved Host restores host and remote canonical registry")
	t.assert_equal(GameSession.players.size(), 1, "Saved Host actively attaches only peer 1")
	t.assert_equal(GameSession.get_local_player_id(), local_id, "Saved Host attaches the existing saved host state")
	t.assert_equal(GameSession.player.health, 83.0, "Saved Host does not replace the restored host PlayerState")
	t.assert_equal(NetworkManager.players.size(), 1, "Saved Host network roster contains only the host")
	t.assert_equal(NetworkManager.player_id_for_peer(1), local_id, "Saved Host network roster maps peer 1 to the profile")
	t.assert_equal(NetworkManager.peer_id_for_player(REMOTE_B), 0, "saved remote B has no restored peer ID")
	t.assert_equal(NetworkManager.peer_id_for_player(REMOTE_C), 0, "saved remote C has no restored peer ID")
	t.assert_equal(NetworkManager.world_ready_peers.keys(), [1], "only the host starts world-ready")
	t.assert_equal(GameSession.get_player_state_by_player_id(REMOTE_B).health, 37.0, "detached remote B retains private state")
	t.assert_equal(GameSession.get_player_state_by_player_id(REMOTE_C).health, 61.0, "detached remote C retains private state")

	var exported_after_restore := GameSession.export_persistent_state()
	var original := _read_json(path)
	var expected_export := {"shared": original["shared"], "players": original["players"]}
	var normalized_export: Variant = JSON.parse_string(JSON.stringify(exported_after_restore))
	t.assert_equal(normalized_export, expected_export, "immediate export is semantically identical to the staged Save")

	var restored_b := GameSession.get_player_state_by_player_id(REMOTE_B)
	t.assert_true(restored_b.effects.paused, "saved remote B keeps detach pause as host runtime state only")
	t.assert_true(NetworkManager._set_identity(77, REMOTE_B), "returning B receives a new active peer mapping")
	NetworkManager.players[77] = NetworkPlayerInfo.new(77, REMOTE_B, "B", true)
	t.assert_true(GameSession.attach_player(77, REMOTE_B) == restored_b, "returning B attaches the exact restored canonical object")
	t.assert_equal(GameSession.get_player(77).inventory.count(&"berry"), 4, "returning B retains saved private items")
	var private_b := GameSession.make_player_private_snapshot(77)
	t.assert_true(private_b != null and private_b.player_id == REMOTE_B, "returning B owner-private payload derives from its active sender mapping")
	var parsed_private_b := PlayerPrivateStateSnapshot.from_payload(private_b.to_payload(), ContentRegistry, GameSession.get_start_definition(), REMOTE_B)
	var client_b := PlayerState.new(Callable(ContentRegistry, "get_item"))
	client_b.reset(GameSession.get_start_definition(), ContentRegistry)
	t.assert_true(client_b.apply_private_network_mirror(parsed_private_b, GameSession.get_start_definition(), ContentRegistry), "saved detached B private state applies to its client mirror")
	t.assert_equal(client_b.stats.to_dict(), restored_b.stats.to_dict(), "saved detached B restores base stats to its owner")
	t.assert_equal(client_b.survival.to_dict(), restored_b.survival.to_dict(), "saved detached B restores survival state to its owner")
	t.assert_equal(client_b.effects.to_array(), restored_b.effects.to_array(), "saved detached B restores active effects to its owner")
	t.assert_equal(client_b.last_safe_position, restored_b.last_safe_position, "saved detached B restores last-safe position to its owner")
	t.assert_true(not client_b.effects.paused, "detach pause is not serialized into the owning client mirror")
	t.assert_equal(NetworkManager._handshake_identity_error(88, REMOTE_B), "Player identity is already connected", "duplicate active B identity remains rejected")
	t.assert_equal(NetworkManager._handshake_identity_error(88, local_id), "Player identity is already connected", "remote host identity forgery remains rejected")

	t.assert_true(NetworkManager._set_identity(78, FRESH_D), "fresh player receives an active identity mapping")
	NetworkManager.players[78] = NetworkPlayerInfo.new(78, FRESH_D, "D", true)
	var fresh_d := GameSession.attach_player(78, FRESH_D)
	t.assert_true(fresh_d != null and GameSession.get_player_state_by_player_id(FRESH_D) == fresh_d, "unknown identity follows the existing fresh-player path")
	t.assert_true(not NetworkManager.world_ready_peers.has(77) and not NetworkManager.world_ready_peers.has(78), "new attachments are not world-ready before scene confirmation")
	var exported_with_detached := GameSession.export_persistent_state()
	t.assert_true(exported_with_detached.players.has(String(REMOTE_C)), "still-detached C remains in canonical Save export")

	NetworkManager.hosting_started.disconnect(ready_callback)
	NetworkManager.leave_game()
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.OFFLINE, "leaving a Saved Host closes transport")
	t.assert_equal(GameSession.persistent_player_ids(), [local_id], "leaving removes saved remote session state from the offline menu")
	app.queue_free()
	await t.get_tree().process_frame

func _test_fresh_host_authority(t: Node) -> void:
	var port := 25200 + randi_range(0, 600)
	t.assert_equal(NetworkManager.host_game(port, 2), OK, "fresh Host still finalizes normally")
	t.assert_equal(NetworkManager.state, NetworkManager.ConnectionState.HOSTING, "fresh Host reaches HOSTING")
	t.assert_true(NetworkManager.is_server() and NetworkManager.is_session_connected(), "fresh Host has server and connected-session semantics")
	t.assert_true(NetworkManager.is_host_session_ready() and NetworkManager.is_authoritative_simulation(), "fresh Host receives gameplay authority after finalization")
	t.assert_true(NetworkManager.is_accepting_handshakes(), "fresh Host accepts handshakes after finalization")
	NetworkManager.leave_game()

func _write_json(path: String, value: Dictionary) -> void:
	_write(path, JSON.stringify(value))

func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(contents)
		file.flush()
		file.close()

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}

func _cleanup(path: String) -> void:
	for suffix: String in ["", ".tmp", ".bak"]:
		var candidate: String = path + suffix
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
