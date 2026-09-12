extends Node

const SETTLEMENT: StringName = &"settlement"
const SEWER: StringName = &"adventure:sewer_region"

var role := ""
var index := 0
var port := NetworkManager.DEFAULT_PORT
var expected_players := 2
var world_layer: Node
var _server_root: ServerWorldRoot
var _confirmations: Dictionary[String, Dictionary] = {}
var _remote_peers: Array[int] = []
var _finished := false
var _deadline_msec := 0
var _sewer_enemy_events := 0
var _sewer_loot_events := 0

func _ready() -> void:
	_parse_arguments()
	_deadline_msec = Time.get_ticks_msec() + 45000
	world_layer = Node.new()
	world_layer.name = "WorldLayer"
	add_child(world_layer)
	SceneRouter.register_world_layer(world_layer)
	NetworkManager.local_world_assignment_received.connect(_on_world_assignment)
	NetworkManager.connection_failed.connect(func() -> void: _fail(NetworkManager.last_error))
	NetworkManager.enemy_spawn_received.connect(func(world_id: StringName, _payload: Dictionary) -> void:
		if role == "host" and world_id == SEWER:
			_sewer_enemy_events += 1
	)
	NetworkManager.loot_spawn_received.connect(func(world_id: StringName, _payload: Dictionary) -> void:
		if role == "host" and world_id == SEWER:
			_sewer_loot_events += 1
	)
	if role == "host":
		_server_root = ServerWorldRoot.new()
		_server_root.name = "ServerWorldRoot"
		add_child(_server_root)
		if NetworkManager.host_game(port, expected_players) != OK or not GameSession.start_new_game() \
				or not SceneRouter.go_to_settlement():
			_fail("host setup failed")
			return
		print("WORLD RUNTIME HOST LISTENING")
		call_deferred("_run_host_scenario")
	else:
		if NetworkManager.join_game("127.0.0.1", port) != OK:
			_fail("client setup failed")

func _process(_delta: float) -> void:
	if not _finished and Time.get_ticks_msec() > _deadline_msec:
		_fail("timeout role=%s world=%s confirmations=%s" % [role, SceneRouter.current_world_id(), _confirmations.keys()])

func _run_host_scenario() -> void:
	if not await _wait_until(func() -> bool:
		return NetworkManager.players.size() == expected_players and _all_peers_ready()
	):
		_fail("players did not become ready")
		return
	for peer_id in NetworkManager.players:
		if peer_id != 1:
			_remote_peers.append(peer_id)
	_remote_peers.sort()
	var b_peer := _remote_peers[0]
	var c_peer := _remote_peers[1] if _remote_peers.size() > 1 else 0
	for peer_id in _remote_peers:
		_command.rpc_id(peer_id, "ENTER", 0)
	if not await _wait_until(func() -> bool:
		for peer_id in _remote_peers:
			if not _confirmed("ENTER", peer_id):
				return false
		return true
	):
		_fail("clients did not enter Sewer")
		return
	if SceneRouter.current_world_id() != SETTLEMENT or GameSession.get_peer_world_id(1) != SETTLEMENT:
		_fail("host presentation left Settlement")
		return
	var runtime := _server_root.runtime(SEWER)
	if runtime == null or runtime.player_manager() == null or runtime.enemy_manager() == null:
		_fail("Sewer authoritative runtime was not created")
		return
	var runtime_identity := runtime.get_instance_id()
	var settlement_runtime := _server_root.runtime(SETTLEMENT)
	if settlement_runtime == null or settlement_runtime._viewport.world_2d == runtime._viewport.world_2d:
		_fail("server physics worlds are not isolated")
		return
	if runtime.participant_peer_ids() != _remote_peers or _presentation_roster().size() != 1:
		_fail("host presentation/runtime participant isolation failed")
		return
	_command.rpc_id(b_peer, "SETTLEMENT_REJECT", 0)
	if not await _wait_until(func() -> bool: return _confirmed("SETTLEMENT_REJECT", b_peer)):
		_fail("Sewer player did not receive a Settlement-command rejection")
		return
	var settlement_rejection := _confirmation("SETTLEMENT_REJECT", b_peer)
	if bool(settlement_rejection.get("success", true)) \
			or GameSession.settlement.facility_levels.get(&"workbench", 0) != 0:
		_fail("Sewer player mutated Settlement through a world-scoped command")
		return
	var session := GameSession.adventure_session_for_world(SEWER)
	var elapsed_before := session.elapsed_seconds if session != null else -1.0
	await get_tree().create_timer(0.35).timeout
	if session == null or session.elapsed_seconds <= elapsed_before:
		_fail("background Sewer clock did not advance")
		return
	var enemy := _first_enemy(runtime)
	if enemy == null:
		_fail("Sewer enemy runtime is empty")
		return
	var initial_target := runtime.player_manager().get_actor(b_peer)
	if initial_target == null:
		_fail("Sewer authoritative player actor is missing")
		return
	enemy.global_position = initial_target.global_position + Vector2(150, 0)
	var enemy_origin := enemy.global_position
	await get_tree().create_timer(0.35).timeout
	if enemy.global_position.is_equal_approx(enemy_origin) or enemy.player == null or enemy.player.peer_id == 1:
		_fail("Sewer enemy AI did not target a Sewer participant")
		return

	if c_peer > 0:
		_command.rpc_id(c_peer, "WATCH_B_MOVE", b_peer)
	var b_runtime_origin := runtime.player_manager().get_actor(b_peer).position
	var move_direction := 1
	if c_peer > 0:
		var c_actor := runtime.player_manager().get_actor(c_peer)
		if c_actor != null and c_actor.position.x > b_runtime_origin.x:
			move_direction = -1
		print("WORLD RUNTIME MOVE b=%d bx=%.2f c=%d cx=%.2f direction=%d" % [
			b_peer, b_runtime_origin.x, c_peer, c_actor.position.x if c_actor != null else -1.0, move_direction,
		])
	_command.rpc_id(b_peer, "MOVE", move_direction)
	if not await _wait_until(func() -> bool:
		return _confirmed("MOVE", b_peer) and (c_peer == 0 or _confirmed("WATCH_B_MOVE", c_peer))
	):
		_fail("same-world movement was not replicated")
		return
	var b_actor := runtime.player_manager().get_actor(b_peer)
	var reported_x := float(_confirmation("MOVE", b_peer).get("x", INF))
	if b_actor == null or absf(b_actor.position.x - b_runtime_origin.x) <= 12.0 \
			or absf(reported_x - b_actor.position.x) > 30.0:
		_fail("authoritative B movement did not execute")
		return
	if _sewer_enemy_events != 0 or _sewer_loot_events != 0:
		_fail("Sewer entity events leaked into host Settlement presentation")
		return

	# A Settlement attack and forged Sewer loot claim are routed only to A's
	# world; neither may mutate the isolated Sewer physics/entity runtime.
	enemy.set_physics_process(false)
	enemy.global_position = b_actor.global_position + Vector2(34, 0)
	b_actor.facing = 1.0
	var health_before_cross_world := enemy.health.current_health
	NetworkManager.submit_player_attack(1, 9000)
	await get_tree().create_timer(0.25).timeout
	if enemy.health.current_health != health_before_cross_world:
		_fail("cross-world host attack damaged Sewer enemy")
		return

	var attack_sequence := 100
	var previous_health := enemy.health.current_health
	while enemy != null and is_instance_valid(enemy) and enemy.health.current_health > 0.0 and attack_sequence < 105:
		enemy.global_position = b_actor.global_position + Vector2(34, 0)
		_command.rpc_id(b_peer, "ATTACK", attack_sequence)
		if not await _wait_until(func() -> bool:
			return not is_instance_valid(enemy) or enemy.health.current_health < previous_health
		, 2.0):
			_fail("production combat request did not damage the Sewer enemy")
			return
		if is_instance_valid(enemy):
			previous_health = enemy.health.current_health
		attack_sequence += 1
		await get_tree().create_timer(0.55).timeout
	if not await _wait_until(func() -> bool: return not runtime.loot_manager().entity_ids().is_empty(), 3.0):
		_fail("enemy death did not create world-local loot")
		return
	var loot_id: int = runtime.loot_manager().entity_ids()[0]
	NetworkManager.request_loot_pickup(loot_id)
	await get_tree().create_timer(0.15).timeout
	if runtime.loot_manager().get_loot(loot_id) == null:
		_fail("cross-world host pickup claimed Sewer loot")
		return
	var loot := runtime.loot_manager().get_loot(loot_id)
	b_actor.global_position = loot.global_position
	_command.rpc_id(b_peer, "PICKUP", loot_id)
	if not await _wait_until(func() -> bool: return runtime.loot_manager().get_loot(loot_id) == null, 3.0):
		_fail("same-world loot pickup did not commit")
		return
	if c_peer > 0:
		_command.rpc_id(c_peer, "REPORT_EMPTY_LOOT", 0)
		if not await _wait_until(func() -> bool: return _confirmed("REPORT_EMPTY_LOOT", c_peer)):
			_fail("C retained loot after B claim")
			return
	var gather_peer := c_peer if c_peer > 0 else b_peer
	var runtime_region := runtime.runtime_scene
	var gather_target: InteractionTarget = runtime_region._gather_targets.get(&"scrap_cache_a")
	var gather_actor := runtime.player_manager().get_actor(gather_peer)
	if gather_target == null or gather_actor == null:
		_fail("authoritative gather fixture is unavailable")
		return
	gather_actor.global_position = gather_target.global_position
	_command.rpc_id(gather_peer, "GATHER", 0)
	if not await _wait_until(func() -> bool: return runtime_region._consumed_gather.has(&"scrap_cache_a")):
		_fail("same-world gather did not commit")
		return
	var observe_gather_peer := b_peer if gather_peer == c_peer else c_peer
	if observe_gather_peer > 0:
		_command.rpc_id(observe_gather_peer, "REPORT_GATHER_ABSENT", 0)
		if not await _wait_until(func() -> bool: return _confirmed("REPORT_GATHER_ABSENT", observe_gather_peer)):
			_fail("consumed gather remained visible to a same-world peer")
			return

	_command.rpc_id(b_peer, "RETURN", 0)
	if not await _wait_until(func() -> bool: return _confirmed("RETURN", b_peer)):
		_fail("B did not return independently")
		return
	if c_peer > 0:
		if GameSession.get_peer_world_id(c_peer) != SEWER or _server_root.runtime(SEWER) == null \
				or _server_root.runtime(SEWER).get_instance_id() != runtime_identity:
			_fail("B exit destroyed C's Sewer runtime")
			return
		_command.rpc_id(c_peer, "RETURN", 0)
		if not await _wait_until(func() -> bool: return _confirmed("RETURN", c_peer)):
			_fail("C did not return")
			return
	await get_tree().process_frame
	await get_tree().process_frame
	if _server_root.runtime(SEWER) != null:
		_fail("empty Sewer runtime was not cleaned up")
		return
	_command.rpc_id(b_peer, "REENTER", 0)
	if not await _wait_until(func() -> bool: return _confirmed("REENTER", b_peer)):
		_fail("B did not re-enter a fresh Sewer runtime")
		return
	var fresh_runtime := _server_root.runtime(SEWER)
	if fresh_runtime == null or fresh_runtime.get_instance_id() == runtime_identity \
			or fresh_runtime.enemy_manager() == null or fresh_runtime.enemy_manager().get_enemy(1) == null:
		_fail("Sewer re-entry did not create one fresh runtime")
		return
	if expected_players == 2:
		# Reverse the presentation split as well: the host enters Sewer while the
		# remote player remains in Settlement. The host presentation is still a
		# mirror; authoritative movement continues in the isolated Sewer runtime.
		_command.rpc_id(b_peer, "RETURN_FOR_HOST", 0)
		if not await _wait_until(func() -> bool: return _confirmed("RETURN_FOR_HOST", b_peer)):
			_fail("B did not return before the host-only Sewer scenario")
			return
		var host_enter := NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region")
		if not host_enter.success or not await _wait_until(func() -> bool:
			return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == SEWER
		):
			_fail("host did not enter its independently presented Sewer world")
			return
		_command.rpc_id(b_peer, "REPORT_SETTLEMENT", 0)
		if not await _wait_until(func() -> bool: return _confirmed("REPORT_SETTLEMENT", b_peer)):
			_fail("Settlement client was affected by the host transition")
			return
		var host_runtime := _server_root.runtime(SEWER)
		var host_actor := host_runtime.player_manager().get_actor(1) if host_runtime != null else null
		if host_runtime == null or host_actor == null or host_runtime.participant_peer_ids() != [1] \
				or _presentation_roster() != [1]:
			_fail("host-only Sewer runtime/presentation roster is inconsistent")
			return
		var host_origin := host_actor.position
		var host_sequence := 20000
		var host_move_until := Time.get_ticks_msec() + 600
		while Time.get_ticks_msec() < host_move_until:
			NetworkManager.submit_player_move_input(1, host_sequence, 1.0, 0.0, false)
			host_sequence += 1
			await get_tree().process_frame
		NetworkManager.submit_player_move_input(1, host_sequence, 0.0, 0.0, false)
		await get_tree().create_timer(0.15).timeout
		if absf(host_actor.position.x - host_origin.x) <= 12.0:
			_fail("host authoritative Sewer actor did not move")
			return
	_finish_success()

@rpc("authority", "call_remote", "reliable")
func _command(command: String, value: int) -> void:
	match command:
		"ENTER", "REENTER":
			var result := NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region")
			if not result.success:
				_fail(result.message)
				return
			await _confirm_when_world_ready(command, SEWER)
		"RETURN", "RETURN_FOR_HOST":
			var result := NetworkManager.request_return_to_settlement()
			if not result.success:
				_fail(result.message)
				return
			await _confirm_when_world_ready(command, SETTLEMENT)
		"REPORT_SETTLEMENT":
			if SceneRouter.current_world_id() != SETTLEMENT \
					or GameSession.get_peer_world_id(NetworkManager.local_peer_id()) != SETTLEMENT \
					or _presentation_roster() != [NetworkManager.local_peer_id()] \
					or _enemy_manager() != null:
				_fail("client Settlement presentation contains another-world state")
				return
			_confirm.rpc_id(1, command, {"roster": _presentation_roster()})
		"SETTLEMENT_REJECT":
			var service := get_tree().get_first_node_in_group(&"settlement_replication_service") as SettlementReplicationService
			if service == null:
				_fail("Settlement replication service is unavailable")
				return
			var reply: Dictionary = {}
			service.facility_upgrade_result.connect(func(success: bool, message: String) -> void:
				reply["success"] = success
				reply["message"] = message
			, CONNECT_ONE_SHOT)
			service.request_upgrade_facility(&"workbench")
			if not await _wait_until(func() -> bool: return reply.has("success")):
				_fail("Settlement command rejection response timed out")
				return
			_confirm.rpc_id(1, command, reply)
		"MOVE":
			var actor := _local_actor()
			var start_x := actor.position.x if actor != null else INF
			var sequence := 10000
			var move_until := Time.get_ticks_msec() + 750
			while Time.get_ticks_msec() < move_until:
				NetworkManager.submit_player_move_input(
					NetworkManager.local_peer_id(), sequence, float(value), 0.0, false
				)
				sequence += 1
				await get_tree().process_frame
			NetworkManager.submit_player_move_input(
				NetworkManager.local_peer_id(), sequence, 0.0, 0.0, false
			)
			await get_tree().create_timer(0.15).timeout
			actor = _local_actor()
			if actor == null or absf(actor.position.x - start_x) <= 12.0:
				_fail("local presentation did not receive movement start=%.2f current=%.2f" % [start_x, actor.position.x if actor != null else -1.0])
				return
			_confirm.rpc_id(1, command, {"x": actor.position.x})
		"WATCH_B_MOVE":
			var watched := _actor(value)
			var start_x := watched.position.x if watched != null else INF
			if not await _wait_until(func() -> bool:
				var current := _actor(value)
				return current != null and absf(current.position.x - start_x) > 8.0
			):
				_fail("same-world remote movement mirror did not advance")
				return
			_confirm.rpc_id(1, command, {"x": _actor(value).position.x})
		"ATTACK":
			NetworkManager.submit_player_attack(NetworkManager.local_peer_id(), value)
			_confirm.rpc_id(1, command, {"sequence": value})
		"PICKUP":
			NetworkManager.request_loot_pickup(value)
			_confirm.rpc_id(1, command, {"entity_id": value})
		"REPORT_EMPTY_LOOT":
			if not await _wait_until(func() -> bool:
				var manager := _loot_manager()
				return manager != null and manager.entity_ids().is_empty()
			):
				_fail("same-world loot despawn was not replicated")
				return
			_confirm.rpc_id(1, command, {"empty": true})
		"GATHER":
			NetworkManager.request_gather(&"scrap_cache_a")
			_confirm.rpc_id(1, command, {"requested": true})
		"REPORT_GATHER_ABSENT":
			if not await _wait_until(func() -> bool:
				var root := _current_world_root()
				if root == null:
					return false
				var target: Variant = root._gather_targets.get(&"scrap_cache_a")
				return not is_instance_valid(target)
			):
				_fail("same-world gather consumption was not replicated")
				return
			_confirm.rpc_id(1, command, {"absent": true})

func _confirm_when_world_ready(command: String, world_id: StringName) -> void:
	if not await _wait_until(func() -> bool:
		return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == world_id
	):
		_fail("client world transition did not become ready: %s" % command)
		return
	if world_id == SEWER:
		if not await _wait_until(func() -> bool: return _enemy_manager() != null and _first_presentation_enemy() != null):
			_fail("Sewer enemy roster was not replicated")
			return
	_confirm.rpc_id(1, command, {"roster": _presentation_roster()})

@rpc("any_peer", "call_remote", "reliable")
func _confirm(command: String, data: Dictionary) -> void:
	if role != "host":
		return
	var sender := multiplayer.get_remote_sender_id()
	if not NetworkManager.has_peer(sender):
		_fail("confirmation from unknown peer")
		return
	_confirmations["%s:%d" % [command, sender]] = data

func _confirmed(command: String, peer_id: int) -> bool:
	return _confirmations.has("%s:%d" % [command, peer_id])

func _confirmation(command: String, peer_id: int) -> Dictionary:
	return _confirmations.get("%s:%d" % [command, peer_id], {})

func _all_peers_ready() -> bool:
	for peer_id in NetworkManager.players:
		if not NetworkManager.is_peer_world_ready(peer_id):
			return false
	return true

func _wait_until(predicate: Callable, seconds: float = 5.0) -> bool:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		if predicate.call():
			return true
		await get_tree().process_frame
	return bool(predicate.call())

func _first_enemy(runtime: ServerWorldRuntime) -> EnemyAgent:
	if runtime == null or runtime.enemy_manager() == null:
		return null
	for entity_id in runtime.enemy_manager()._enemies:
		return runtime.enemy_manager().get_enemy(entity_id)
	return null

func _first_presentation_enemy() -> EnemyAgent:
	var manager := _enemy_manager()
	if manager != null:
		for entity_id in manager._enemies:
			return manager.get_enemy(entity_id)
	return null

func _current_world_root() -> Node:
	return world_layer.get_child(0) if world_layer.get_child_count() > 0 else null

func _spawn_manager() -> PlayerSpawnManager:
	var root := _current_world_root()
	return root.get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager if root != null else null

func _enemy_manager() -> EnemySpawnManager:
	var root := _current_world_root()
	return root.get_node_or_null("EnemySpawnManager") as EnemySpawnManager if root != null else null

func _loot_manager() -> LootSpawnManager:
	var root := _current_world_root()
	return root.get_node_or_null("LootSpawnManager") as LootSpawnManager if root != null else null

func _actor(peer_id: int) -> PlayerActor:
	var manager := _spawn_manager()
	return manager.get_actor(peer_id) if manager != null else null

func _local_actor() -> PlayerActor:
	return _actor(NetworkManager.local_peer_id())

func _presentation_roster() -> Array[int]:
	var result: Array[int] = []
	var manager := _spawn_manager()
	if manager != null:
		result.assign(manager._actors.keys())
		result.sort()
	return result

func _on_world_assignment(assignment: PlayerWorldAssignment) -> void:
	if not SceneRouter.apply_world_assignment(assignment):
		_fail("cannot apply world assignment: %s" % assignment.world_id)

func _finish_success() -> void:
	if _finished:
		return
	if not NetworkManager.validate_runtime_invariants().is_empty():
		_fail("runtime mapping invariant failed")
		return
	_finished = true
	for peer_id in NetworkManager.players:
		if peer_id != 1 and NetworkManager.can_send_to_peer(peer_id):
			_finish_remote.rpc_id(peer_id)
	print("WORLD RUNTIME PROBE PASS players=%d" % expected_players)
	await get_tree().create_timer(0.15).timeout
	get_tree().quit(0)

@rpc("authority", "call_remote", "reliable")
func _finish_remote() -> void:
	if _finished:
		return
	_finished = true
	print("WORLD RUNTIME PROBE PASS client=%d" % index)
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(0)

func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	Input.action_release(&"move_left")
	push_error("WORLD RUNTIME PROBE FAIL: %s" % message)
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
