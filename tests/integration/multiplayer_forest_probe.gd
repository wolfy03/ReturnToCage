extends Node
## Process-separated ENet probe for the Forest Trail: server-owned enemy spawns,
## frog targeting and leap damage, replicated animation state, a late entrant,
## leash/return, and replicated death and removal for the frog and the beetle.

const SETTLEMENT: StringName = &"settlement"
const FOREST: StringName = &"adventure:forest_region"
const GATE := Vector2(1010, 510)

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
## entity id -> animations its replica has shown on this process.
var _seen_animations: Dictionary[int, Dictionary] = {}

func _ready() -> void:
	_parse_arguments()
	_deadline_msec = Time.get_ticks_msec() + 70000
	world_layer = Node.new()
	world_layer.name = "WorldLayer"
	add_child(world_layer)
	SceneRouter.register_world_layer(world_layer)
	NetworkManager.local_world_assignment_received.connect(_on_world_assignment)
	NetworkManager.connection_failed.connect(func() -> void: _fail(NetworkManager.last_error))
	if role == "host":
		_server_root = ServerWorldRoot.new()
		_server_root.name = "ServerWorldRoot"
		add_child(_server_root)
		if NetworkManager.host_game(port, expected_players) != OK or not GameSession.start_new_game() \
				or not SceneRouter.go_to_settlement():
			_fail("host setup failed")
			return
		print("FOREST HOST LISTENING")
		call_deferred("_run_host_scenario")
	elif NetworkManager.join_game("127.0.0.1", port) != OK:
		_fail("client setup failed")

func _process(_delta: float) -> void:
	if _finished:
		return
	if Time.get_ticks_msec() > _deadline_msec:
		_fail("timeout role=%s world=%s confirmations=%s" % [role, SceneRouter.current_world_id(), _confirmations.keys()])
		return
	var manager := _enemy_manager()
	if manager == null:
		return
	for entity_id in manager._enemies:
		var enemy := manager.get_enemy(entity_id)
		if enemy != null and enemy.animation_presenter != null:
			if not _seen_animations.has(entity_id):
				_seen_animations[entity_id] = {}
			_seen_animations[entity_id][String(enemy.animation_presenter.current_animation)] = true

func _run_host_scenario() -> void:
	if not await _wait_until(func() -> bool:
		return NetworkManager.players.size() == expected_players and _all_peers_ready()
	, 15.0):
		_fail("players did not become ready")
		return
	for peer_id in NetworkManager.players:
		if peer_id != 1:
			_remote_peers.append(peer_id)
	_remote_peers.sort()
	var b_peer := _remote_peers[0]
	var c_peer := _remote_peers[1] if _remote_peers.size() > 1 else 0

	# B enters alone. The server runtime owns every spawn.
	if not await _enter_client(b_peer):
		return
	var runtime := _server_root.runtime(FOREST)
	if runtime == null or runtime.enemy_manager() == null or runtime.participant_peer_ids() != [b_peer]:
		_fail("Forest authoritative runtime was not created for B alone")
		return
	var enemies := _runtime_enemies(runtime)
	var frog: FrogAgent
	var beetle: EnemyAgent
	var kinds: Dictionary[StringName, int] = {}
	for enemy in enemies:
		kinds[enemy.definition.id] = int(kinds.get(enemy.definition.id, 0)) + 1
		if enemy.animation_presenter != null or not enemy.is_simulation_authority():
			_fail("server runtime enemy is not a visual-free authority: %d" % enemy.network_entity_id)
			return
		if enemy is FrogAgent and frog == null:
			frog = enemy
		elif not enemy is FrogAgent and beetle == null:
			beetle = enemy
	if enemies.size() != 4 or kinds.get(&"frog", 0) != 2 or kinds.get(&"sewer_beetle", 0) != 2:
		_fail("Forest did not spawn two frogs and two beetles on the server: %s" % kinds)
		return
	var b_roster := _confirmation("ENTER", b_peer).get("enemies", {}) as Dictionary
	if not _roster_matches(b_roster, enemies):
		_fail("B's enemy roster differs from the server: %s" % b_roster)
		return
	if SceneRouter.current_world_id() != SETTLEMENT or _enemy_manager() != null:
		_fail("host presentation left Settlement or shows Forest enemies")
		return

	# Frog targeting, chase, leap attack: decided and damaged on the server only.
	var b_actor := runtime.player_manager().get_actor(b_peer)
	if b_actor == null:
		_fail("B has no authoritative Forest actor")
		return
	var hits: Array[int] = [0]
	var attacks: Array[int] = [0]
	var hops: Array[int] = [0]
	b_actor.health.invulnerability_seconds = 0.0
	var frog_damage: Array[float] = [0.0]
	b_actor.health.damaged.connect(func(context: DamageContext) -> void:
		# Other forest enemies may join the fight; only this frog's leaps are counted.
		if context.source == frog:
			hits[0] += 1
			frog_damage[0] += context.amount
	)
	frog.state_changed.connect(func(id: StringName) -> void:
		if id == &"attack":
			attacks[0] += 1
		elif id == &"hop":
			hops[0] += 1
	)
	# Open ground with nothing reachable overhead.
	b_actor.global_position = Vector2(1960.0, 518.0)
	b_actor.velocity = Vector2.ZERO
	frog.global_position = Vector2(2140.0, 524.0)
	frog.patrol_origin = frog.global_position
	frog.velocity = Vector2.ZERO
	frog.change_state(&"idle")
	var health_before := b_actor.health.current_health
	if not await _wait_until(func() -> bool: return attacks[0] >= 2 and frog.current_state_id != &"attack", 12.0):
		_fail("server frog did not chase and attack B: state=%s attacks=%d hops=%d target=%s" % [frog.current_state_id, attacks[0], hops[0], frog.player])
		return
	if frog.player != b_actor or hops[0] < 1 or hits[0] < 1 or hits[0] > attacks[0] or b_actor.health.current_health >= health_before:
		_fail("frog attack accounting is wrong: hits=%d attacks=%d hops=%d health %.1f -> %.1f" % [hits[0], attacks[0], hops[0], health_before, b_actor.health.current_health])
		return
	if frog_damage[0] <= 0.0 or frog_damage[0] > float(attacks[0]) * frog.effect_stats.value(&"attack_power") + 0.01:
		_fail("a leap damaged B more than once: %.2f over %d attacks" % [frog_damage[0], attacks[0]])
		return
	_send_command(b_peer, "REPORT_ENEMY", {"entity_id": frog.network_entity_id})
	if not await _wait_until(func() -> bool: return _confirmed("REPORT_ENEMY", b_peer)):
		_fail("B did not report the frog replica")
		return
	var frog_report := _confirmation("REPORT_ENEMY", b_peer)
	var frog_seen := frog_report.get("seen", []) as Array
	for animation in ["jump_start", "attack"]:
		if not frog_seen.has(animation):
			_fail("B's frog replica never showed %s: %s" % [animation, frog_seen])
			return
	if not frog_seen.has("jump") and not frog_seen.has("fall"):
		_fail("B's frog replica never showed an airborne clip: %s" % [frog_seen])
		return
	if bool(frog_report.get("simulating", true)) or bool(frog_report.get("hurtbox", true)):
		_fail("B's frog replica simulates or can be hit locally")
		return
	if float(frog_report.get("local_health", 0.0)) >= float(frog_report.get("local_max_health", 0.0)):
		_fail("B did not receive the frog's damage from the server: %s" % frog_report)
		return

	# Leash: the target walks away, the frog goes home instead of chasing forever.
	b_actor.health.god_mode = true
	b_actor.global_position = Vector2(300.0, 518.0)
	b_actor.velocity = Vector2.ZERO
	if not await _wait_until(func() -> bool:
		return (frog.current_state_id == &"idle" or frog.current_state_id == &"patrol") \
			and absf(frog.global_position.x - frog.patrol_origin.x) <= frog.patrol_radius + 12.0
	, 12.0):
		_fail("frog did not return home after losing B: state=%s x=%.0f origin=%.0f" % [frog.current_state_id, frog.global_position.x, frog.patrol_origin.x])
		return
	if frog.global_position.x < 1300.0 or frog.global_position.x > 2400.0 or frog.global_position.y > 560.0:
		_fail("frog left its terrain: %s" % frog.global_position)
		return

	# Late entrants restore the live enemy state: C (three players), then the host.
	if c_peer != 0:
		if not await _enter_client(c_peer):
			return
		if not _roster_matches(_confirmation("ENTER", c_peer).get("enemies", {}) as Dictionary, _runtime_enemies(runtime)):
			_fail("late client C did not restore the live enemy roster")
			return
	NetworkManager.authoritative_actor(1).position = GATE
	var host_enter := NetworkManager.request_enter_region(&"forest_gate", &"forest_region")
	if not host_enter.success or not await _wait_until(func() -> bool:
		return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == FOREST \
			and _enemy_manager() != null and _enemy_manager()._enemies.size() == 4
	, 8.0):
		_fail("late host entrant did not receive the Forest enemy roster")
		return
	await get_tree().create_timer(0.4).timeout
	if not _roster_matches(_local_roster(), _runtime_enemies(runtime)):
		_fail("host presentation roster differs from the authoritative runtime: %s" % _local_roster())
		return
	var expected_participants: Array[int] = [1, b_peer]
	if c_peer != 0:
		expected_participants.append(c_peer)
	expected_participants.sort()
	if runtime.participant_peer_ids() != expected_participants or _runtime_enemies(runtime).size() != 4:
		_fail("late entrants changed the authoritative enemy set")
		return
	# With several players present the server still picks one valid target.
	frog.change_state(&"idle")
	var host_actor := runtime.player_manager().get_actor(1)
	host_actor.health.god_mode = true
	host_actor.global_position = frog.global_position + Vector2(-120.0, -6.0)
	if not await _wait_until(func() -> bool: return frog.player == host_actor and frog.current_state_id != &"idle" and frog.current_state_id != &"patrol", 6.0):
		_fail("server frog did not retarget the nearest valid player")
		return
	host_actor.global_position = Vector2(200.0, 518.0)

	# Death and removal replicate for both kinds; loot stays server-owned.
	var doomed: Array[int] = [frog.network_entity_id, beetle.network_entity_id]
	var loot_before := runtime.loot_manager().entity_ids().size()
	for enemy in [frog, beetle]:
		enemy.health.invulnerability_seconds = 0.0
		enemy.health.receive_damage(DamageContext.new(9999.0, &"physical", b_actor, &"player", Vector2.ZERO))
		if enemy.current_state_id != &"dead":
			_fail("lethal damage did not kill enemy %d" % enemy.network_entity_id)
			return
	if not await _wait_until(func() -> bool: return _runtime_enemies(runtime).size() == 2, 4.0):
		_fail("dead enemies were not removed from the server runtime")
		return
	if runtime.loot_manager().entity_ids().size() < loot_before:
		_fail("enemy death removed server loot")
		return
	for peer_id in expected_participants:
		if peer_id == 1:
			continue
		_send_command(peer_id, "REPORT_GONE", {"ids": doomed, "require_death": peer_id == b_peer or true})
	if not await _wait_until(func() -> bool:
		for peer_id in expected_participants:
			if peer_id != 1 and not _confirmed("REPORT_GONE", peer_id):
				return false
		return true
	, 6.0):
		_fail("clients did not confirm enemy death and removal")
		return
	if not await _wait_until(func() -> bool: return _enemy_manager() != null and _enemy_manager()._enemies.size() == 2, 4.0):
		_fail("host presentation kept a dead enemy")
		return
	for entity_id in doomed:
		if not (_seen_animations.get(entity_id, {}) as Dictionary).has("death"):
			_fail("host presentation never showed the death of enemy %d" % entity_id)
			return
	_finish_success()

func _enter_client(peer_id: int) -> bool:
	var actor := NetworkManager.authoritative_actor(peer_id)
	if actor != null:
		actor.position = GATE
		actor.velocity = Vector2.ZERO
	_send_command(peer_id, "ENTER", {})
	if not await _wait_until(func() -> bool: return _confirmed("ENTER", peer_id), 10.0):
		_fail("client %d did not enter the Forest" % peer_id)
		return false
	return true

func _runtime_enemies(runtime: ServerWorldRuntime) -> Array[EnemyAgent]:
	var result: Array[EnemyAgent] = []
	for entity_id in runtime.enemy_manager()._enemies:
		var enemy := runtime.enemy_manager().get_enemy(entity_id)
		if enemy != null:
			result.append(enemy)
	return result

## Same ids, same kinds, and positions close to the authoritative ones.
func _roster_matches(roster: Dictionary, enemies: Array[EnemyAgent]) -> bool:
	if roster.size() != enemies.size():
		return false
	for enemy in enemies:
		var entry: Variant = roster.get(enemy.network_entity_id, roster.get(str(enemy.network_entity_id)))
		if not entry is Dictionary or entry.get("enemy") != String(enemy.definition.id) \
				or not bool(entry.get("presenter", false)) or bool(entry.get("simulating", true)):
			return false
		if (entry.get("position") as Vector2).distance_to(enemy.global_position) > 160.0:
			return false
	return true

func _local_roster() -> Dictionary:
	var roster := {}
	var manager := _enemy_manager()
	if manager == null:
		return roster
	for entity_id in manager._enemies:
		var enemy := manager.get_enemy(entity_id)
		if enemy != null:
			roster[entity_id] = {"enemy": String(enemy.definition.id), "position": enemy.global_position,
				"presenter": enemy.animation_presenter != null, "simulating": enemy.is_physics_processing()}
	return roster

@rpc("authority", "call_remote", "reliable")
func _command(command: String, data: Dictionary) -> void:
	match command:
		"ENTER":
			var result := NetworkManager.request_enter_region(&"forest_gate", &"forest_region")
			if not result.success:
				_fail("client could not request the Forest: %s" % result.message)
				return
			if not await _wait_until(func() -> bool:
				return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == FOREST \
					and _enemy_manager() != null and _enemy_manager()._enemies.size() == 4
			, 8.0):
				_fail("Forest world or enemy roster was not replicated")
				return
			await get_tree().create_timer(0.4).timeout
			_confirm.rpc_id(1, command, {"enemies": _local_roster()})
		"REPORT_ENEMY":
			var enemy := _enemy_manager().get_enemy(int(data.get("entity_id", 0))) if _enemy_manager() != null else null
			if enemy == null:
				_fail("replica is missing for the reported enemy")
				return
			var actor := _local_actor()
			_confirm.rpc_id(1, command, {
				"seen": (_seen_animations.get(enemy.network_entity_id, {}) as Dictionary).keys(),
				"simulating": enemy.is_physics_processing(),
				"hurtbox": enemy.hurtbox.monitoring or enemy.hurtbox.monitorable,
				"local_health": GameSession.player.health if GameSession.player != null else -1.0,
				"local_max_health": GameSession.player.stats.value(&"max_health") if GameSession.player != null else -1.0,
				"has_actor": actor != null,
			})
		"REPORT_GONE":
			var ids: Array = data.get("ids", [])
			if not await _wait_until(func() -> bool:
				var manager := _enemy_manager()
				if manager == null:
					return false
				for entity_id in ids:
					if manager.get_enemy(int(entity_id)) != null:
						return false
				return true
			, 5.0):
				_fail("enemy removal was not replicated")
				return
			for entity_id in ids:
				if not (_seen_animations.get(int(entity_id), {}) as Dictionary).has("death"):
					_fail("replica of enemy %d never showed death before removal" % int(entity_id))
					return
			_confirm.rpc_id(1, command, {"remaining": _enemy_manager()._enemies.size()})

@rpc("any_peer", "call_remote", "reliable")
func _confirm(command: String, data: Dictionary) -> void:
	if role != "host":
		return
	var sender := multiplayer.get_remote_sender_id()
	if not NetworkManager.has_peer(sender):
		_fail("confirmation from unknown peer")
		return
	_confirmations["%s:%d" % [command, sender]] = data

func _send_command(peer_id: int, command: String, data: Dictionary) -> void:
	_confirmations.erase("%s:%d" % [command, peer_id])
	_command.rpc_id(peer_id, command, data)

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

func _current_world_root() -> Node:
	return world_layer.get_child(0) if world_layer.get_child_count() > 0 else null

func _enemy_manager() -> EnemySpawnManager:
	var root := _current_world_root()
	return root.get_node_or_null("EnemySpawnManager") as EnemySpawnManager if root != null else null

func _local_actor() -> PlayerActor:
	var root := _current_world_root()
	var manager := root.get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager if root != null else null
	return manager.get_actor(NetworkManager.local_peer_id()) if manager != null else null

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
	print("FOREST PROBE PASS players=%d" % expected_players)
	await get_tree().create_timer(0.15).timeout
	get_tree().quit(0)

@rpc("authority", "call_remote", "reliable")
func _finish_remote() -> void:
	if _finished:
		return
	_finished = true
	print("FOREST PROBE PASS client=%d" % index)
	await get_tree().create_timer(0.35).timeout
	get_tree().quit(0)

func _fail(message: String) -> void:
	if _finished:
		return
	_finished = true
	push_error("FOREST PROBE FAIL: %s" % message)
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
