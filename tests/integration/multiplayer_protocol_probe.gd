extends Node

var role := "host"
var port := 7777
var rejected := false
var _finished := false

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
	if role == "host":
		if NetworkManager.host_game(port, 2) != OK or not GameSession.start_new_game():
			_fail("host setup failed")
			return
		print("WORLD RUNTIME HOST LISTENING")
		var until := Time.get_ticks_msec() + 10000
		while Time.get_ticks_msec() < until:
			if not NetworkManager._rejected_handshake_peers.is_empty():
				rejected = true
			if rejected and multiplayer.get_peers().is_empty():
				if NetworkManager.players.size() != 1 or GameSession.players.size() != 1:
					_fail("mismatched peer acquired a canonical attachment")
					return
				_pass()
				return
			await get_tree().process_frame
		_fail("protocol mismatch was not rejected")
	else:
		# Use the production transport and RPC node, replacing only this probe's
		# outbound handshake version. No test hook is added to gameplay code.
		multiplayer.connected_to_server.disconnect(NetworkManager._on_connected_to_server)
		multiplayer.connected_to_server.connect(func() -> void:
			NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
			NetworkManager._local_peer_id = multiplayer.get_unique_id()
			NetworkManager._request_handshake.rpc_id(1, 18, NetworkManager.local_profile_player_id(), "v18 client")
		)
		NetworkManager.connection_failed.connect(func() -> void:
			if NetworkManager.last_error != "Incompatible multiplayer protocol version":
				_fail("unexpected rejection: %s" % NetworkManager.last_error)
			else:
				_pass()
		)
		if NetworkManager.join_game("127.0.0.1", port) != OK:
			_fail("client setup failed")

func _pass() -> void:
	if _finished:
		return
	_finished = true
	print("WORLD RUNTIME PROBE PASS protocol-mismatch %s" % role)
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(0)

func _fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
