extends Node

enum ProbeState { WAITING, HORIZONTAL, JUMPING, PREPARE_CLIMB, CLIMBING, HEALTH, RESPAWN, CLEANUP, RECONNECT, FINISHED }

var role: String = ""
var port: int = NetworkManager.DEFAULT_PORT
var expected_players: int = 2
var disconnect_host: bool = false
var world: Node2D
var spawner: PlayerSpawnManager
var ladder: ClimbableArea2D
var state: ProbeState = ProbeState.WAITING
var selected_peer: int = 0
var start_position: Vector2
var deadline_msec: int
var phase_started_msec: int
var diagnostic_printed: bool = false
var client_start_position: Vector2
var client_saw_authoritative_snapshot: bool = false
var health_test_peer: int = 0
var health_confirmation_sent: bool = false
var health_confirmations: Dictionary[int, bool] = {}
var respawn_test_peer: int = 0
var client_old_actor_id: int = 0
var respawn_confirmation_sent: bool = false
var respawn_confirmations: Dictionary[int, bool] = {}
var server_old_actor_id: int = 0
var server_old_life_id: int = -1
var server_death_phase: int
var session_end_verified: bool = false
var reconnecting: bool = false
var reconnect_confirmations: Dictionary[int, bool] = {}

func _ready() -> void:
	_parse_arguments()
	deadline_msec = Time.get_ticks_msec() + 15000
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	NetworkManager.multiplayer_session_ended.connect(_on_multiplayer_session_ended)
	if role == "host":
		if NetworkManager.host_game(port, expected_players) != OK or not GameSession.start_new_game():
			_fail("host setup failed")
			return
		_build_world()
		print("PROBE HOST READY")
	elif role == "client":
		NetworkManager.session_synchronized.connect(_on_session_synchronized)
		NetworkManager.connection_failed.connect(func() -> void: _fail(NetworkManager.last_error))
		if NetworkManager.join_game("127.0.0.1", port) != OK:
			_fail("client setup failed")
	else:
		_fail("missing --role=host|client")

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > deadline_msec:
		_fail("probe timed out in state %s" % ProbeState.keys()[state])
		return
	if role == "client" and world != null:
		var local_actor := _actor(NetworkManager.local_peer_id())
		if local_actor != null and local_actor.global_position.distance_to(client_start_position) > 15.0:
			client_saw_authoritative_snapshot = true
		if health_test_peer > 0 and not health_confirmation_sent:
			var health_actor := _actor(health_test_peer)
			var health_state := GameSession.get_player(health_test_peer)
			if health_actor != null and health_state != null \
				and is_equal_approx(health_actor.health.current_health, 40.0) \
				and is_equal_approx(health_state.health, 40.0):
				health_confirmation_sent = true
				_confirm_health_presentation.rpc_id(1)
		if respawn_test_peer > 0 and not respawn_confirmation_sent:
			var respawn_actor := _actor(respawn_test_peer)
			if respawn_actor != null and respawn_actor.get_instance_id() != client_old_actor_id:
				respawn_confirmation_sent = true
				_confirm_respawn_presentation.rpc_id(1)
	if role != "host" or world == null:
		return
	var actors := get_tree().get_nodes_in_group(&"player")
	match state:
		ProbeState.WAITING:
			if GameSession.players.size() == expected_players and actors.size() == expected_players:
				print("PROBE HOST PLAYERS %d" % expected_players)
				if disconnect_host:
					print("PROBE HOST EXITING")
					get_tree().quit(0)
					return
				var ids: Array[int] = []
				ids.assign(GameSession.players.keys())
				ids.sort()
				selected_peer = ids[1]
				var actor := _actor(selected_peer)
				start_position = actor.global_position
				state = ProbeState.HORIZONTAL
		ProbeState.HORIZONTAL:
			var actor := _actor(selected_peer)
			if actor != null and actor.global_position.x > start_position.x + 20.0:
				print("PROBE HOST HORIZONTAL OK")
				start_position = actor.global_position
				_begin_jump_test.rpc_id(selected_peer)
				state = ProbeState.JUMPING
		ProbeState.JUMPING:
			var actor := _actor(selected_peer)
			if actor != null and actor.global_position.y < start_position.y - 10.0:
				print("PROBE HOST JUMP OK")
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.PREPARE_CLIMB
		ProbeState.PREPARE_CLIMB:
			if Time.get_ticks_msec() - phase_started_msec > 250:
				var actor := _actor(selected_peer)
				actor.global_position = ladder.bottom() + Vector2(15, 0)
				actor.velocity = Vector2.ZERO
				actor.movement.add_climb_area(ladder)
				start_position = actor.global_position
				_begin_climb_test.rpc_id(selected_peer)
				state = ProbeState.CLIMBING
		ProbeState.CLIMBING:
			var actor := _actor(selected_peer)
			if not diagnostic_printed and Time.get_ticks_msec() - phase_started_msec > 1500:
				diagnostic_printed = true
				print("PROBE CLIMB DIAGNOSTIC axis=%.2f mode=%s pos=%s ladder=%s overlaps=%s monitoring=%s masks=%d/%d areas=%d" % [actor.input.vertical_axis, MovementComponent.Mode.keys()[actor.movement.mode], actor.global_position, ladder.global_position, ladder.overlaps_body(actor), ladder.monitoring, actor.collision_layer, ladder.collision_mask, actor.movement.climb_areas.size()])
			if actor != null and actor.global_position.y < start_position.y - 20.0:
				print("PROBE HOST CLIMB OK")
				GameSession.get_player(selected_peer).set_health(40.0)
				_begin_health_test.rpc(selected_peer)
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.HEALTH
		ProbeState.HEALTH:
			if health_confirmations.size() == expected_players - 1:
				print("PROBE CLIENT HEALTH PRESENTATION OK")
				var actor := _actor(selected_peer)
				server_old_actor_id = actor.get_instance_id()
				server_old_life_id = GameSession.get_player_life_id(selected_peer)
				server_death_phase = GameSession.phase
				_begin_respawn_test.rpc(selected_peer)
				actor.health.receive_damage(DamageContext.new(10000.0, &"probe", self, &"test"))
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.RESPAWN
		ProbeState.RESPAWN:
			var actor := _actor(selected_peer)
			if actor != null and actor.get_instance_id() != server_old_actor_id \
				and GameSession.get_player_life_id(selected_peer) > server_old_life_id \
				and GameSession.phase == server_death_phase \
				and respawn_confirmations.size() == expected_players - 1:
				print("PROBE REMOTE PLAYER RESPAWN OK")
				_probe_done.rpc()
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.CLEANUP
		ProbeState.CLEANUP:
			if GameSession.players.size() == 1 and Time.get_ticks_msec() - phase_started_msec > 250:
				print("PROBE HOST CLEANUP OK")
				state = ProbeState.RECONNECT
		ProbeState.RECONNECT:
			if GameSession.players.size() == expected_players \
				and get_tree().get_nodes_in_group(&"player").size() == expected_players \
				and reconnect_confirmations.size() == expected_players - 1:
				print("PROBE FRESH RECONNECT OK")
				_reconnect_done.rpc()
				print("MULTIPLAYER PROBE PASS")
				state = ProbeState.FINISHED
				get_tree().create_timer(0.75).timeout.connect(func() -> void: get_tree().quit(0))

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--players="):
			expected_players = int(argument.trim_prefix("--players="))
		elif argument == "--disconnect-host":
			disconnect_host = true

func _on_session_synchronized() -> void:
	_build_world()
	await get_tree().create_timer(0.5).timeout
	var local_actor := _actor(NetworkManager.local_peer_id())
	if local_actor == null:
		_fail("client local actor was not spawned by the server roster")
		return
	if reconnecting:
		print("PROBE CLIENT FRESH RECONNECT OK")
		_confirm_reconnect.rpc_id(1)
		return
	client_start_position = local_actor.global_position
	Input.action_press(&"move_right")
	print("PROBE CLIENT WORLD READY")

func _build_world() -> void:
	world = (load("res://world/adventure/sewer_region.tscn") as PackedScene).instantiate() as Node2D
	world.name = "NetworkProbeWorld"
	world.call("configure", AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", &"normal", GameSession.session_id))
	add_child(world)
	ladder = world.get_node("EmergencyLadder") as ClimbableArea2D
	spawner = world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	for enemy in get_tree().get_nodes_in_group(&"enemy"):
		enemy.set_physics_process(false)

func _actor(peer_id: int) -> PlayerActor:
	return world.get_node_or_null("Player_%d" % peer_id) as PlayerActor

@rpc("authority", "call_remote", "reliable")
func _begin_jump_test() -> void:
	Input.action_release(&"move_right")
	var event := InputEventAction.new()
	event.action = &"jump"
	event.pressed = true
	var actor := _actor(NetworkManager.local_peer_id())
	if actor != null:
		actor.input._unhandled_input(event)
	print("PROBE CLIENT JUMP INPUT")

@rpc("authority", "call_remote", "reliable")
func _begin_climb_test() -> void:
	Input.action_release(&"move_right")
	Input.action_press(&"move_up")
	print("PROBE CLIENT CLIMB INPUT")

@rpc("authority", "call_remote", "reliable")
func _begin_health_test(peer_id: int) -> void:
	health_test_peer = peer_id

@rpc("any_peer", "call_remote", "reliable")
func _confirm_health_presentation() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		health_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _begin_respawn_test(peer_id: int) -> void:
	respawn_test_peer = peer_id
	var actor := _actor(peer_id)
	client_old_actor_id = actor.get_instance_id() if actor != null else 0

@rpc("any_peer", "call_remote", "reliable")
func _confirm_respawn_presentation() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		respawn_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _probe_done() -> void:
	Input.action_release(&"move_right")
	Input.action_release(&"move_up")
	var peer_ids: Array[int] = []
	peer_ids.assign(GameSession.players.keys())
	peer_ids.sort()
	var disconnect_delay := 0.2 + maxf(0.0, float(peer_ids.find(NetworkManager.local_peer_id()) - 1)) * 0.5
	await get_tree().create_timer(disconnect_delay).timeout
	if not client_saw_authoritative_snapshot:
		_fail("client did not display an authoritative transform snapshot")
		return
	print("PROBE CLIENT MOVEMENT OK")
	NetworkManager.leave_game()
	if not session_end_verified:
		_fail("manual leave did not complete the network session lifecycle")
		return
	var retired_world := world
	world = null
	if is_instance_valid(retired_world):
		remove_child(retired_world)
		retired_world.queue_free()
	await get_tree().create_timer(1.0).timeout
	reconnecting = true
	session_end_verified = false
	if NetworkManager.join_game("127.0.0.1", port) != OK:
		_fail("fresh reconnect setup failed")

@rpc("any_peer", "call_remote", "reliable")
func _confirm_reconnect() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		reconnect_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _reconnect_done() -> void:
	var peer_ids: Array[int] = []
	peer_ids.assign(GameSession.players.keys())
	peer_ids.sort()
	var leave_delay := 0.1 + maxf(0.0, float(peer_ids.find(NetworkManager.local_peer_id()) - 1)) * 0.2
	await get_tree().create_timer(leave_delay).timeout
	NetworkManager.leave_game()
	if not session_end_verified:
		_fail("fresh reconnect did not end cleanly")
		return
	get_tree().quit(0)

func _on_multiplayer_session_ended(reason: String) -> void:
	if role != "client":
		return
	if NetworkManager.state != NetworkManager.ConnectionState.OFFLINE \
		or not NetworkManager.players.is_empty() or not NetworkManager.world_ready_peers.is_empty() \
		or GameSession.players.size() != 1 or GameSession.phase != GameSession.Phase.MENU \
		or not GameSession.session_id.is_empty():
		_fail("session-end signal fired before cleanup completed")
		return
	session_end_verified = true
	print("PROBE CLIENT SESSION END OK %s" % reason)

func _on_server_disconnected() -> void:
	if role == "client" and disconnect_host:
		if not session_end_verified:
			_fail("server disconnect did not complete the network session lifecycle")
			return
		print("PROBE CLIENT HOST DISCONNECT OK")
		print("MULTIPLAYER PROBE PASS")
		get_tree().quit(0)
	elif role == "client":
		_fail("server disconnected before probe completion")

func _fail(message: String) -> void:
	push_error("MULTIPLAYER PROBE FAIL: %s" % message)
	get_tree().quit(1)
