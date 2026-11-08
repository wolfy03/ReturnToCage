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
	_test_sprites(t)
	_test_authored_sprites(t)

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
	var berry := ContentRegistry.get_item(&"berry")
	var authored_berry := berry.duplicate() as ItemDefinition
	authored_berry.icon = ItemSlotView.PLACEHOLDER
	ContentRegistry._definitions[berry.id] = authored_berry
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
		var visual := loot.get_node_or_null("Visual") as Sprite2D
		t.assert_true(visual != null and visual.texture == authored_berry.icon, "inventory drop displays its authored icon")
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
	ContentRegistry._definitions[berry.id] = berry
	NetworkManager.leave_game()
	SceneRouter.register_world_layer(null)
	service.queue_free()
	layer.queue_free()
	await t.get_tree().process_frame

func _test_sprites(t: Node) -> void:
	var quest := ItemDefinition.new()
	quest.id = &"test_field_quest_sprite"
	quest.category = ItemDefinition.ItemCategory.QUEST
	quest.hunger_restore = 1.0
	ContentRegistry._definitions[quest.id] = quest
	var consumable := ItemDefinition.new()
	consumable.hunger_restore = 1.0
	t.assert_equal(InventoryWindow.tab_for(consumable), InventoryWindow.Tab.CONSUMABLE, "usable resource stays in the consumable tab")
	var gear := EquipmentDefinition.new()
	gear.category = ItemDefinition.ItemCategory.QUEST
	t.assert_equal(InventoryWindow.tab_for(gear), InventoryWindow.Tab.EQUIPMENT, "equipment takes precedence over quest category")
	var fixtures := {
		&"leaf_vest": ["equipment", InventoryWindow.Tab.EQUIPMENT],
		&"berry": ["usable", InventoryWindow.Tab.CONSUMABLE],
		&"return_seed": ["usable", InventoryWindow.Tab.CONSUMABLE],
		&"water_drop": ["usable", InventoryWindow.Tab.CONSUMABLE],
		&"rusty_scrap": ["etc", InventoryWindow.Tab.OTHER],
		quest.id: ["quest", InventoryWindow.Tab.QUEST],
	}
	var material: Material
	var consumable_texture: Texture2D
	var phases: Array[float] = []
	var scene := preload("res://gameplay/actors/loot/loot_actor.tscn")
	for id: StringName in fixtures:
		var loot := scene.instantiate() as LootActor
		loot.configure(phases.size() + 1, ItemStack.new(id, 1), null)
		loot.position = Vector2(90, 110)
		t.add_child(loot)
		var visual := loot.get_node_or_null("Visual") as Sprite2D
		t.assert_equal(InventoryWindow.tab_for(ContentRegistry.get_item(id)), fixtures[id][1], "inventory and loot category agree for %s" % id)
		t.assert_true(visual != null and visual.texture != null, "field Sprite2D has a texture for %s" % id)
		if visual != null and visual.texture != null:
			var path := "res://assets/item/temp_%s_item_img.png" % fixtures[id][0]
			t.assert_equal(visual.texture.resource_path, path, "loot uses the category texture for %s" % id)
			t.assert_equal(visual.texture.get_size(), Vector2(32, 32), "imported texture fits the 32px display size")
			t.assert_true(visual.centered and visual.position == Vector2(0, -5) and visual.scale == Vector2.ONE \
				and visual.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST, "sprite preserves the unscaled float origin and nearest filtering")
			if material == null:
				material = visual.material
			t.assert_true(material is ShaderMaterial and visual.material == material, "loot shares one ShaderMaterial")
			if fixtures[id][0] == "usable":
				if consumable_texture == null:
					consumable_texture = visual.texture
				t.assert_true(visual.texture == consumable_texture, "consumable sprites share one Texture2D")
			var phase: float = visual.get_instance_shader_parameter(&"phase")
			t.assert_true(phase not in phases, "loot retains its individual float phase")
			phases.append(phase)
		var shape := loot.get_node("CollisionShape2D") as CollisionShape2D
		t.assert_true(loot.position == Vector2(90, 110) and shape.position == Vector2.ZERO \
			and (shape.shape as CircleShape2D).radius == 18.0 and not loot.is_processing() and not loot.is_physics_processing(),
			"sprite initialization preserves the collision and adds no frame callback")
		loot.free()
	ContentRegistry._definitions.erase(quest.id)

func _test_authored_sprites(t: Node) -> void:
	var quest := ItemDefinition.new()
	quest.id = &"test_authored_quest_icon"
	quest.category = ItemDefinition.ItemCategory.QUEST
	var definitions: Array[ItemDefinition] = [
		ContentRegistry.get_item(&"leaf_vest"), ContentRegistry.get_item(&"berry"),
		ContentRegistry.get_item(&"rusty_scrap"), quest,
	]
	var sizes := [Vector2i(80, 40), Vector2i(12, 18), Vector2i(16, 64), Vector2i(80, 40)]
	var displayed := [Vector2(32, 16), Vector2(12, 18), Vector2(8, 32), Vector2(32, 16)]
	var scene := preload("res://gameplay/actors/loot/loot_actor.tscn")
	var shared_material: ShaderMaterial
	var shared_icon: Texture2D
	for index in definitions.size():
		var original := definitions[index]
		var fixture := original.duplicate() as ItemDefinition
		if index == definitions.size() - 1:
			fixture.icon = shared_icon
		else:
			var image := Image.create_empty(sizes[index].x, sizes[index].y, false, Image.FORMAT_RGBA8)
			image.fill_rect(Rect2i(Vector2i.ONE, sizes[index] - Vector2i(2, 2)), Color.ORANGE_RED)
			fixture.icon = ImageTexture.create_from_image(image)
			if index == 0:
				shared_icon = fixture.icon
		ContentRegistry._definitions[fixture.id] = fixture
		var loot := scene.instantiate() as LootActor
		loot.configure(20 + index, ItemStack.new(fixture.id, 1), null)
		loot.position = Vector2(90, 110)
		t.add_child(loot)
		var visual := loot.get_node_or_null("Visual") as Sprite2D
		t.assert_true(visual != null and visual.texture == fixture.icon, "authored icon wins for %s" % fixture.id)
		if visual != null and visual.texture != null:
			t.assert_true((visual.texture.get_size() * visual.scale).is_equal_approx(displayed[index]),
				"authored icon fits within 32px without changing its aspect ratio or enlarging it")
			t.assert_equal(fixture.icon.get_size(), Vector2(sizes[index]), "display size preserves the shared texture dimensions")
			if shared_material == null:
				shared_material = visual.material as ShaderMaterial
			t.assert_true(shared_material != null and visual.material == shared_material, "authored icons share one float material")
			var compensation: Variant = visual.get_instance_shader_parameter(&"inverse_display_scale")
			t.assert_true(compensation != null and is_equal_approx(float(compensation) * visual.scale.y, 1.0),
				"float amplitude is independent of the sprite display scale")
			t.assert_true(visual.centered and visual.position == Vector2(0, -5) and loot.position == Vector2(90, 110) \
				and (loot.get_node("CollisionShape2D") as CollisionShape2D).position == Vector2.ZERO,
				"authored icons preserve the visual origin and collision coordinates")
		loot.free()
		if original == quest:
			ContentRegistry._definitions.erase(quest.id)
		else:
			ContentRegistry._definitions[original.id] = original

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
