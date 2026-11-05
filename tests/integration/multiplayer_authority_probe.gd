extends "res://tests/integration/multiplayer_world_runtime_probe.gd"

var _drop_id: String = ""
var _failures_seen: int = 0
var _channel_events: Array[bool] = []
var _drop_events: int = 0

func _ready() -> void:
	NetworkManager.world_transition_failed.connect(func(_message: String) -> void: _failures_seen += 1)
	NetworkManager.return_channel_received.connect(func(active: bool, _progress: float) -> void: _channel_events.append(active))
	NetworkManager.death_drop_state_received.connect(func(_world: StringName, _payload: Dictionary) -> void: _drop_events += 1)
	super._ready()
	_deadline_msec = Time.get_ticks_msec() + 90000

func _run_host_scenario() -> void:
	if not await _wait_until(func() -> bool: return NetworkManager.players.size() == expected_players and _all_peers_ready()):
		_fail("authority peers not ready")
		return
	for peer in NetworkManager.players:
		if peer != 1:
			_remote_peers.append(peer)
	_remote_peers.sort()
	var b := _remote_peers[0]
	var c := _remote_peers[1] if _remote_peers.size() > 1 else 0
	var b_identity := GameSession.get_player_id(b)
	var c_identity := GameSession.get_player_id(c) if c > 0 else &""
	var host_scene := _current_world_root().get_instance_id()
	# Negative requests pass through the actual ENet RPC sender boundary.
	var before := _protected_state(b)
	_send_command(b, "FAR_ENTRY", 0)
	if not await _wait_until(func() -> bool: return _confirmed("FAR_ENTRY", b)) or _protected_state(b) != before:
		_fail("forged distant entry mutated state")
		return
	for peer in _remote_peers:
		_send_command(peer, "ENTER", 0)
		if not await _wait_until(func() -> bool: return _confirmed("ENTER", peer)):
			_fail("valid near entry failed")
			return
	var runtime := _server_root.runtime(SEWER)
	var runtime_id := runtime.get_instance_id()
	for enemy_id in runtime.enemy_manager()._enemies:
		runtime.enemy_manager().get_enemy(enemy_id).set_physics_process(false)
	var actor := NetworkManager.authoritative_actor(b)
	actor.position = Vector2(700, 510)
	actor.survival.set_process(false)
	before = _protected_state(b)
	_send_command(b, "FORGED_ESCAPES", 0)
	if not await _wait_until(func() -> bool: return _confirmed("FORGED_ESCAPES", b)) or _protected_state(b) != before:
		_fail("forged escape mutated canonical state")
		return
	# Remote discovery while the host compatibility facade is null.
	actor.position = Vector2(70, 510)
	if not await _wait_until(func() -> bool: return GameSession.adventure_session_for_peer(b).discovered_escape_points.has(&"sewer_entrance")) \
			or GameSession.adventure.active_session != null:
		_fail("world-aware discovery failed")
		return
	_send_command(b, "RETURN", 0)
	if not await _wait_until(func() -> bool: return _confirmed("RETURN", b)):
		_fail("valid normal escape failed")
		return
	if c > 0 and (_server_root.runtime(SEWER).get_instance_id() != runtime_id or GameSession.get_peer_world_id(c) != SEWER):
		_fail("individual normal escape destroyed C runtime")
		return
	_send_command(b, "REENTER", 0)
	if not await _wait_until(func() -> bool: return _confirmed("REENTER", b)):
		_fail("return-channel reentry failed")
		return
	runtime = _server_root.runtime(SEWER)
	for enemy_id in runtime.enemy_manager()._enemies:
		runtime.enemy_manager().get_enemy(enemy_id).set_physics_process(false)
	actor = NetworkManager.authoritative_actor(b)
	actor.position = Vector2(300, 510)
	actor.return_channel_required = 2.0
	actor.survival.set_process(false)
	await get_tree().create_timer(0.2).timeout
	var inventory := GameSession.get_player(b).inventory
	var seed_count := inventory.count(&"return_seed")
	_send_command(b, "START_ITEM", 0)
	if not await _wait_until(func() -> bool: return _confirmed("START_ITEM", b) and actor.return_channel > 0.0):
		_fail("remote quick item did not start server channel")
		return
	_send_command(b, "CANCEL_ITEM_MOVE", 0)
	if not await _wait_until(func() -> bool: return _confirmed("CANCEL_ITEM_MOVE", b) and actor.return_channel == 0.0) \
			or inventory.count(&"return_seed") != seed_count or not actor.movement.enabled:
		_fail("movement did not cancel return without consumption")
		return
	actor.return_channel_required = 0.6
	_send_command(b, "COMPLETE_ITEM", 0)
	if not await _wait_until(func() -> bool: return _confirmed("COMPLETE_ITEM", b)) \
			or inventory.count(&"return_seed") != seed_count - 1 or GameSession.get_peer_world_id(b) != SETTLEMENT:
		_fail("server channel completion did not consume exactly once")
		return
	_send_command(b, "STALE_ENTRY", 0)
	var returned := _protected_state(b)
	if not await _wait_until(func() -> bool: return _confirmed("STALE_ENTRY", b)) or _protected_state(b) != returned:
		_fail("stale transition replay mutated returned player")
		return
	# Re-enter under a world-specific DROP_AT_DEATH rules snapshot.
	_confirmations.erase("REENTER:%d" % b)
	_send_command(b, "REENTER", 0)
	if not await _wait_until(func() -> bool: return _confirmed("REENTER", b)):
		_fail("death scenario reentry failed")
		return
	runtime = _server_root.runtime(SEWER)
	runtime_id = runtime.get_instance_id()
	for enemy_id in runtime.enemy_manager()._enemies:
		runtime.enemy_manager().get_enemy(enemy_id).set_physics_process(false)
	var session := GameSession.adventure_session_for_peer(b)
	var c_inventory: Array[Dictionary] = []
	var c_loot: Array[Dictionary] = []
	if c > 0:
		c_inventory = GameSession.get_player(c).inventory.to_array()
		c_loot = session.get_player_adventure(c).unsecured_loot.to_array()
	var enemy_health: Dictionary[int, float] = {}
	for enemy_id in runtime.enemy_manager()._enemies:
		enemy_health[enemy_id] = runtime.enemy_manager().get_enemy(enemy_id).health.current_health
	var loot_ids := runtime.loot_manager().entity_ids()
	session.rules = AdventureRulesSnapshot.new(ContentRegistry.get_definition(&"survival") as DifficultyDefinition)
	actor = NetworkManager.authoritative_actor(b)
	actor.position = Vector2(300, 510)
	inventory.add_item(&"rusty_scrap", 4)
	var killed_actor_id := actor.get_instance_id()
	actor.health.invulnerable_remaining = 0.0
	var lethal := DamageContext.new(10000.0, &"test", null, &"environment")
	lethal.can_be_evaded = false
	actor.health.receive_damage(lethal)
	if not await _wait_until(func() -> bool:
		var current := NetworkManager.authoritative_actor(b)
		return current != null and current.get_instance_id() != killed_actor_id and not GameSession.adventure.death_drops.is_empty()
	):
		_fail("production death did not create drop and respawn")
		return
	var record: DeathDropRecord = GameSession.adventure.death_drops.back()
	_drop_id = record.id
	var drops := runtime.runtime_scene.get_node("DeathDropManager") as DeathDropManager
	if record.owner_player_id != b_identity or drops.target(record.id) == null:
		_fail("runtime death drop ownership/entity missing")
		return
	_set_drop.rpc_id(b, record.id)
	if c > 0:
		_set_drop.rpc_id(c, record.id)
		NetworkManager.authoritative_actor(c).position = record.position
		_send_command(c, "WRONG_OWNER", 0)
		if not await _wait_until(func() -> bool: return _confirmed("WRONG_OWNER", c)) or record.recovered:
			_fail("C claimed B personal drop")
			return
	NetworkManager.authoritative_actor(b).position = Vector2(900, 510)
	_send_command(b, "INVALID_DROP", 0)
	if not await _wait_until(func() -> bool: return _confirmed("INVALID_DROP", b)) or record.recovered:
		_fail("forged/wrong-world/far recovery succeeded")
		return
	# Disconnect while a channel is active, then recover with a fresh attachment.
	GameSession.get_player(b).inventory.add_item(&"return_seed", 1)
	actor = NetworkManager.authoritative_actor(b)
	actor.return_channel_required = 10.0
	_confirmations.erase("START_ITEM:%d" % b)
	_send_command(b, "START_ITEM", 0)
	if not await _wait_until(func() -> bool: return _confirmed("START_ITEM", b) and actor.return_channel > 0.0):
		_fail("pre-disconnect channel failed")
		return
	seed_count = GameSession.get_player(b).inventory.count(&"return_seed")
	_send_command(b, "RECONNECT", 0)
	var old_peer := b
	if not await _wait_until(func() -> bool:
		var peer := NetworkManager.peer_id_for_player(b_identity)
		return peer > 0 and peer != old_peer and _confirmed("RECONNECT", peer)
	, 10.0):
		_fail("persistent owner did not reconnect with a fresh peer")
		return
	b = NetworkManager.peer_id_for_player(b_identity)
	if GameSession.get_player(b).inventory.count(&"return_seed") != seed_count:
		_fail("disconnect consumed a return item")
		return
	_send_command(b, "REENTER", 0)
	if not await _wait_until(func() -> bool: return _confirmed("REENTER", b)):
		_fail("reconnected owner did not reenter")
		return
	_set_drop.rpc_id(b, record.id)
	_send_command(b, "ROSTER_DROP", 0)
	if not await _wait_until(func() -> bool: return _confirmed("ROSTER_DROP", b)):
		_fail("late entrant did not receive death-drop roster")
		return
	NetworkManager.authoritative_actor(b).position = record.position
	_send_command(b, "CLAIM_DROP", 0)
	if c > 0:
		_send_command(c, "RACE_WRONG_OWNER", 0)
	if not await _wait_until(func() -> bool: return _confirmed("CLAIM_DROP", b)) or not record.recovered:
		_fail("reconnected owner could not recover exactly once")
		return
	if GameSession.adventure_session_for_peer(b).get_player_adventure(b).unsecured_loot.count(&"rusty_scrap") != 4:
		_fail("death-drop duplicate recovery changed quantity")
		return
	if c > 0:
		_send_command(c, "DROP_GONE", 0)
		if not await _wait_until(func() -> bool: return _confirmed("DROP_GONE", c)):
			_fail("same-world despawn not replicated")
			return
	_confirmations.erase("RETURN:%d" % b)
	_send_command(b, "RETURN", 0)
	if not await _wait_until(func() -> bool: return _confirmed("RETURN", b)):
		_fail("reconnected B did not return independently")
		return
	if c > 0 and (GameSession.get_peer_world_id(c) != SEWER or _server_root.runtime(SEWER).get_instance_id() != runtime_id \
			or GameSession.get_player_id(c) != c_identity):
		_fail("C identity/runtime changed during B lifecycle")
		return
	if c > 0:
		if GameSession.get_player(c).inventory.to_array() != c_inventory \
				or session.get_player_adventure(c).unsecured_loot.to_array() != c_loot \
				or runtime.loot_manager().entity_ids() != loot_ids:
			_fail("B death/claim/exit modified C possessions or world loot")
			return
		for enemy_id in enemy_health:
			var enemy := runtime.enemy_manager().get_enemy(enemy_id)
			if enemy == null or enemy.health.current_health != enemy_health[enemy_id]:
				_fail("B lifecycle changed surviving Sewer enemies")
				return
	if _drop_events != 0 or _current_world_root().get_instance_id() != host_scene or SceneRouter.current_world_id() != SETTLEMENT:
		_fail("Sewer death drops or transition leaked into Host Settlement")
		return
	print("GAMEPLAY AUTHORITY RPC NEGATIVES + CHANNEL + DEATH + RECONNECT PASS")
	_finish_success()

func _protected_state(peer: int) -> Dictionary:
	var session := GameSession.adventure_session_for_peer(peer)
	return {"world": GameSession.get_peer_world_id(peer), "revision": GameSession.get_peer_world(peer).revision,
		"inventory": GameSession.get_player(peer).inventory.to_array(), "storage": GameSession.settlement.to_save_dict(),
		"personal": session.get_player_adventure(peer) if session != null else null,
		"spawn": NetworkManager.spawn_assignment_for_peer(peer), "ready": NetworkManager.is_peer_world_ready(peer),
		"pending": NetworkManager._pending_world_transitions.get(peer)}

@rpc("authority", "call_remote", "reliable")
func _set_drop(id: String) -> void:
	_drop_id = id

@rpc("authority", "call_remote", "reliable")
func _command(command: String, value: int) -> void:
	var peer := NetworkManager.local_peer_id()
	var world := GameSession.get_local_player_world()
	var failures_before := _failures_seen
	var expected_failures := 0
	match command:
		"FAR_ENTRY":
			NetworkManager._request_enter_region.rpc_id(1, &"sewer_gate", &"sewer_region", world.world_id, world.revision)
			expected_failures = 1
		"FORGED_ESCAPES":
			NetworkManager._request_return_to_settlement.rpc_id(1, int(AdventureSession.Result.NORMAL_ESCAPE))
			NetworkManager._request_return_to_settlement.rpc_id(1, int(AdventureSession.Result.RETURN_ITEM_ESCAPE))
			NetworkManager._request_escape_at_point.rpc_id(1, &"sewer_entrance", world.world_id, world.revision)
			NetworkManager._request_escape_at_point.rpc_id(1, &"forged", world.world_id, world.revision)
			NetworkManager._request_escape_at_point.rpc_id(1, &"sewer_entrance", SETTLEMENT, world.revision)
			expected_failures = 5
		"STALE_ENTRY":
			NetworkManager._request_enter_region.rpc_id(1, &"sewer_gate", &"sewer_region", world.world_id, world.revision - 2)
			expected_failures = 1
		"START_ITEM":
			_channel_events.clear()
			_local_actor()._on_quick_item()
			if not await _wait_until(func() -> bool: return _channel_events.has(true)):
				_fail("server return channel start never reached owner")
				return
		"CANCEL_ITEM_MOVE":
			Input.action_press(&"move_right")
			if not await _wait_until(func() -> bool: return _channel_events.has(false)):
				_fail("channel cancel event not received")
				return
			Input.action_release(&"move_right")
		"COMPLETE_ITEM":
			NetworkManager.request_use_return_item()
			NetworkManager.request_use_return_item()
			await _confirm_when_world_ready(command, SETTLEMENT)
			return
		"WRONG_OWNER", "INVALID_DROP":
			if not await _wait_until(func() -> bool: return _visible_drop()):
				_fail("same-world runtime drop not visible")
				return
			NetworkManager._request_recover_death_drop.rpc_id(1, _drop_id, world.world_id, world.revision)
			expected_failures = 1
			if command == "INVALID_DROP":
				NetworkManager._request_recover_death_drop.rpc_id(1, _drop_id, SETTLEMENT, world.revision)
				NetworkManager._request_recover_death_drop.rpc_id(1, "forged-id", world.world_id, world.revision)
				expected_failures = 3
		"RACE_WRONG_OWNER":
			NetworkManager._request_recover_death_drop.rpc_id(1, _drop_id, world.world_id, world.revision)
			expected_failures = 1
		"ROSTER_DROP":
			if not await _wait_until(func() -> bool: return _visible_drop()):
				_fail("late death-drop roster missing")
				return
		"CLAIM_DROP":
			NetworkManager.request_recover_death_drop(_drop_id)
			NetworkManager.request_recover_death_drop(_drop_id)
			if not await _wait_until(func() -> bool: return not _visible_drop()):
				_fail("owner claim did not despawn drop")
				return
		"DROP_GONE":
			if not await _wait_until(func() -> bool: return not _visible_drop()):
				_fail("same-world drop despawn missing")
				return
		"RECONNECT":
			var identity := GameSession.get_local_player_id()
			NetworkManager.leave_game()
			for child in world_layer.get_children():
				world_layer.remove_child(child)
				child.queue_free()
			await get_tree().create_timer(0.25).timeout
			NetworkManager.join_game("127.0.0.1", port)
			if not await _wait_until(func() -> bool: return NetworkManager.is_local_world_ready() and SceneRouter.current_world_id() == SETTLEMENT, 8.0) \
					or GameSession.get_local_player_id() != identity or NetworkManager.local_peer_id() == peer:
				_fail("reconnect identity/attachment failure")
				return
		_:
			await super._command(command, value)
			return
	if expected_failures > 0 and not await _wait_until(func() -> bool: return _failures_seen >= failures_before + expected_failures):
		_fail("negative RPC did not receive expected rejection: %s" % command)
		return
	_confirm.rpc_id(1, command, {"passed": true})

func _visible_drop() -> bool:
	var scene := _current_world_root()
	var manager := scene.get_node_or_null("DeathDropManager") as DeathDropManager if scene != null else null
	return manager != null and manager.target(_drop_id) != null
