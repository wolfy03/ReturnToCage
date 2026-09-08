extends RefCounted

func run(t: Node) -> void:
	var valid := PlayerMoveCommand.new(1, 1.0, -1.0, true)
	t.assert_true(valid.is_valid_after(0), "bounded movement command is accepted")
	t.assert_true(not valid.is_valid_after(1), "duplicate movement sequence is rejected")
	t.assert_true(not PlayerMoveCommand.new(2, -1.01, 0.0).is_valid_after(1), "horizontal underflow is rejected")
	t.assert_true(not PlayerMoveCommand.new(2, 1.01, 0.0).is_valid_after(1), "horizontal overflow is rejected")
	t.assert_true(not PlayerMoveCommand.new(2, 0.0, -1.01).is_valid_after(1), "vertical underflow is rejected")
	t.assert_true(not PlayerMoveCommand.new(2, 0.0, 1.01).is_valid_after(1), "vertical overflow is rejected")
	t.assert_true(not PlayerMoveCommand.new(2, NAN, 0.0).is_valid_after(1), "NaN movement is rejected")
	t.assert_true(not PlayerMoveCommand.new(2, INF, 0.0).is_valid_after(1), "infinite movement is rejected")
	t.assert_true(NetworkProtocol.valid_command_sender(42, 42, true), "known sender may control its actor")
	t.assert_true(not NetworkProtocol.valid_command_sender(42, 7, true), "sender cannot spoof another actor")
	t.assert_true(not NetworkProtocol.valid_command_sender(42, 42, false), "unknown sender input is rejected")
	t.assert_true(NetworkProtocol.valid_snapshot(Vector2.ONE, Vector2.ZERO, 1.0, MovementComponent.Mode.GROUND), "finite server snapshot is accepted")
	t.assert_true(not NetworkProtocol.valid_snapshot(Vector2(NAN, 0), Vector2.ZERO, 1.0, MovementComponent.Mode.GROUND), "malformed snapshot is rejected")
	var payload := {
		"protocol_version": NetworkProtocol.VERSION,
		"session_id": "test",
		"phase": GameSession.Phase.SETTLEMENT,
		"difficulty_id": "normal",
		"players": [1, 42],
	}
	var snapshot := NetworkSessionSnapshot.from_payload(payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS)
	t.assert_true(snapshot.error_message.is_empty() and snapshot.player_ids == [1, 42], "network session schema validates independently of save data")
	payload["protocol_version"] = NetworkProtocol.VERSION + 1
	t.assert_equal(NetworkSessionSnapshot.from_payload(payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS).error_message, "Incompatible multiplayer protocol version", "protocol mismatch is rejected explicitly")
