extends RefCounted

const PLAYER_ID := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PEER := 1
const OTHER_PEER := 42

var service: PlayerItemReplicationService
var player: PlayerState
var manager: LootSpawnManager
var responses: Array[CommandResult] = []

func run(t: Node) -> void:
	NetworkManager.leave_game()
	t.assert_equal(NetworkManager.host_game(31000 + randi_range(0, 4000), 2), OK, "drop fixture hosts")
	t.assert_true(GameSession.start_new_game(), "drop fixture starts")
	var root := ServerWorldRoot.new()
	t.add_child(root)
	service = PlayerItemReplicationService.new()
	t.add_child(service)
	service.slot_result.connect(func(_sequence: int, success: bool, message: String) -> void:
		responses.append(CommandResult.make(success, message))
	)
	NetworkManager.players[OTHER_PEER] = NetworkPlayerInfo.new(OTHER_PEER, PLAYER_ID, "B", true)
	NetworkManager._set_identity(OTHER_PEER, PLAYER_ID)
	GameSession.attach_player(OTHER_PEER, PLAYER_ID)
	t.assert_true(GameSession.begin_player_adventure(PEER, &"sewer_gate", &"sewer_region").success, "drop fixture enters Sewer")
	root.reconcile()
	await t.get_tree().physics_frame
	await t.get_tree().process_frame
	NetworkManager.mark_peer_world_ready(PEER)
	var actor := NetworkManager.authoritative_actor(PEER)
	manager = root.runtime(GameSession.get_peer_world_id(PEER)).loot_manager()
	player = GameSession.get_player(PEER)
	var equipment := ItemStack.new(&"leaf_vest", 1)
	equipment.instance_id = "drop-fixture-instance"
	equipment.durability = 37
	var bag := player.inventory
	t.assert_true(bag.initialize_slots([ItemStack.new(&"berry", 4), null, equipment, ItemStack.new(&"berry", 2), ItemStack.new(&"rusty_scrap", 1)]).success, "drop fixture inventory")
	player.protected_inventory.initialize([ItemStack.new(&"berry", 1)])
	var main := PlayerItemCommandService.SlotInventory.MAIN
	var protected := PlayerItemCommandService.SlotInventory.PROTECTED
	_reject(t, _command(protected, 0, 1), "protected bag")
	_reject(t, _command(main, 1, 1), "empty source")
	_reject(t, _command(main, 0, 0), "zero amount")
	_reject(t, _command(main, 0, -1), "negative amount on the wire")
	_reject(t, _command(main, 0, 5), "amount exceeds source stack")
	var definition := ContentRegistry.get_item(&"berry")
	var restricted := definition.duplicate() as ItemDefinition
	ContentRegistry._definitions[definition.id] = restricted
	restricted.discardable = false
	_reject(t, _command(main, 0, 1), "non-discardable item")
	restricted.discardable = true
	restricted.quest_protected = true
	_reject(t, _command(main, 0, 1), "quest-protected item")
	ContentRegistry._definitions[definition.id] = definition
	var intent := _command(main, 0, 1)
	intent.revision -= 1
	_reject(t, intent, "stale item revision")
	intent = _command(main, 2, 1)
	intent.source.durability -= 1
	_reject(t, intent, "stale source fingerprint")
	intent = _command(main, 0, 1)
	intent.world_id = "settlement"
	_reject(t, intent, "wrong world")
	intent = _command(main, 0, 1)
	intent.world_revision += 1
	_reject(t, intent, "stale world revision")
	intent = _command(main, 0, 1)
	intent.session_id = "different-session"
	_reject(t, intent, "wrong session")
	intent = _command(main, 0, 1)
	intent.owner_player_id = String(PLAYER_ID)
	_reject(t, intent, "forged owner")
	var registry := manager._registry
	var original_next: int = registry._next_entity_ids.get(manager.world_id, 1)
	registry._next_entity_ids[manager.world_id] = NetworkEntityRegistry.MAX_ENTITY_ID + 1
	_reject(t, _command(main, 0, 1), "failed entity registration")
	registry._next_entity_ids[manager.world_id] = original_next
	var guard := bag.mutation_guard
	bag.mutation_guard = func() -> bool: return false
	_reject(t, _command(main, 0, 1), "failed slot removal rolls back staged entity")
	bag.mutation_guard = guard
	var other_inventory := GameSession.get_player(OTHER_PEER).inventory.to_slot_dict()
	var before_ids := manager.entity_ids()
	var before_revision := player.item_state_revision
	var full_drop := _command(main, 0, 4)
	var full_result := _execute(full_drop)
	t.assert_true(full_result.success, "full stack drops: %s" % full_result.message)
	t.assert_true(bag.get_slot(0) == null and bag.get_slot(3).quantity == 2, "only the exact source slot is removed")
	t.assert_equal(player.item_state_revision, before_revision + 1, "successful drop publishes exactly one item revision")
	var spawned := _new_loot(before_ids)
	t.assert_true(spawned != null and spawned.stack.quantity == 4 and spawned.stack.item_id == &"berry", "full source stack becomes one field item")
	_reject(t, full_drop, "duplicate drop sequence", "Stale slot command sequence")
	before_ids = manager.entity_ids()
	t.assert_true(_execute(_command(main, 3, 1)).success, "partial drop succeeds")
	var partial := _new_loot(before_ids)
	t.assert_true(bag.get_slot(3).quantity == 1 and partial != null and partial.stack.quantity == 1, "partial drop conserves quantity")
	before_ids = manager.entity_ids()
	t.assert_true(service.request_drop_slot(main, 2) > 0 and responses.pop_back().success, "public drop request defaults to the complete stack")
	var gear := _new_loot(before_ids)
	t.assert_true(gear != null and gear.stack.to_dict() == equipment.to_dict(), "field item preserves equipment instance ID and durability")
	if gear != null:
		t.assert_true(gear.global_position.is_equal_approx(actor.item_drop_point.global_position), "field item spawns at the authoritative actor's feet")
		t.assert_true(manager.server_try_pickup(PEER, gear.network_entity_id).success, "dropped gear uses existing pickup path")
		var loot := GameSession.adventure_session_for_peer(PEER).get_player_adventure(PEER).unsecured_loot
		t.assert_equal(loot.to_array(), [], "carried drops are not converted into unsecured Adventure loot")
		t.assert_true(equipment.to_dict() in bag.to_array(), "pickup restores the exact dropped instance to the main bag")
	t.assert_true(GameSession.start_quest(&"sewer_supplies"), "collection quest starts")
	var quest: QuestState = GameSession.progression.shared_quest_states[&"sewer_supplies"]
	before_ids = manager.entity_ids()
	t.assert_true(_execute(_command(main, 4, 1)).success, "quest material can be dropped")
	var scrap := _new_loot(before_ids)
	t.assert_true(scrap != null and manager.server_try_pickup(PEER, scrap.network_entity_id).success, "dropped quest material remains collectible")
	t.assert_equal(quest.progress[0], 0, "re-picking a carried drop cannot farm collection credit")
	var native_loot := manager.spawn_loot(ItemStack.new(&"rusty_scrap", 1), actor.item_drop_point.global_position)
	t.assert_true(manager.server_try_pickup(PEER, native_loot).success, "regular field loot remains collectible")
	t.assert_equal(quest.progress[0], 1, "regular field loot still grants collection credit")
	t.assert_equal(GameSession.adventure_session_for_peer(PEER).get_player_adventure(PEER).unsecured_loot.count(&"rusty_scrap"), 1,
		"regular Adventure loot remains unsecured")
	t.assert_equal(GameSession.get_player(OTHER_PEER).inventory.to_slot_dict(), other_inventory, "drop preserves the other player inventory")
	manager.queue_free()
	_reject(t, _command(main, 3, 1), "retiring loot runtime")
	service.queue_free()
	root.get_parent().remove_child(root)
	root.queue_free()
	await t.get_tree().process_frame
	NetworkManager.leave_game()
	await _test_offline(t)

func _test_offline(t: Node) -> void:
	var layer := Node.new()
	t.add_child(layer)
	SceneRouter.register_world_layer(layer)
	service = PlayerItemReplicationService.new()
	t.add_child(service)
	service.slot_result.connect(func(_sequence: int, success: bool, message: String) -> void:
		responses.append(CommandResult.make(success, message))
	)
	t.assert_true(GameSession.start_new_game() and SceneRouter.go_to_settlement(), "offline drop fixture starts in Settlement")
	var bag := GameSession.get_local_player().inventory
	bag.initialize([ItemStack.new(&"berry", 2)])
	var main := PlayerItemCommandService.SlotInventory.MAIN
	var settlement_loot := layer.get_child(0).get_node_or_null("LootSpawnManager") as LootSpawnManager
	t.assert_true(service.request_drop_slot(main, 0) > 0 and responses.pop_back().success, "Settlement accepts a drop")
	t.assert_true(settlement_loot != null, "Settlement owns a loot manager")
	if settlement_loot != null and not settlement_loot.entity_ids().is_empty():
		var id := settlement_loot.entity_ids()[0]
		var loot := settlement_loot.get_loot(id)
		t.assert_equal(loot.stack.quantity, 2, "Settlement field holds the entire dropped stack")
		var almost_full := ContentRegistry.get_item(&"berry").max_stack - 1
		bag.initialize([ItemStack.new(&"berry", almost_full)], 1)
		var full := bag.to_slot_dict()
		var revision := GameSession.get_local_player().item_state_revision
		t.assert_true(not settlement_loot.server_try_pickup(1, id).success, "full Settlement bag rejects pickup")
		t.assert_true(settlement_loot.get_loot(id) == loot and loot.claim_state == LootActor.ClaimState.AVAILABLE,
			"failed pickup keeps the entity available")
		t.assert_equal(bag.to_slot_dict(), full, "failed pickup rolls back even the portion that could merge")
		t.assert_equal(GameSession.get_local_player().item_state_revision, revision, "failed pickup preserves item revision")
		bag.clear()
		var nested: Array[bool] = []
		var retry := func() -> void: nested.append(settlement_loot.server_try_pickup(1, id).success)
		bag.changed.connect(retry, CONNECT_ONE_SHOT)
		loot.activated.emit(NetworkManager.authoritative_actor(1))
		t.assert_equal(bag.count(&"berry"), 2, "Settlement interaction restores the full stack to MAIN")
		t.assert_equal(nested, [false], "reentrant pickup cannot claim the same stack")
		t.assert_true(settlement_loot.get_loot(id) == null, "successful pickup removes Settlement loot")
	t.assert_true(NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region").success, "offline fixture enters Sewer through the gameplay path")
	t.assert_equal(SceneRouter.current_world_id(), &"adventure:sewer_region", "offline Sewer scene loads")
	t.assert_true(service.request_drop_slot(main, 0) > 0 and responses.pop_back().success, "offline authority can drop an entire stack")
	t.assert_true(bag.get_slot(0) == null, "offline drop clears the source slot")
	var sewer_loot := layer.get_child(0).get_node("LootSpawnManager") as LootSpawnManager
	if not sewer_loot.entity_ids().is_empty():
		var id := sewer_loot.entity_ids()[0]
		t.assert_true(sewer_loot.server_try_pickup(1, id).success and bag.count(&"berry") == 2,
			"offline Adventure pickup restores the carried stack to MAIN")
	NetworkManager.leave_game()
	SceneRouter.register_world_layer(null)
	service.queue_free()
	layer.queue_free()
	await t.get_tree().process_frame

func _command(kind: int, source: int, amount: int) -> Dictionary:
	return service.make_slot_intent(PlayerItemCommandService.SlotAction.DROP, kind, source, -1, amount)

func _execute(command: Dictionary) -> CommandResult:
	service._execute_slot(PEER, command, true)
	return responses.pop_back()

func _reject(t: Node, command: Dictionary, reason: String, message: String = "") -> void:
	var before := _state()
	var result := _execute(command)
	t.assert_true(not result.success, "drop rejects %s" % reason)
	if not message.is_empty():
		t.assert_equal(result.message, message, reason)
	t.assert_equal(_state(), before, "drop rejection preserves inventory, revision and field for %s" % reason)

func _state() -> Array:
	return [player.inventory.to_slot_dict(), player.protected_inventory.to_slot_dict(),
		player.item_state_revision, manager.entity_ids(), manager._registry.entity_count()]

func _new_loot(previous: Array[int]) -> LootActor:
	for id in manager.entity_ids():
		if id not in previous:
			return manager.get_loot(id)
	return null
