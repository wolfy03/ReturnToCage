extends Node

const PERSONAL_QUEST_ID := &"restart_personal_probe"
const SHARED_QUEST_ID := &"restart_shared_probe"
const SETTLEMENT_SCENE := preload("res://world/settlement/settlement.tscn")
const APP_SCENE := preload("res://core/boot.tscn")

const MODE_SEED_HOST := "seed_host"
const MODE_SEED_CLIENT := "seed_client"
const MODE_RESUME_HOST := "resume_host"
const MODE_RESUME_CLIENT := "resume_client"
const MODE_DUPLICATE_CLIENT := "duplicate_client"

var mode: String = ""
var label: String = ""
var scenario: String = "valid"
var port: int = 17777
var expected_players: int = 2
var result_path: String = ""
var expected_path: String = ""
var release_path: String = ""
var timeout_seconds: float = 35.0

var _deadline_msec: int = 0
var _world: Node2D
var _app: AppRoot
var _seeded: bool = false
var _labels_by_peer: Dictionary[int, String] = {}
var _expected: Dictionary = {}
var _detached_instance_ids: Dictionary[StringName, int] = {}
var _reattach_counts: Dictionary[StringName, int] = {}
var _confirmed_players: Dictionary[StringName, bool] = {}
var _restored_host_state: Dictionary = {}
var _restored_play_time_seconds: float = 0.0
var _client_sync_pending: bool = false
var _client_sync_round: int = 0
var _client_first_peer_id: int = 0
var _client_process_restart_assignment: Dictionary = {}
var _client_process_restart_actor_position := Vector2.ZERO
var _client_healed_safe_position := Vector2.ZERO
var _client_initial_actor_position := Vector2.ZERO
var _client_assignment: PlayerSpawnAssignment
var _final_client_result: Dictionary = {}
var _expect_host_disconnect: bool = false
var _finishing: bool = false
var _last_wait_reason: String = ""
var _last_diag_msec: int = 0

func _ready() -> void:
	_parse_arguments()
	_install_probe_quests()
	_deadline_msec = Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	NetworkManager.session_synchronized.connect(_on_session_synchronized)
	NetworkManager.peer_joined.connect(_on_peer_joined)
	NetworkManager.connection_failed.connect(_on_connection_failed)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	call_deferred("_start")

func _process(_delta: float) -> void:
	if _finishing:
		return
	if Time.get_ticks_msec() > _deadline_msec:
		_fail("Timeout in %s/%s: %s" % [mode, label, _last_wait_reason])
		return
	match mode:
		MODE_SEED_HOST:
			_poll_seed_host()
		MODE_RESUME_HOST:
			_poll_resume_host()

func _start() -> void:
	match mode:
		MODE_SEED_HOST:
			_start_seed_host()
		MODE_SEED_CLIENT, MODE_RESUME_CLIENT, MODE_DUPLICATE_CLIENT:
			await _start_client()
		MODE_RESUME_HOST:
			await _start_resume_host()
		_:
			_fail("Unknown restart probe mode: %s" % mode)

func _start_seed_host() -> void:
	if NetworkManager.host_game(port, NetworkManager.MAX_PLAYERS) != OK:
		_fail("Fresh Host failed: %s" % NetworkManager.last_error)
		return
	if not GameSession.start_new_game():
		_fail("Fresh Host could not start a new session: %s" % GameSession.last_message)
		return
	_world = SETTLEMENT_SCENE.instantiate() as Node2D
	add_child(_world)
	_write_result({
		"status": "host_seed_ready",
		"role": "host",
		"phase": "seed",
		"player_id": String(NetworkManager.local_profile_player_id()),
		"session_id": GameSession.session_id,
		"profile": _profile_summary(),
	})
	print("RESTART PROBE HOST SEED READY")

func _start_client() -> void:
	if label.is_empty():
		_fail("Client label is required")
		return
	# Saved Host enters Settlement through AppRoot. Restarted clients instantiate
	# the same production root so scene-relative multiplayer RPC paths match and
	# AppRoot owns the normal Join -> Settlement transition.
	if mode == MODE_RESUME_CLIENT:
		_expected = _read_json(expected_path)
		if _expected.is_empty():
			_fail("Cannot read phase-one expected state")
			return
		_app = APP_SCENE.instantiate() as AppRoot
		add_child(_app)
		await get_tree().process_frame
	if NetworkManager.join_game("127.0.0.1", port) != OK:
		_fail("Join failed: %s" % NetworkManager.last_error)

func _start_resume_host() -> void:
	_expected = _read_json(expected_path)
	if _expected.is_empty():
		_fail("Cannot read phase-one expected state")
		return
	_app = APP_SCENE.instantiate() as AppRoot
	add_child(_app)
	await get_tree().process_frame
	_app._host_saved_game(SaveManager.SAVE_PATH, port, NetworkManager.MAX_PLAYERS)
	if NetworkManager.state != NetworkManager.ConnectionState.HOSTING \
			or not NetworkManager.is_host_session_ready() or _app.world_layer.get_child_count() != 1:
		_fail("Host Saved Game did not reach a ready Settlement session: %s" % NetworkManager.last_error)
		return
	_world = _app.world_layer.get_child(0) as Node2D
	var expected_records: Dictionary = _expected.get("players", {})
	if GameSession.persistent_player_count() != expected_records.size() or GameSession.players.size() != 1:
		_fail("Saved Host registry did not restore canonical/detached counts")
		return
	for raw_player_id in expected_records:
		var player_id := StringName(raw_player_id)
		var state := GameSession.get_player_state_by_player_id(player_id)
		if state == null:
			_fail("Saved Host omitted canonical player %s" % _fingerprint(player_id))
			return
		if player_id != GameSession.get_local_player_id():
			_detached_instance_ids[player_id] = state.get_instance_id()
			if NetworkManager.peer_id_for_player(player_id) != 0:
				_fail("Saved remote player restored with a stale peer mapping")
				return
	var local_mismatch := _state_mismatch(
		expected_records[String(GameSession.get_local_player_id())], GameSession.player, false
	)
	if not local_mismatch.is_empty():
		_fail("Saved Host local private state differs from phase-one Save: %s" % local_mismatch)
		return
	var invariant_errors := NetworkManager.validate_runtime_invariants()
	if not invariant_errors.is_empty():
		_fail("Saved Host runtime invariant failed: %s" % "; ".join(invariant_errors))
		return
	_restored_host_state = _state_summary(GameSession.get_local_player_id())
	_restored_host_state["label"] = "A"
	_restored_play_time_seconds = GameSession.play_time_seconds
	_write_result({
		"status": "host_restore_ready",
		"role": "host",
		"phase": "resume",
		"player_id": String(NetworkManager.local_profile_player_id()),
		"session_id": GameSession.session_id,
		"play_time_seconds": _restored_play_time_seconds,
		"host_private": _restored_host_state,
		"canonical_count": GameSession.persistent_player_count(),
		"active_count": GameSession.players.size(),
		"detached_count": _detached_instance_ids.size(),
		"profile": _profile_summary(),
		"registry_valid": true,
	})
	print("RESTART PROBE HOST RESTORE READY")

func _poll_seed_host() -> void:
	if _seeded or NetworkManager.state != NetworkManager.ConnectionState.HOSTING:
		return
	if NetworkManager.players.size() != expected_players \
			or NetworkManager.world_ready_peers.size() != expected_players \
			or _labels_by_peer.size() != expected_players - 1:
		return
	_seeded = true
	_seed_and_save()

func _seed_and_save() -> void:
	var labels_by_player: Dictionary[StringName, String] = {
		GameSession.get_local_player_id(): "A",
	}
	for peer_id in _labels_by_peer:
		var player_id := NetworkManager.player_id_for_peer(peer_id)
		if player_id.is_empty():
			_fail("Seed peer has no persistent player identity")
			return
		labels_by_player[player_id] = _labels_by_peer[peer_id]
	var ordered_labels := labels_by_player.values()
	ordered_labels.sort()
	for index in ordered_labels.size():
		var player_label: String = ordered_labels[index]
		var player_id := _player_id_for_label(labels_by_player, player_label)
		var state := GameSession.get_player_state_by_player_id(player_id)
		if state == null or not _seed_player_state(state, player_id, player_label, index):
			_fail("Could not seed player %s" % player_label)
			return
		if not GameSession.start_quest(PERSONAL_QUEST_ID, player_id):
			_fail("Could not start personal restart quest for %s" % player_label)
			return
		GameSession.report_quest_event(
			QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, &"sewer_beetle", 1, player_id
		)
	if not GameSession.start_quest(SHARED_QUEST_ID, GameSession.get_local_player_id()):
		_fail("Could not start shared restart quest")
		return
	GameSession.report_quest_event(
		QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY,
		&"sewer_beetle", 1, GameSession.get_local_player_id()
	)
	if not GameSession.settlement.storage.initialize([ItemStack.new(&"moss_fiber", 7)]).success:
		_fail("Could not seed shared Settlement storage")
		return
	if not SaveManager.save_game():
		_fail("Could not write the phase-one Save v4")
		return
	var records: Dictionary = {}
	for player_id in labels_by_player:
		var summary := _state_summary(player_id)
		summary["label"] = labels_by_player[player_id]
		records[String(player_id)] = summary
	var save_root := _read_json(ProjectSettings.globalize_path(SaveManager.SAVE_PATH))
	var saved_shared: Dictionary = save_root.get("shared", {})
	var saved_session: Dictionary = saved_shared.get("session", {})
	var result := {
		"status": "seed_saved",
		"role": "host",
		"phase": "seed",
		"scenario": scenario,
		"player_id": String(NetworkManager.local_profile_player_id()),
		"session_id": GameSession.session_id,
		"play_time_seconds": float(saved_session.get("play_time_seconds", -1.0)),
		"player_ids": _string_player_ids(GameSession.persistent_player_ids()),
		"canonical_count": GameSession.persistent_player_count(),
		"active_count": GameSession.players.size(),
		"players": records,
		"shared": _shared_summary(),
		"saved_at": save_root.get("saved_at", ""),
		"save_exists": FileAccess.file_exists(SaveManager.SAVE_PATH),
		"save_sha256": FileAccess.get_sha256(SaveManager.SAVE_PATH),
		"profile": _profile_summary(),
		"registry_errors": Array(NetworkManager.validate_runtime_invariants()),
	}
	_write_result(result)
	_seed_saved.rpc()
	print("RESTART PROBE SEED SAVED %d PLAYERS" % records.size())
	await get_tree().create_timer(0.6).timeout
	_finish_success()

func _seed_player_state(
	state: PlayerState,
	player_id: StringName,
	player_label: String,
	index: int
) -> bool:
	state.effects.restore([], Callable(ContentRegistry, "get_definition"))
	state.stats.set_base(&"move_speed", 221.0 + index * 17.0)
	state.survival.hunger = 31.0 + index * 11.0
	state.survival.thirst = 42.0 + index * 9.0
	state.survival.progression_reduction = 0.1 + index * 0.1
	state.set_health(87.0 - index * 13.0)
	state.begin_item_update()
	var inventory_ok := state.inventory.initialize([
		ItemStack.new(&"water_drop", 2 + index),
	]).success
	var protected_ok := state.protected_inventory.initialize([
		ItemStack.new(&"return_seed", mini(3, 1 + index)),
	]).success
	var vest := ItemStack.new(&"leaf_vest", 1)
	vest.instance_id = "restart_%s_%s_vest" % [player_label.to_lower(), _fingerprint(player_id)]
	vest.durability = 30 + index
	var equipment_ok := state.equipment.initialize({
		EquipmentDefinition.EquipmentSlot.BODY: vest,
	}).success
	state.end_item_update()
	state.effects.apply_effect(
		ContentRegistry.get_definition(&"quick_paws") as EffectDefinition,
		ItemDefinition.FoodSlot.SNACK
	)
	var safe_position := Vector2(350.0 + index * 80.0, 500.0)
	if scenario == "invalid" and player_label == "B":
		safe_position = Vector2(2000.0, 500.0)
	return inventory_ok and protected_ok and equipment_ok \
			and state.update_last_safe_position(safe_position)

func _poll_resume_host() -> void:
	if _app == null or not FileAccess.file_exists(release_path):
		return
	if _finishing:
		return
	_finishing = true
	var expected_records: Dictionary = _expected.get("players", {})
	if _confirmed_players.size() != expected_players - 1 \
			or GameSession.players.size() != expected_players \
			or GameSession.persistent_player_count() != expected_players:
		_fail_now("Host release arrived before every restarted client was ready")
		return
	for raw_player_id in expected_records:
		var player_id := StringName(raw_player_id)
		if player_id == GameSession.get_local_player_id():
			continue
		var state := GameSession.get_player_state_by_player_id(player_id)
		if state == null or state.get_instance_id() != _detached_instance_ids.get(player_id, -1):
			_fail_now("Returning player did not reuse its restored canonical object")
			return
		if _reattach_counts.get(player_id, 0) < 2:
			_fail_now("Returning player did not complete same-session reconnect after restart")
			return
	var invariant_errors := NetworkManager.validate_runtime_invariants()
	if not invariant_errors.is_empty():
		_fail_now("Final runtime invariant failed: %s" % "; ".join(invariant_errors))
		return
	var healed_save_verified := scenario != "invalid"
	if scenario == "invalid":
		if not SaveManager.save_game():
			_fail_now("Could not persist healed fallback safe position")
			return
		healed_save_verified = _saved_safe_position_matches_runtime(expected_records, "B")
		if not healed_save_verified:
			_fail_now("Re-saved fallback did not persist the healed last_safe_position")
			return
	var actual_records: Dictionary = {}
	for player_id in GameSession.persistent_player_ids():
		actual_records[String(player_id)] = _state_summary(player_id)
	var manager := _world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var assignments: Dictionary = {}
	for peer_id in NetworkManager.players:
		var assignment := NetworkManager.spawn_assignment_for_peer(peer_id)
		if assignment != null:
			assignments[String(NetworkManager.player_id_for_peer(peer_id))] = _assignment_summary(assignment)
	_write_result({
		"status": "host_final",
		"role": "host",
		"phase": "resume",
		"scenario": scenario,
		"player_id": String(NetworkManager.local_profile_player_id()),
		"session_id": GameSession.session_id,
		"restored_play_time_seconds": _restored_play_time_seconds,
		"restored_host_private": _restored_host_state,
		"canonical_count": GameSession.persistent_player_count(),
		"active_count": GameSession.players.size(),
		"player_ids": _string_player_ids(GameSession.persistent_player_ids()),
		"players": actual_records,
		"shared": _shared_summary(),
		"profile": _profile_summary(),
		"assignments": assignments,
		"reattach_counts": _string_key_dictionary(_reattach_counts),
		"registry_valid": true,
		"world_ready_count": NetworkManager.world_ready_peers.size(),
		"actor_count": manager._actors.size(),
		"save_sha256": FileAccess.get_sha256(SaveManager.SAVE_PATH),
		"healed_save_verified": healed_save_verified,
	})
	_host_finishing.rpc()
	print("RESTART PROBE HOST FINAL PASS")
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(0)

func _poll_resume_client() -> void:
	if not _client_sync_pending or _world == null:
		return
	var local_id := GameSession.get_local_player_id()
	var expected_record: Dictionary = _expected.get("players", {}).get(String(local_id), {})
	if expected_record.is_empty():
		_last_wait_reason = "selected player is absent from expected phase-one state"
		_schedule_client_poll()
		return
	_last_wait_reason = _client_state_wait_reason(expected_record)
	if not _last_wait_reason.is_empty():
		if Time.get_ticks_msec() - _last_diag_msec > 1000:
			_last_diag_msec = Time.get_ticks_msec()
			_write_result({
				"status": "client_sync_waiting",
				"role": label,
				"phase": "resume",
				"player_id": String(local_id),
				"reason": _last_wait_reason,
			})
			print("RESTART PROBE CLIENT %s WAITING: %s" % [label, _last_wait_reason])
		_schedule_client_poll()
		return
	_client_sync_pending = false
	if _client_sync_round == 1:
		_client_first_peer_id = NetworkManager.local_peer_id()
		_client_process_restart_assignment = _assignment_summary(_client_assignment)
		_client_process_restart_actor_position = _client_initial_actor_position
		_client_healed_safe_position = GameSession.get_local_player().last_safe_position
		_world = null
		call_deferred("_restart_client_connection")
		return
	var privacy_errors := _privacy_errors(local_id)
	var invariant_errors := NetworkManager.validate_runtime_invariants()
	if not privacy_errors.is_empty() or not invariant_errors.is_empty():
		_fail("Client privacy/runtime invariant failed: %s %s" % [
			"; ".join(privacy_errors), "; ".join(invariant_errors),
		])
		return
	var manager := _world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var actor := manager.get_actor(NetworkManager.local_peer_id())
	if actor == null or not _client_initial_actor_position.is_equal_approx(_client_assignment.position):
		_fail("Local actor was not initially placed at its authoritative assignment")
		return
	_final_client_result = {
		"status": "client_ready",
		"role": label,
		"phase": "resume",
		"scenario": scenario,
		"player_id": String(local_id),
		"session_id": GameSession.session_id,
		"first_peer_id": _client_first_peer_id,
		"peer_id": NetworkManager.local_peer_id(),
		"peer_changed": _client_first_peer_id != NetworkManager.local_peer_id(),
		"private": _state_summary(local_id),
		"process_restart_assignment": _client_process_restart_assignment,
		"process_restart_actor_position": [
			_client_process_restart_actor_position.x, _client_process_restart_actor_position.y,
		],
		"assignment": _assignment_summary(_client_assignment),
		"actor_initial_position": [_client_initial_actor_position.x, _client_initial_actor_position.y],
		"actor_position": [actor.position.x, actor.position.y],
		"private_sync_complete": NetworkManager._received_private_player_state,
		"spawn_sync_complete": NetworkManager._received_spawn_assignment,
		"session_ready": NetworkManager._session_entered,
		"world_ready": true,
		"privacy_valid": true,
		"registry_valid": true,
		"profile": _profile_summary(),
	}
	_write_result(_final_client_result)
	_resume_client_confirm.rpc_id(1, label)
	print("RESTART PROBE CLIENT %s READY" % label)

func _restart_client_connection() -> void:
	print("RESTART PROBE CLIENT %s LEAVING FOR SAME-SESSION RECONNECT" % label)
	NetworkManager.leave_game()
	get_tree().create_timer(0.25).timeout.connect(_perform_client_rejoin, CONNECT_ONE_SHOT)

func _perform_client_rejoin() -> void:
	print("RESTART PROBE CLIENT %s REJOINING" % label)
	if NetworkManager.join_game("127.0.0.1", port) != OK:
		_fail("Same-session reconnect failed: %s" % NetworkManager.last_error)

func _on_session_synchronized() -> void:
	if mode not in [MODE_SEED_CLIENT, MODE_RESUME_CLIENT]:
		return
	_client_sync_round += 1
	if mode == MODE_RESUME_CLIENT:
		call_deferred("_capture_resume_client_world")
		return
	_world = SETTLEMENT_SCENE.instantiate() as Node2D
	add_child(_world)
	_capture_client_spawn_state()
	_register_restart_label.rpc_id(1, label)

func _capture_resume_client_world() -> void:
	await get_tree().process_frame
	if _app == null or _app.world_layer.get_child_count() != 1:
		_fail("AppRoot did not enter Settlement after client synchronization")
		return
	_world = _app.world_layer.get_child(0) as Node2D
	_capture_client_spawn_state()
	_register_restart_label.rpc_id(1, label)
	_client_sync_pending = true
	print("RESTART PROBE CLIENT %s SETTLEMENT CAPTURED" % label)
	_poll_resume_client()

func _schedule_client_poll() -> void:
	if _client_sync_pending and not _finishing:
		get_tree().create_timer(0.05).timeout.connect(_poll_resume_client, CONNECT_ONE_SHOT)

func _capture_client_spawn_state() -> void:
	var manager := _world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	_client_assignment = manager.local_spawn_assignment()
	var actor := manager.get_actor(NetworkManager.local_peer_id())
	_client_initial_actor_position = actor.position if actor != null else Vector2.INF

func _on_peer_joined(peer_id: int) -> void:
	if mode != MODE_RESUME_HOST:
		return
	var player_id := NetworkManager.player_id_for_peer(peer_id)
	if _detached_instance_ids.has(player_id):
		var state := GameSession.get_player(peer_id)
		if state == null or state.get_instance_id() != _detached_instance_ids[player_id]:
			_fail("Host attached a replacement instead of the restored canonical state")
			return
		_reattach_counts[player_id] = _reattach_counts.get(player_id, 0) + 1

func _on_connection_failed() -> void:
	if mode == MODE_DUPLICATE_CLIENT:
		var rejected := NetworkManager.last_error == "Player identity is already connected"
		_write_result({
			"status": "duplicate_rejected" if rejected else "failed",
			"role": label,
			"phase": "resume",
			"player_id": String(NetworkManager.local_profile_player_id()),
			"error": NetworkManager.last_error,
			"registry_valid": NetworkManager.players.is_empty() and NetworkManager.peer_to_player.is_empty(),
		})
		_finishing = true
		get_tree().quit(0 if rejected else 1)
	elif not _finishing:
		_fail("Connection failed: %s" % NetworkManager.last_error)

func _on_server_disconnected() -> void:
	if not _expect_host_disconnect:
		if not _finishing:
			_fail("Host disconnected before the final lifecycle boundary")
		return
	var local_id := NetworkManager.local_profile_player_id()
	var clean := NetworkManager.state == NetworkManager.ConnectionState.OFFLINE \
			and NetworkManager.players.is_empty() and NetworkManager.peer_to_player.is_empty() \
			and NetworkManager.player_to_peer.is_empty() and NetworkManager._spawn_assignments.is_empty() \
			and not NetworkManager._received_session_snapshot \
			and not NetworkManager._received_private_player_state \
			and not NetworkManager._received_spawn_assignment \
			and GameSession.persistent_player_ids() == [local_id]
	_final_client_result["status"] = "client_host_disconnect_clean" if clean else "failed"
	_final_client_result["host_disconnect_clean"] = clean
	_final_client_result["post_disconnect_player_ids"] = _string_player_ids(GameSession.persistent_player_ids())
	_write_result(_final_client_result)
	_finishing = true
	print("RESTART PROBE CLIENT %s HOST DISCONNECT %s" % [label, "PASS" if clean else "FAIL"])
	get_tree().quit(0 if clean else 1)

@rpc("any_peer", "call_remote", "reliable")
func _register_restart_label(client_label: String) -> void:
	if not NetworkManager.is_server() or client_label not in ["B", "C", "D"]:
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1 and NetworkManager.has_peer(sender):
		_labels_by_peer[sender] = client_label

@rpc("authority", "call_remote", "reliable")
func _seed_saved() -> void:
	if mode != MODE_SEED_CLIENT:
		return
	_write_result({
		"status": "seed_complete",
		"role": label,
		"phase": "seed",
		"player_id": String(NetworkManager.local_profile_player_id()),
		"peer_id": NetworkManager.local_peer_id(),
		"session_id": GameSession.session_id,
		"profile": _profile_summary(),
	})
	print("RESTART PROBE CLIENT %s SEED COMPLETE" % label)
	_finish_success()

@rpc("any_peer", "call_remote", "reliable")
func _resume_client_confirm(client_label: String) -> void:
	if mode != MODE_RESUME_HOST or client_label not in ["B", "C", "D"]:
		return
	var sender := multiplayer.get_remote_sender_id()
	var player_id := NetworkManager.player_id_for_peer(sender)
	if sender > 1 and not player_id.is_empty() and _reattach_counts.get(player_id, 0) >= 2:
		_confirmed_players[player_id] = true

@rpc("authority", "call_remote", "reliable")
func _host_finishing() -> void:
	if mode == MODE_RESUME_CLIENT:
		_expect_host_disconnect = true

func _client_state_wait_reason(expected_record: Dictionary) -> String:
	var state := GameSession.get_local_player()
	if state == null or _client_assignment == null:
		return "local state or spawn assignment is unavailable"
	var invalid_scenario := scenario == "invalid" and label == "B"
	var mismatch := _state_mismatch(expected_record, state, invalid_scenario)
	if not mismatch.is_empty():
		return mismatch
	var quest := GameSession.progression.get_quest_state(
		PERSONAL_QUEST_ID, GameSession.get_local_player_id(), ContentRegistry
	)
	var shared_quest := GameSession.progression.get_quest_state(
		SHARED_QUEST_ID, GameSession.get_local_player_id(), ContentRegistry
	)
	if quest == null or not quest.completed or shared_quest == null or not shared_quest.completed:
		return "personal/shared quest snapshot is not complete"
	if GameSession.settlement.storage.count(&"moss_fiber") != 7:
		return "Settlement shared storage snapshot is not complete"
	if invalid_scenario:
		if _client_sync_round == 1:
			return "" if _client_assignment.spawn_kind == PlayerSpawnAssignment.SpawnKind.SETTLEMENT_FALLBACK \
					and _client_assignment.fallback_used \
					and state.last_safe_position == _client_assignment.position else "fallback spawn assignment is incomplete"
		return "" if _client_assignment.spawn_kind == PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION \
				and state.last_safe_position == _client_healed_safe_position \
				and _client_assignment.position == _client_healed_safe_position \
				else "healed returning spawn assignment is incomplete"
	return "" if _client_assignment.spawn_kind == PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION \
			and state.last_safe_position == _position_from_array(expected_record.get("last_safe_position", [])) \
			else "returning safe-position assignment is incomplete"

func _state_matches(expected_record: Dictionary, state: PlayerState, allow_healed_safe: bool) -> bool:
	return _state_mismatch(expected_record, state, allow_healed_safe).is_empty()

func _state_mismatch(expected_record: Dictionary, state: PlayerState, allow_healed_safe: bool) -> String:
	if state == null:
		return "missing state"
	if not is_equal_approx(state.health, float(expected_record.get("health", -1.0))):
		return "health expected=%s actual=%s" % [expected_record.get("health"), state.health]
	if not _numeric_dictionary_matches(expected_record.get("stats", {}), state.stats.to_dict()):
		return "stats expected=%s actual=%s" % [expected_record.get("stats"), state.stats.to_dict()]
	if not _numeric_dictionary_matches(expected_record.get("survival", {}), state.survival.to_dict()):
		return "survival expected=%s actual=%s" % [expected_record.get("survival"), state.survival.to_dict()]
	if not _variant_matches(expected_record.get("effects", []), _effect_summary(state)):
		return "effects expected=%s actual=%s" % [expected_record.get("effects"), _effect_summary(state)]
	if not _variant_matches(expected_record.get("inventory", []), state.inventory.to_array()):
		return "inventory expected=%s actual=%s" % [expected_record.get("inventory"), state.inventory.to_array()]
	if not _variant_matches(expected_record.get("protected_inventory", []), state.protected_inventory.to_array()):
		return "protected expected=%s actual=%s" % [expected_record.get("protected_inventory"), state.protected_inventory.to_array()]
	if not _variant_matches(expected_record.get("equipment", {}), state.equipment.to_dict()):
		return "equipment expected=%s actual=%s" % [expected_record.get("equipment"), state.equipment.to_dict()]
	if not allow_healed_safe and state.last_safe_position != _position_from_array(expected_record.get("last_safe_position", [])):
		return "last_safe expected=%s actual=%s" % [expected_record.get("last_safe_position"), state.last_safe_position]
	return ""

func _privacy_errors(local_id: StringName) -> PackedStringArray:
	var errors := PackedStringArray()
	for raw_player_id in _expected.get("players", {}):
		var player_id := StringName(raw_player_id)
		if player_id == local_id:
			continue
		var remote := GameSession.get_player_state_by_player_id(player_id)
		if remote == null:
			continue
		if not remote.inventory.stacks().is_empty() or not remote.protected_inventory.stacks().is_empty() \
				or not remote.equipment.all_equipped().is_empty() \
				or remote.effects.active_effects.has(&"quick_paws"):
			errors.append("remote private mirror leaked for %s" % _fingerprint(player_id))
		var private_quest := GameSession.progression.get_quest_state(PERSONAL_QUEST_ID, player_id, ContentRegistry)
		if private_quest != null:
			errors.append("remote personal quest leaked for %s" % _fingerprint(player_id))
	return errors

func _state_summary(player_id: StringName) -> Dictionary:
	var state := GameSession.get_player_state_by_player_id(player_id)
	if state == null:
		return {}
	var quest := GameSession.progression.get_quest_state(PERSONAL_QUEST_ID, player_id, ContentRegistry)
	return {
		"health": state.health,
		"stats": state.stats.to_dict(),
		"survival": state.survival.to_dict(),
		"effects": _effect_summary(state),
		"inventory": state.inventory.to_array(),
		"protected_inventory": state.protected_inventory.to_array(),
		"equipment": state.equipment.to_dict(),
		"personal_quest": quest.to_dict() if quest != null else {},
		"last_safe_position": [state.last_safe_position.x, state.last_safe_position.y],
	}

func _effect_summary(state: PlayerState) -> Array[Dictionary]:
	var effects: Array[Dictionary] = []
	for raw in state.effects.to_array():
		effects.append({
			"effect_id": raw.get("effect_id", ""),
			"stacks": raw.get("stacks", 0),
		})
	effects.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.effect_id < b.effect_id)
	return effects

func _shared_summary() -> Dictionary:
	var quest := GameSession.progression.get_quest_state(
		SHARED_QUEST_ID, GameSession.get_local_player_id(), ContentRegistry
	)
	return {
		"moss_fiber": GameSession.settlement.storage.count(&"moss_fiber"),
		"shared_quest": quest.to_dict() if quest != null else {},
	}

func _assignment_summary(assignment: PlayerSpawnAssignment) -> Dictionary:
	return {
		"player_id": String(assignment.player_id),
		"spawn_kind": PlayerSpawnAssignment.SpawnKind.keys()[assignment.spawn_kind],
		"position": [assignment.position.x, assignment.position.y],
		"fallback_used": assignment.fallback_used,
		"reason": assignment.reason,
	}

func _profile_summary() -> Dictionary:
	return {
		"valid": NetworkManager.has_valid_local_profile(),
		"load_status": NetworkManager.local_profile_load_status(),
		"primary_exists": FileAccess.file_exists(LocalPlayerProfile.DEFAULT_PATH),
		"backup_exists": FileAccess.file_exists(LocalPlayerProfile.DEFAULT_PATH + ".bak"),
		"user_path": ProjectSettings.globalize_path("user://"),
	}

func _saved_safe_position_matches_runtime(
	expected_records: Dictionary,
	target_label: String
) -> bool:
	var target_id := ""
	for raw_player_id in expected_records:
		if expected_records[raw_player_id].get("label", "") == target_label:
			target_id = String(raw_player_id)
			break
	if target_id.is_empty():
		return false
	var save_root := _read_json(ProjectSettings.globalize_path(SaveManager.SAVE_PATH))
	var players: Dictionary = save_root.get("players", {})
	var record: Dictionary = players.get(target_id, {})
	var saved_state: Dictionary = record.get("player_state", {})
	var saved_position := _position_from_array(saved_state.get("last_safe_position", null))
	var live_state := GameSession.get_player_state_by_player_id(StringName(target_id))
	return live_state != null and saved_position.is_equal_approx(live_state.last_safe_position)

func _install_probe_quests() -> void:
	var personal_objective := QuestObjectiveDefinition.new()
	personal_objective.type = QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY
	personal_objective.target_id = &"sewer_beetle"
	personal_objective.required_amount = 1
	var personal := QuestDefinition.new()
	personal.id = PERSONAL_QUEST_ID
	personal.title = "Restart Personal Probe"
	personal.scope = QuestDefinition.Scope.PERSONAL
	personal.objectives = [personal_objective]
	ContentRegistry._definitions[personal.id] = personal
	var shared_objective := personal_objective.duplicate() as QuestObjectiveDefinition
	var shared := QuestDefinition.new()
	shared.id = SHARED_QUEST_ID
	shared.title = "Restart Shared Probe"
	shared.scope = QuestDefinition.Scope.PARTY
	shared.objectives = [shared_objective]
	ContentRegistry._definitions[shared.id] = shared

func _numeric_dictionary_matches(expected_values: Dictionary, actual_values: Dictionary) -> bool:
	if expected_values.size() != actual_values.size():
		return false
	for key in expected_values:
		if not actual_values.has(key) \
				or absf(float(expected_values[key]) - float(actual_values[key])) >= 0.05:
			return false
	return true

func _variant_matches(expected_value: Variant, actual_value: Variant) -> bool:
	if (expected_value is int or expected_value is float) \
			and (actual_value is int or actual_value is float):
		return is_equal_approx(float(expected_value), float(actual_value))
	if expected_value is Dictionary and actual_value is Dictionary:
		if expected_value.size() != actual_value.size():
			return false
		for key in expected_value:
			if not actual_value.has(key) or not _variant_matches(expected_value[key], actual_value[key]):
				return false
		return true
	if expected_value is Array and actual_value is Array:
		if expected_value.size() != actual_value.size():
			return false
		for index in expected_value.size():
			if not _variant_matches(expected_value[index], actual_value[index]):
				return false
		return true
	return expected_value == actual_value

func _position_from_array(value: Variant) -> Vector2:
	return Vector2(float(value[0]), float(value[1])) if value is Array and value.size() == 2 else Vector2.INF

func _player_id_for_label(mapping: Dictionary[StringName, String], target: String) -> StringName:
	for player_id in mapping:
		if mapping[player_id] == target:
			return player_id
	return &""

func _string_player_ids(values: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result

func _string_key_dictionary(values: Dictionary) -> Dictionary:
	var result := {}
	for key in values:
		result[String(key)] = values[key]
	return result

func _fingerprint(player_id: StringName) -> String:
	return String(player_id).right(8)

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	file.close()
	return parser.data if parse_error == OK and parser.data is Dictionary else {}

func _write_result(value: Dictionary) -> void:
	if result_path.is_empty():
		return
	var payload := value.duplicate(true)
	payload["process_id"] = OS.get_process_id()
	var temporary := result_path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		push_error("Cannot write restart probe result: %s" % temporary)
		return
	file.store_string(JSON.stringify(payload, "  "))
	file.flush()
	file.close()
	if FileAccess.file_exists(result_path):
		DirAccess.remove_absolute(result_path)
	DirAccess.rename_absolute(temporary, result_path)

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--mode="):
			mode = argument.trim_prefix("--mode=")
		elif argument.begins_with("--label="):
			label = argument.trim_prefix("--label=")
		elif argument.begins_with("--scenario="):
			scenario = argument.trim_prefix("--scenario=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--players="):
			expected_players = int(argument.trim_prefix("--players="))
		elif argument.begins_with("--result="):
			result_path = argument.trim_prefix("--result=")
		elif argument.begins_with("--expected="):
			expected_path = argument.trim_prefix("--expected=")
		elif argument.begins_with("--release="):
			release_path = argument.trim_prefix("--release=")
		elif argument.begins_with("--timeout="):
			timeout_seconds = float(argument.trim_prefix("--timeout="))

func _finish_success() -> void:
	_finishing = true
	get_tree().quit(0)

func _fail(message: String) -> void:
	if _finishing:
		return
	_finishing = true
	_fail_now(message)

func _fail_now(message: String) -> void:
	push_error("RESTART PROBE FAIL: %s" % message)
	_write_result({
		"status": "failed",
		"role": label if not label.is_empty() else "host",
		"phase": mode,
		"player_id": String(NetworkManager.local_profile_player_id()),
		"session_id": GameSession.session_id,
		"network_state": NetworkManager.ConnectionState.keys()[NetworkManager.state],
		"error": message,
	})
	get_tree().quit(1)
