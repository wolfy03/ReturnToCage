extends RefCounted

const PLAYER_ONE := "player_11111111111111111111111111111111"
const PLAYER_TWO := "player_22222222222222222222222222222222"
const PLAYER_TEST: StringName = &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func run(t: Node) -> void:
	t.assert_equal(NetworkProtocol.VERSION, 11, "individual-world assignment handshake contract uses protocol v11")
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
		"players": [
			{"peer_id": 1, "player_id": PLAYER_ONE},
			{"peer_id": 42, "player_id": PLAYER_TWO},
		],
	}
	var snapshot := NetworkSessionSnapshot.from_payload(payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS)
	t.assert_true(snapshot.error_message.is_empty() and snapshot.player_ids == [1, 42], "network session schema validates stable player identities")
	t.assert_equal(snapshot.identities[1].player_id, StringName(PLAYER_TWO), "session identity roundtrip preserves logical player id")
	var duplicate := payload.duplicate(true)
	duplicate["players"][1]["player_id"] = PLAYER_ONE
	t.assert_true(not NetworkSessionSnapshot.from_payload(duplicate, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS).error_message.is_empty(), "duplicate logical player identity is rejected")
	var local_payload := payload.duplicate(true)
	local_payload["players"][0]["player_id"] = String(NetworkManager.local_profile_player_id())
	var local_snapshot := NetworkSessionSnapshot.from_payload(local_payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS)
	t.assert_true(NetworkManager._snapshot_matches_local_profile(local_snapshot), "session snapshot accepts the local persistent profile identity")
	t.assert_true(not NetworkManager._snapshot_matches_local_profile(snapshot), "session snapshot rejects a substituted local player identity")
	NetworkManager.peer_to_player.clear()
	NetworkManager.player_to_peer.clear()
	t.assert_true(NetworkManager._set_identity(77, PLAYER_TEST), "logical identity mapping accepts a unique pair")
	t.assert_equal(NetworkManager.player_id_for_peer(77), PLAYER_TEST, "peer to logical player lookup is reversible")
	t.assert_equal(NetworkManager.peer_id_for_player(PLAYER_TEST), 77, "logical player to peer lookup is reversible")
	t.assert_true(not NetworkManager._set_identity(78, PLAYER_TEST), "duplicate logical identity mapping is rejected")
	NetworkManager.players[77] = NetworkPlayerInfo.new(77, PLAYER_TEST, "Existing", true)
	t.assert_equal(NetworkManager._handshake_identity_error(78, PLAYER_TEST), "Player identity is already connected", "second active peer handshake with the same profile is rejected")
	t.assert_equal(NetworkManager.player_id_for_peer(77), PLAYER_TEST, "duplicate handshake leaves the existing identity mapping untouched")
	for invalid_id in ["", "abc", "player_", "player_ABCDEF0123456789abcdef0123456789", "player_123456789012345678901234567890123", "player_1234567890123456789012345678901g"]:
		t.assert_true(not LocalPlayerProfile.is_valid_player_id(invalid_id), "malformed persistent player identity is rejected: %s" % invalid_id)
	NetworkManager.players.erase(77)
	NetworkManager._remove_identity(77)
	payload["protocol_version"] = 10
	t.assert_equal(NetworkSessionSnapshot.from_payload(payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS).error_message, "Incompatible multiplayer protocol version", "v10 session snapshot is rejected by protocol v11")
	payload["protocol_version"] = NetworkProtocol.VERSION + 1
	t.assert_equal(NetworkSessionSnapshot.from_payload(payload, NetworkProtocol.VERSION, NetworkManager.MAX_PLAYERS).error_message, "Incompatible multiplayer protocol version", "protocol mismatch is rejected explicitly")
