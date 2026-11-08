extends "res://tests/integration/multiplayer_world_runtime_probe.gd"

var _drop_id: String = ""
var _failures_seen: int = 0
var _channel_events: Array[bool] = []
var _drop_events: int = 0
var _item_service: PlayerItemReplicationService
var _settlement_roster_id: int
var _sewer_roster_id: int

func _ready() -> void:
	var gear := ContentRegistry.get_item(&"leaf_vest").duplicate() as ItemDefinition
	gear.icon = ItemSlotView.PLACEHOLDER
	ContentRegistry._definitions[gear.id] = gear
	_item_service = PlayerItemReplicationService.new()
	_item_service.name = "PlayerItemReplicationService"
	add_child(_item_service)
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
	if not await _test_settlement_drops(b, c):
		_fail("Settlement field drops failed Host/Client replication or competing pickup")
		return
	for peer in _remote_peers:
		_send_command(peer, "ENTER", 0)
		if not await _wait_until(func() -> bool: return _confirmed("ENTER", peer)):
			_fail("valid near entry failed")
			return
	_send_command(b, "INVENTORY_DROP_ISOLATED", _settlement_roster_id)
	if not await _wait_until(func() -> bool: return _confirmed("INVENTORY_DROP_ISOLATED", b)) \
			or _server_root.runtime(SETTLEMENT).loot_manager().get_loot(_settlement_roster_id) == null:
		_fail("Sewer client could see or claim a Settlement drop")
		return
	var runtime := _server_root.runtime(SEWER)
	var runtime_id := runtime.get_instance_id()
	for enemy_id in runtime.enemy_manager()._enemies:
		runtime.enemy_manager().get_enemy(enemy_id).set_physics_process(false)
	var actor := NetworkManager.authoritative_actor(b)
	actor.position = Vector2(700, 510)
	actor.survival.set_process(false)
	if not await _test_inventory_drop(b, c, runtime.loot_manager()):
		_fail("inventory drop failed real RPC validation or world-scoped replication")
		return
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
	if not await _check_settlement_roster(b):
		_fail("returning player did not receive the surviving Settlement drop")
		return
	if c > 0 and (_server_root.runtime(SEWER).get_instance_id() != runtime_id or GameSession.get_peer_world_id(c) != SEWER):
		_fail("individual normal escape destroyed C runtime")
		return
	if c == 0 and not await _wait_until(func() -> bool: return _server_root.runtime(SEWER) == null):
		_fail("empty Sewer runtime was not retired")
		return
	_send_command(b, "REENTER", 0)
	if not await _wait_until(func() -> bool: return _confirmed("REENTER", b)):
		_fail("return-channel reentry failed")
		return
	runtime = _server_root.runtime(SEWER)
	if c > 0:
		_send_command(b, "INVENTORY_DROP_VISIBLE", _sewer_roster_id)
		if not await _wait_until(func() -> bool: return _confirmed("INVENTORY_DROP_VISIBLE", b)):
			_fail("Sewer re-entry did not restore the occupied world's drop roster")
			return
	else:
		var retired_id := _sewer_roster_id
		if runtime.get_instance_id() == runtime_id or runtime.loot_manager().get_loot(retired_id) != null:
			_fail("retired Sewer runtime retained a transient drop")
			return
		if not await _test_inventory_drop(b, 0, runtime.loot_manager()) or _sewer_roster_id == retired_id:
			_fail("recreated Sewer runtime reused the retired loot ID")
			return
	var unsecured := GameSession.adventure_session_for_peer(b).get_player_adventure(b).unsecured_loot
	var unsecured_before := unsecured.to_slot_dict()
	var loot_position := runtime.loot_manager().get_loot(_sewer_roster_id).global_position
	NetworkManager.authoritative_actor(b).global_position = loot_position + Vector2.UP * 12
	var claim_command := "CLAIM_SETTLED_LOOT" if c > 0 else "CLAIM_INVENTORY_LOOT"
	_confirmations.erase("%s:%d" % [claim_command, b])
	_send_command(b, claim_command, _sewer_roster_id)
	if not await _wait_until(func() -> bool: return _confirmed(claim_command, b)) \
			or unsecured.to_slot_dict() != unsecured_before or runtime.loot_manager().get_loot(_sewer_roster_id) != null:
		_fail("Sewer pickup failed to restore carried items to the owner-private main bag")
		return
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
	if not await _check_settlement_roster(b):
		_fail("reconnecting player did not receive the surviving Settlement drop")
		return
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
	if not await _check_host_loot_reentry(b):
		_fail("Host presentation did not receive the surviving Settlement roster after travel")
		return
	print("SETTLEMENT + ADVENTURE FIELD DROPS, PICKUP AND LOOT ROSTER PASS")
	print("GAMEPLAY AUTHORITY RPC NEGATIVES + CHANNEL + DEATH + RECONNECT PASS")
	_finish_success()

func _test_settlement_drops(client: int, other_client: int) -> bool:
	var manager := _server_root.runtime(SETTLEMENT).loot_manager()
	if manager == null:
		return false
	var gear := ItemStack.new(&"leaf_vest", 1)
	gear.instance_id = "enet-settlement-drop-gear"
	gear.durability = 37
	var host_bag := GameSession.get_player(1).inventory
	var client_bag := GameSession.get_player(client).inventory
	var slot := _seed_drop_slot(host_bag, gear)
	if slot < 0:
		return false
	var throw_origin := NetworkManager.authoritative_actor(1).item_throw_origin()
	_item_service.request_drop_slot(PlayerItemCommandService.SlotInventory.MAIN, slot)
	if host_bag.get_slot(slot) != null or manager.entity_ids().size() != 1:
		return false
	var id := manager.entity_ids()[0]
	var dropped := manager.get_loot(id)
	var host_gear := _loot_manager().get_loot(id)
	if dropped.stack.to_dict() != gear.to_dict() or dropped.has_node("Visual") \
			or host_gear == null or not host_gear._throw_origin.is_equal_approx(throw_origin) \
			or not _uses_loot_texture(host_gear, ItemSlotView.PLACEHOLDER.resource_path.get_file()):
		return false
	var landing_x := dropped.global_position.x
	var effect_path := NodePath("LootPickup_%d" % id)
	NetworkManager.authoritative_actor(client).global_position = dropped.global_position + Vector2(50, -12)
	if not await _wait_until(func() -> bool: return _actor(client).global_position.x > landing_x + 35.0):
		return false
	_send_command(client, "CLAIM_INVENTORY_LOOT", id)
	if not await _wait_until(func() -> bool:
		var effect := _current_world_root().get_node_or_null(effect_path) as Sprite2D
		return effect != null and effect.global_position.x > landing_x + 18.0
	) or manager.get_parent().has_node(effect_path) or manager.get_loot(id) != null:
		return false
	if not await _wait_until(func() -> bool: return _confirmed("CLAIM_INVENTORY_LOOT", client)) \
			or manager.get_loot(id) != null or not gear.to_dict() in client_bag.to_array():
		return false

	slot = _seed_drop_slot(client_bag, ItemStack.new(&"berry", 3))
	if slot < 0:
		return false
	_send_command(client, "INVENTORY_DROP", slot)
	if not await _wait_until(func() -> bool: return _confirmed("INVENTORY_DROP", client)):
		return false
	id = int(_confirmation("INVENTORY_DROP", client).get("id", 0))
	dropped = manager.get_loot(id)
	var host_visible := _loot_manager().get_loot(id)
	if dropped == null or host_visible == null or not _uses_loot_texture(host_visible, "temp_usable_item_img.png") \
			or not host_visible.global_position.is_equal_approx(dropped.global_position) or client_bag.get_slot(slot) != null:
		return false
	var contender := other_client if other_client > 0 else 1
	var contender_bag := GameSession.get_player(contender).inventory
	var combined := client_bag.count(&"berry") + contender_bag.count(&"berry")
	NetworkManager.authoritative_actor(contender).global_position = dropped.global_position + Vector2(25, -12)
	_send_command(client, "PICKUP", id)
	if contender == 1:
		NetworkManager.request_loot_pickup(id)
	else:
		_send_command(contender, "PICKUP", id)
	if not await _wait_until(func() -> bool:
		return _confirmed("PICKUP", client) and (contender == 1 or _confirmed("PICKUP", contender)) and manager.get_loot(id) == null
	) or client_bag.count(&"berry") + contender_bag.count(&"berry") != combined + 3 or _loot_manager().get_loot(id) != null:
		return false
	slot = _seed_drop_slot(host_bag, ItemStack.new(&"water_drop", 1))
	if slot < 0:
		return false
	_item_service.request_drop_slot(PlayerItemCommandService.SlotInventory.MAIN, slot)
	if manager.entity_ids().size() != 1:
		return false
	_settlement_roster_id = manager.entity_ids()[0]
	return _settlement_roster_id != id

func _seed_drop_slot(inventory: InventoryModel, stack: ItemStack) -> int:
	var slots := inventory.slots()
	var slot := slots.find(null)
	if slot < 0:
		return -1
	slots[slot] = stack
	return slot if inventory.initialize_slots(slots).success else -1

func _check_settlement_roster(peer: int) -> bool:
	_confirmations.erase("SETTLEMENT_LOOT_ROSTER:%d" % peer)
	_send_command(peer, "SETTLEMENT_LOOT_ROSTER", _settlement_roster_id)
	return await _wait_until(func() -> bool: return _confirmed("SETTLEMENT_LOOT_ROSTER", peer))

func _check_host_loot_reentry(settlement_peer: int) -> bool:
	if GameSession.get_peer_world_id(settlement_peer) != SETTLEMENT:
		return false
	var actor := NetworkManager.authoritative_actor(1)
	actor.position = Vector2(865, 510)
	if not NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region").success:
		return false
	if not await _wait_until(func() -> bool: return SceneRouter.current_world_id() == SEWER and NetworkManager.is_local_world_ready()):
		return false
	actor = NetworkManager.authoritative_actor(1)
	actor.position = Vector2(70, 510)
	if not NetworkManager._return_player_to_settlement(1, AdventureSession.Result.NORMAL_ESCAPE, &"sewer_entrance").success:
		return false
	return await _wait_until(func() -> bool:
		return SceneRouter.current_world_id() == SETTLEMENT and _loot_manager().get_loot(_settlement_roster_id) != null
	)

func _test_inventory_drop(owner: int, observer: int, manager: LootSpawnManager) -> bool:
	var inventory := GameSession.get_player(owner).inventory
	var slots := inventory.slots()
	var slot := slots.find(null)
	if slot < 0:
		return false
	slots[slot] = ItemStack.new(&"berry", 3)
	if not inventory.initialize_slots(slots).success:
		return false
	var before := manager.entity_ids()
	_confirmations.erase("INVENTORY_DROP:%d" % owner)
	_send_command(owner, "INVENTORY_DROP", slot)
	if not await _wait_until(func() -> bool: return _confirmed("INVENTORY_DROP", owner)):
		return false
	var id := int(_confirmation("INVENTORY_DROP", owner).get("id", 0))
	var loot := manager.get_loot(id)
	if inventory.get_slot(slot) != null or manager.entity_ids().size() != before.size() + 1 \
			or id in before or id == _settlement_roster_id or loot == null \
			or loot.stack.to_dict() != slots[slot].to_dict() or _sewer_loot_events != 0:
		return false
	if observer > 0:
		_send_command(observer, "INVENTORY_DROP_VISIBLE", id)
		if not await _wait_until(func() -> bool: return _confirmed("INVENTORY_DROP_VISIBLE", observer)):
			return false
	_sewer_roster_id = id
	return true

func _request_inventory_drop(slot: int) -> int:
	var player := GameSession.get_local_player()
	if not await _wait_until(func() -> bool:
		var stack := player.inventory.get_slot(slot)
		return stack != null and stack.item_id == &"berry" and stack.quantity == 3
	):
		return 0
	var revision := player.item_state_revision
	var manager := _loot_manager()
	var before := manager.entity_ids()
	var action := PlayerItemCommandService.SlotAction.DROP
	var kind := PlayerItemCommandService.SlotInventory.MAIN
	var wrong_world := _item_service.make_slot_intent(action, kind, slot, -1, 3)
	wrong_world.world_id = String(SEWER if SceneRouter.current_world_id() == SETTLEMENT else SETTLEMENT)
	var valid := _item_service.make_slot_intent(action, kind, slot, -1, 3)
	var replies: Array[Array] = []
	var record := func(sequence: int, success: bool, message: String) -> void:
		replies.append([sequence, success, message])
	_item_service.slot_result.connect(record)
	_item_service._request_slot_command.rpc_id(1, wrong_world)
	_item_service._request_slot_command.rpc_id(1, valid)
	_item_service._request_slot_command.rpc_id(1, valid)
	var complete := await _wait_until(func() -> bool:
		return replies.size() == 3 and player.item_state_revision == revision + 1 and manager.entity_ids().size() == before.size() + 1
	)
	_item_service.slot_result.disconnect(record)
	if not complete or player.inventory.get_slot(slot) != null \
			or replies[0] != [wrong_world.sequence, false, "Stale inventory command world"] \
			or replies[1].slice(0, 2) != [valid.sequence, true] \
			or replies[2] != [valid.sequence, false, "Stale slot command sequence"]:
		return 0
	for id in manager.entity_ids():
		if id not in before:
			return id if _uses_loot_texture(manager.get_loot(id), "temp_usable_item_img.png") else 0
	return 0

func _uses_loot_texture(loot: LootActor, file_name: String) -> bool:
	var visual := loot.get_node_or_null("Visual") as Sprite2D
	return visual != null and visual.texture != null and visual.texture.resource_path.get_file() == file_name

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
		"INVENTORY_DROP":
			var id := await _request_inventory_drop(value)
			if id <= 0:
				_fail("owner did not reconcile inventory drop and rejected RPCs")
				return
			_confirm.rpc_id(1, command, {"id": id})
			return
		"INVENTORY_DROP_ISOLATED":
			if _loot_manager().get_loot(value) != null:
				_fail("another world's loot appeared in the local scene")
				return
			NetworkManager.request_loot_pickup(value)
		"CLAIM_INVENTORY_LOOT", "CLAIM_SETTLED_LOOT":
			if not await _wait_until(func() -> bool: return _loot_manager().get_loot(value) != null):
				_fail("Host drop did not reach client")
				return
			var loot := _loot_manager().get_loot(value)
			var stack := loot.stack
			if loot._throw_origin.is_finite() != (command == "CLAIM_INVENTORY_LOOT"):
				_fail("loot throw origin does not match live spawn or roster")
				return
			var file_name := ItemSlotView.PLACEHOLDER.resource_path.get_file() if stack.item_id == &"leaf_vest" else "temp_usable_item_img.png"
			if not _uses_loot_texture(loot, file_name):
				_fail("client displayed the wrong field loot category")
				return
			var inventory := GameSession.get_local_player().inventory
			var expected_count := inventory.count(stack.item_id) + stack.quantity
			NetworkManager.request_loot_pickup(value)
			if not await _wait_until(func() -> bool:
				return _loot_manager().get_loot(value) == null and inventory.count(stack.item_id) == expected_count \
					and (stack.instance_id.is_empty() or stack.to_dict() in inventory.to_array())
			):
				_fail("client did not receive the exact Host equipment or the despawn")
				return
		"INVENTORY_DROP_VISIBLE", "SETTLEMENT_LOOT_ROSTER":
			if not await _wait_until(func() -> bool: return _loot_manager().get_loot(value) != null):
				_fail("same-world peer did not receive inventory drop")
				return
			if command == "SETTLEMENT_LOOT_ROSTER" and _loot_manager().get_loot(value)._throw_origin.is_finite():
				_fail("roster replayed an inventory throw on entry")
				return
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
