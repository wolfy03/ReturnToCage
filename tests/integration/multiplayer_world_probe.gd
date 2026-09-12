extends Node

const SETTLEMENT: StringName = &"settlement"
const SEWER: StringName = &"adventure:sewer_region"

var role := ""
var index := 0
var port := NetworkManager.DEFAULT_PORT
var expected_players := 2
var world_layer: Node
var deadline_msec := 0
var _started := false
var _command_name := ""
var _command_reported := false
var _confirmations: Dictionary[String, Dictionary] = {}
var _b_peer := 0
var _c_peer := 0
var _finishing := false

func _ready() -> void:
	_parse_arguments()
	deadline_msec = Time.get_ticks_msec() + 20000
	world_layer = Node.new()
	world_layer.name = "WorldLayer"
	add_child(world_layer)
	SceneRouter.register_world_layer(world_layer)
	NetworkManager.local_world_assignment_received.connect(_on_world_assignment)
	NetworkManager.connection_failed.connect(func() -> void: _fail(NetworkManager.last_error))
	if role == "host":
		if NetworkManager.host_game(port, expected_players) != OK or not GameSession.start_new_game():
			_fail("host setup failed")
			return
		if not SceneRouter.go_to_settlement():
			_fail("host Settlement load failed")
			return
		print("WORLD PROBE HOST LISTENING")
	else:
		if NetworkManager.join_game("127.0.0.1", port) != OK:
			_fail("client setup failed")

func _process(_delta: float) -> void:
	if _finishing:
		return
	if Time.get_ticks_msec() > deadline_msec:
		_fail("timeout role=%s command=%s world=%s" % [role, _command_name, SceneRouter.current_world_id()])
		return
	if role == "host":
		_process_host()
	else:
		_process_client()

func _process_host() -> void:
	if not _started:
		if NetworkManager.players.size() != expected_players:
			return
		for peer_id in NetworkManager.players:
			if not NetworkManager.is_peer_world_ready(peer_id):
				return
		var remotes: Array[int] = []
		for peer_id in NetworkManager.players:
			if peer_id != 1:
				remotes.append(peer_id)
		remotes.sort()
		_b_peer = remotes[0]
		_c_peer = remotes[1] if remotes.size() > 1 else 0
		_started = true
		_command.rpc_id(_b_peer, "ENTER1")
		return
	if _confirmed("ENTER1", _b_peer) and not _confirmations.has("SPLIT_ADVANCED"):
		if not _assert_host_worlds([_b_peer], [_c_peer] if _c_peer > 0 else []):
			return
		_confirmations["SPLIT_ADVANCED"] = {}
		if _c_peer > 0:
			_command.rpc_id(_c_peer, "CHECK_STAY")
		else:
			_command.rpc_id(_b_peer, "RETURN")
	if _c_peer > 0 and _confirmed("CHECK_STAY", _c_peer) and not _confirmations.has("RETURN_SENT"):
		_confirmations["RETURN_SENT"] = {}
		_command.rpc_id(_b_peer, "RETURN")
	if _confirmed("RETURN", _b_peer) and not _confirmations.has("RETURN_ADVANCED"):
		if not _assert_host_worlds([], [_b_peer, _c_peer] if _c_peer > 0 else [_b_peer]):
			return
		_confirmations["RETURN_ADVANCED"] = {}
		if _c_peer > 0:
			_command.rpc_id(_c_peer, "CHECK_ALL")
		else:
			var host_transition := NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region")
			if not host_transition.success:
				_fail(host_transition.message)
				return
			_confirmations["HOST_ENTER_SENT"] = {}
	if _c_peer == 0 and _confirmations.has("HOST_ENTER_SENT") \
			and not _confirmations.has("HOST_AWAY_CHECK_SENT") \
			and NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == SEWER:
		var roster := _actor_roster()
		if roster != [1]:
			_fail("host Sewer roster was not isolated: %s" % [roster])
			return
		_confirmations["HOST_AWAY_CHECK_SENT"] = {}
		_command.rpc_id(_b_peer, "CHECK_HOST_AWAY")
	if _c_peer == 0 and _confirmed("CHECK_HOST_AWAY", _b_peer) \
			and not _confirmations.has("HOST_RETURN_SENT"):
		var host_return := NetworkManager.request_return_to_settlement()
		if not host_return.success:
			_fail(host_return.message)
			return
		_confirmations["HOST_RETURN_SENT"] = {}
	if _c_peer == 0 and _confirmations.has("HOST_RETURN_SENT") \
			and NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == SETTLEMENT:
		if _actor_roster().size() == 2:
			_finish_success()
	if _c_peer > 0 and _confirmed("CHECK_ALL", _c_peer) and not _confirmations.has("ENTER2_B_SENT"):
		_confirmations["ENTER2_B_SENT"] = {}
		_command.rpc_id(_b_peer, "ENTER2")
	if _confirmed("ENTER2", _b_peer) and not _confirmations.has("ENTER2_C_SENT"):
		_confirmations["ENTER2_C_SENT"] = {}
		_command.rpc_id(_c_peer, "ENTER2")
	if _c_peer > 0 and _confirmed("ENTER2", _c_peer) and not _confirmations.has("CHECK_SEWER_SENT"):
		_confirmations["CHECK_SEWER_SENT"] = {}
		_command.rpc_id(_b_peer, "CHECK_SEWER")
	if _c_peer > 0 and _confirmed("CHECK_SEWER", _b_peer):
		if _assert_host_worlds([_b_peer, _c_peer], []):
			_finish_success()

func _process_client() -> void:
	if _command_name.is_empty() or _command_reported or not NetworkManager.is_local_world_ready():
		return
	var expected_world := SEWER if _command_name in ["ENTER1", "ENTER2", "CHECK_SEWER"] else SETTLEMENT
	if GameSession.get_peer_world_id(NetworkManager.local_peer_id()) != expected_world \
			or SceneRouter.current_world_id() != expected_world:
		return
	var roster := _actor_roster()
	var local_peer := NetworkManager.local_peer_id()
	if not roster.has(local_peer):
		_fail("local actor missing after %s" % _command_name)
		return
	if _command_name == "ENTER1" and roster.size() != 1:
		_fail("first Sewer roster was not isolated: %s" % [roster])
		return
	if _command_name == "CHECK_HOST_AWAY" and roster != [local_peer]:
		_fail("client scene changed or retained host actor during host transition: %s" % [roster])
		return
	_command_reported = true
	_confirm.rpc_id(1, _command_name, String(expected_world), roster)

func _on_world_assignment(assignment: PlayerWorldAssignment) -> void:
	if not SceneRouter.apply_world_assignment(assignment):
		_fail("cannot apply world assignment: %s" % assignment.world_id)

@rpc("authority", "call_remote", "reliable")
func _command(name: String) -> void:
	print("WORLD PROBE COMMAND %s initial_roster=%s local=%d" % [name, _actor_roster(), NetworkManager.local_peer_id()])
	_command_name = name
	_command_reported = false
	if name in ["ENTER1", "ENTER2"]:
		var result := NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region")
		if not result.success:
			_fail(result.message)
	elif name == "RETURN":
		var result := NetworkManager.request_return_to_settlement()
		if not result.success:
			_fail(result.message)

@rpc("any_peer", "call_remote", "reliable")
func _confirm(name: String, world_id: String, roster: Array) -> void:
	if role != "host":
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not NetworkManager.has_peer(sender) \
			or GameSession.get_peer_world_id(sender) != StringName(world_id):
		_fail("invalid confirmation %s from %d" % [name, sender])
		return
	_confirmations["%s:%d" % [name, sender]] = {"roster": roster}

func _confirmed(name: String, peer_id: int) -> bool:
	return _confirmations.has("%s:%d" % [name, peer_id])

func _assert_host_worlds(sewer_peers: Array, extra_settlement_peers: Array) -> bool:
	if GameSession.get_peer_world_id(1) != SETTLEMENT or SceneRouter.current_world_id() != SETTLEMENT:
		_fail("host left Settlement")
		return false
	for peer_id in sewer_peers:
		if GameSession.get_peer_world_id(peer_id) != SEWER:
			_fail("peer %d did not enter Sewer" % peer_id)
			return false
	for peer_id in extra_settlement_peers:
		if peer_id > 0 and GameSession.get_peer_world_id(peer_id) != SETTLEMENT:
			_fail("peer %d did not remain in Settlement" % peer_id)
			return false
	var roster := _actor_roster()
	if roster.has(_b_peer) and sewer_peers.has(_b_peer) \
			or _c_peer > 0 and roster.has(_c_peer) and sewer_peers.has(_c_peer):
		_fail("Settlement retained an actor from another world: %s" % [roster])
		return false
	return NetworkManager.validate_runtime_invariants().is_empty()

func _actor_roster() -> Array[int]:
	if world_layer.get_child_count() == 0:
		return []
	var manager := world_layer.get_child(0).get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	var result: Array[int] = []
	if manager != null:
		result.assign(manager._actors.keys())
		result.sort()
	return result

func _finish_success() -> void:
	if _finishing:
		return
	if not NetworkManager.validate_runtime_invariants().is_empty():
		_fail("runtime mapping invariant failed")
		return
	_finishing = true
	for peer_id in NetworkManager.players:
		if peer_id != 1 and NetworkManager.can_send_to_peer(peer_id):
			_finish_remote.rpc_id(peer_id)
	print("WORLD PARTICIPATION PROBE PASS players=%d" % expected_players)
	# Give the reliable completion RPC a network poll before the host closes.
	await get_tree().create_timer(0.15).timeout
	get_tree().quit(0)

@rpc("authority", "call_remote", "reliable")
func _finish_remote() -> void:
	if _finishing:
		return
	_finishing = true
	print("WORLD PARTICIPATION PROBE PASS client=%d" % index)
	# Let the host own transport teardown after receiving all logical assertions.
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(0)

func _fail(message: String) -> void:
	push_error("WORLD PARTICIPATION PROBE FAIL: %s" % message)
	get_tree().quit(1)

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--index="):
			index = int(argument.trim_prefix("--index="))
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--players="):
			expected_players = int(argument.trim_prefix("--players="))
