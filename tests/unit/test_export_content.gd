extends RefCounted

func run(t: Node) -> void:
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID)
	ContentRegistry._definitions.erase(GameSession.DEFAULT_START_ID)
	t.assert_true(not ContentRegistry.validate_all().is_empty(), "registry validation rejects missing mandatory GameStartDefinition")
	ContentRegistry._definitions[GameSession.DEFAULT_START_ID] = start
	var definitions := ContentRegistry._definitions.duplicate()
	ContentRegistry._definitions.clear()
	t.assert_true(not ContentRegistry.validate_all().is_empty(), "empty exported registry must not validate successfully")
	ContentRegistry._definitions.assign(definitions)
	t.assert_true(ContentRegistry.validate_all().is_empty(), "mandatory content fixture restores cleanly")
	_test_snapshot_failure(t, "unknown_export_difficulty", "Unknown difficulty: unknown_export_difficulty")
	_test_snapshot_failure(t, "normal", "Missing GameStartDefinition: default_game_start", true)
	if ContentRegistry.has_method("_register_resource"):
		var registry := (load("res://autoload/content_registry.gd") as GDScript).new() as Node
		registry.call("_register_resource", "res://invalid-type.tres", Resource.new())
		var empty := ContentDefinition.new()
		registry.call("_register_resource", "res://empty-id.tres", empty)
		var duplicate := ContentDefinition.new()
		duplicate.id = &"duplicate_probe"
		registry.call("_register_resource", "res://first.tres", duplicate)
		registry.call("_register_resource", "res://second.tres", duplicate)
		registry.call("_register_resource", "res://unreadable.tres", null)
		t.assert_equal(registry._load_errors.size(), 4, "invalid type, empty ID, duplicate ID, and unreadable resource are rejected")
		t.assert_true(String(registry._load_errors[2]).contains("first.tres") and String(registry._load_errors[2]).contains("second.tres"), "duplicate diagnostics identify both resource paths")
		registry.free()

func _test_snapshot_failure(t: Node, difficulty: String, expected: String, remove_start: bool = false) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var old_session := GameSession.session_id
	var old_player := GameSession.get_player(1)
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._local_peer_id = 42
	NetworkManager._set_identity(1, &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	NetworkManager._set_identity(42, NetworkManager.local_profile_player_id())
	var payload := {
		"protocol_version": NetworkProtocol.VERSION, "session_id": "export-probe", "phase": GameSession.Phase.SETTLEMENT,
		"difficulty_id": difficulty, "players": [
			{"peer_id": 1, "player_id": "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
			{"peer_id": 42, "player_id": String(NetworkManager.local_profile_player_id())},
		]}
	var snapshot := NetworkSessionSnapshot.from_payload(payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS)
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID)
	if remove_start:
		ContentRegistry._definitions.erase(GameSession.DEFAULT_START_ID)
	t.assert_true(not GameSession.apply_network_snapshot(snapshot), "invalid export snapshot is rejected")
	t.assert_true(GameSession.get_player(1) == old_player and GameSession.session_id == old_session, "snapshot preflight failure preserves existing canonical model")
	t.assert_true(GameSession.get("last_network_snapshot_error") == expected, "snapshot reports actionable content failure")
	NetworkManager._receive_session_snapshot(payload)
	t.assert_equal(NetworkManager.last_error, "Session snapshot rejected: %s" % expected, "network failure retains the precise content reason for the UI")
	t.assert_true(NetworkManager.state == NetworkManager.ConnectionState.OFFLINE and not NetworkManager._received_session_snapshot, "rejected content cannot continue a multiplayer session")
	ContentRegistry._definitions[GameSession.DEFAULT_START_ID] = start
	NetworkManager.leave_game()
	GameSession.start_new_game()
