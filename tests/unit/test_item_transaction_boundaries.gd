extends RefCounted

func run(t: Node) -> void:
	_test_transfer_identity(t)
	_test_fresh_gear(t)
	_test_periodic_gear(t)
	_test_death_gear(t)
	_test_sparse_craft(t)
	_test_offline_secure_failure(t)
	_test_invalid_save_equipment(t)

func _stack(id: StringName, identity: String, durability: int = -1) -> ItemStack:
	var stack := ItemStack.new(id, 1)
	stack.instance_id = identity
	stack.durability = durability
	return stack

func _test_transfer_identity(t: Node) -> void:
	var resolver := Callable(ContentRegistry, "get_item")
	var player := PlayerState.new(resolver)
	player.inventory.capacity = 4
	player.protected_inventory.capacity = 2
	var settlement := SettlementState.new(resolver)
	settlement.storage.capacity = 6
	var service := PlayerItemCommandService.new(ContentRegistry)
	var withdraw := PlayerItemCommandService.TransferDirection.WITHDRAW
	var legacy := _stack(&"leaf_vest", "", 12)
	var other_legacy := _stack(&"leaf_vest", "", 24)
	var known := _stack(&"leaf_vest", "known-vest", 39)
	settlement.storage.initialize_slots([legacy, null, other_legacy, null, known])
	t.assert_true(service.try_transfer(player, settlement, withdraw, &"leaf_vest", "", 1).success, "legacy gear remains withdrawable")
	var kept := settlement.storage.get_slot(4)
	t.assert_true(settlement.storage.get_slot(0) == null and kept != null and kept.to_dict() == known.to_dict(), "legacy withdrawal consumes its selected cell and never an identified copy")
	t.assert_equal(settlement.storage.get_slot(2).to_dict(), other_legacy.to_dict(), "legacy withdrawal leaves the other durability and slot untouched")
	var received := player.inventory.get_slot(0)
	t.assert_true(received != null and not received.instance_id.is_empty() and received.durability == 12, "legacy withdrawal assigns a new identity to the actual selected piece")

	var known_food := _stack(&"berry", "known-berry")
	settlement.storage.initialize_slots([ItemStack.new(&"berry", 1), null, known_food])
	t.assert_true(service.try_transfer(player, settlement, withdraw, &"berry", "", 1).success, "type-based transfer can spend an anonymous stack")
	kept = settlement.storage.get_slot(2)
	t.assert_true(kept != null and kept.to_dict() == known_food.to_dict(), "type-based transfer never strips another stack's identity")
	var owned := _stack(&"leaf_vest", "protected-duplicate", 25)
	settlement.storage.initialize([owned])
	player.protected_inventory.add_stack(owned)
	var before := [settlement.storage.to_slot_dict(), player.inventory.to_slot_dict(), player.protected_inventory.to_slot_dict(), player.item_state_revision, settlement.revision]
	t.assert_true(not service.try_transfer(player, settlement, withdraw, owned.item_id, owned.instance_id, 1).success, "transfer rejects a duplicate in protected inventory")
	t.assert_equal([settlement.storage.to_slot_dict(), player.inventory.to_slot_dict(), player.protected_inventory.to_slot_dict(), player.item_state_revision, settlement.revision], before, "duplicate transfer preserves both layouts and revisions")

func _test_fresh_gear(t: Node) -> void:
	GameSession.start_new_game()
	var first := GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	var authored := GameSession.get_start_definition().equipment_items[0]
	var original_id := authored.instance_id
	authored.instance_id = "authored-starter-template"
	var other := GameSession.attach_player(42, &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
	var third := GameSession.attach_player(43, &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
	t.assert_equal(authored.instance_id, "authored-starter-template", "starter template is never mutated by issuing a grant")
	authored.instance_id = original_id
	var second := other.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	t.assert_true(not first.instance_id.is_empty() and not second.instance_id.is_empty() and first.instance_id != second.instance_id, "each fresh canonical starter sword has a different nonempty identity")
	var last := third.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	t.assert_true(second.instance_id != "authored-starter-template" and second.instance_id != last.instance_id, "two players starting from one explicit ID template receive different IDs")
	var detached := GameSession.prepare_persistent_restore(GameSession.export_persistent_state())
	t.assert_true(detached.fatal_error.is_empty(), "starter identities validate across both players")
	GameSession.start_new_game()
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	var loot := GameSession.adventure.active_session.get_player_adventure(1).unsecured_loot
	loot.resize_capacity(2)
	var award := GameSession.collect_adventure_loot(&"leaf_hat", 3)
	t.assert_true(award.changed == 2 and award.remainder == 1, "gear gather preserves partial fit semantics")
	t.assert_true(not loot.get_slot(0).instance_id.is_empty() and not loot.get_slot(1).instance_id.is_empty() \
		and loot.get_slot(0).instance_id != loot.get_slot(1).instance_id, "each awarded gear piece has a distinct identity before extraction")
	GameSession.start_new_game()

func _test_periodic_gear(t: Node) -> void:
	var coat := EquipmentDefinition.new()
	coat.id = &"timer_coat"
	coat.equipment_slot = EquipmentDefinition.EquipmentSlot.BODY
	var pulse := EffectDefinition.new()
	pulse.id = &"gear_heal"
	pulse.kind = EffectDefinition.EffectKind.PERIODIC_HEAL
	pulse.tick_interval_seconds = 1.0
	pulse.magnitude = 4.0
	coat.equip_effects = [pulse]
	var buff := EffectDefinition.new()
	buff.id = pulse.id # Same authored effect ID must still have independent lifetime.
	buff.target_stat = &"defense"
	buff.magnitude = 2.0
	buff.duration_seconds = 20.0
	buff.max_stacks = 2
	buff.stack_policy = EffectDefinition.StackPolicy.STACK
	var resolver := func(id: StringName) -> ItemDefinition:
		return coat if id == coat.id else ContentRegistry.get_item(id)
	var player := PlayerState.new(resolver)
	player.set_health(40.0)
	player.equipment.equip(_stack(coat.id, "pulse-coat"))
	# An independently sourced temporary buff can share a source label with gear.
	player.effects.apply_effect(buff, ItemDefinition.FoodSlot.NONE, &"equipment:1")
	player.effects.apply_effect(buff, ItemDefinition.FoodSlot.NONE, &"equipment:1")
	player.effects.tick(0.75)
	var ring := _stack(&"seed_ring", "timer-ring", 35)
	var before := player.to_save_dict(true)
	var projected := player.preview_equipment_stats(ring)
	t.assert_equal(player.to_save_dict(true), before, "detached preview preserves stacked buff and health")
	t.assert_equal(projected.value(&"defense"), 4.0, "unrelated loadout projection retains both temporary stacks")
	player.equipment.equip(ring)
	player.effects.tick(0.25)
	t.assert_equal(player.health, 44.0, "equipping an unrelated slot preserves the running pulse timer")
	player.equipment.unequip(EquipmentDefinition.EquipmentSlot.BODY)
	t.assert_equal(player.stats.value(&"defense"), 4.0, "unequipping gear leaves independently sourced stacks")
	t.assert_equal(player.effects.to_array().size(), 1, "temporary buff survives equipment source removal")

func _test_death_gear(t: Node) -> void:
	GameSession.start_new_game()
	var player := GameSession.player
	var necklace := _stack(&"acorn_necklace", "death-necklace", 38)
	player.equipment.equip(necklace)
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	var rules := GameSession.current_difficulty()
	rules.equipment_loss = DifficultyDefinition.EquipmentLoss.LOSE
	rules.recovery_policy = DifficultyDefinition.RecoveryPolicy.DROP_AT_DEATH
	var start := GameSession.get_start_definition()
	var policy := start.respawn_policy.duplicate() as RespawnPolicy
	policy.health_ratio = 0.5
	player.begin_item_update()
	var result := DeathResolutionService.resolve(player, GameSession.settlement, GameSession.adventure, rules,
		Vector2(300, 500), policy, start.survival_config, GameSession.session_id, Callable(ContentRegistry, "get_item"))
	player.end_item_update()
	t.assert_equal(result.health, 50.0, "respawn ratio uses stats after lost equipment is removed")
	t.assert_equal(player.health, result.health, "respawn record and canonical health agree")
	var drop := result.drops[0]
	t.assert_true(player.equipment.equipped(EquipmentDefinition.EquipmentSlot.ACCESSORY_1) == null \
		and drop.items.any(func(stack: ItemStack) -> bool: return stack.to_dict() == necklace.to_dict()), "lost gear exists only in the drop with its original identity")
	t.assert_true(GameSession.adventure.recover_drop(drop.id).success, "drop recovery transfers into unsecured loot")
	var loot := GameSession.adventure.active_session.get_player_adventure(1).unsecured_loot
	t.assert_true(drop.items.is_empty() and loot.stacks().any(func(stack: ItemStack) -> bool: return stack.to_dict() == necklace.to_dict()), "recovered instance preserves its ID and durability")
	GameSession.start_new_game()

func _test_sparse_craft(t: Node) -> void:
	var resolver := Callable(ContentRegistry, "get_item")
	var settlement := SettlementState.new(resolver)
	settlement.storage.initialize_slots([null, ItemStack.new(&"moss_fiber", 2), null, ItemStack.new(&"rusty_scrap", 1)], 6)
	settlement.facility_levels = {&"workbench": 0}
	var bag := InventoryModel.new(5, resolver)
	bag.enable_equipment_id_assignment()
	bag.initialize_slots([_stack(&"leaf_vest", "sparse-vest", 33), null, ItemStack.new(&"berry", 2), null, ItemStack.new(&"water_drop", 1)])
	var recipe := ContentRegistry.get_definition(&"field_gear_recipe") as RecipeDefinition
	var progression := ProgressionState.new()
	var before := [settlement.storage.to_slot_dict(), bag.to_slot_dict()]
	t.assert_true(not CraftingService.craft(recipe, settlement, progression, bag).success, "two sparse holes cannot accept three gear pieces")
	t.assert_equal([settlement.storage.to_slot_dict(), bag.to_slot_dict()], before, "failed sparse craft preserves inputs, holes, metadata and existing equipment")
	bag.expand_capacity(1)
	t.assert_true(CraftingService.craft(recipe, settlement, progression, bag).success, "exactly three sparse holes accept the field gear kit")
	t.assert_true(bag.get_slot(0).instance_id == "sparse-vest" and bag.get_slot(2).quantity == 2 and bag.get_slot(4).item_id == &"water_drop", "successful craft leaves all pre-existing slots alone")
	var identities := [bag.get_slot(1).instance_id, bag.get_slot(3).instance_id, bag.get_slot(5).instance_id]
	t.assert_true(not identities.has("") and identities[0] != identities[1] and identities[1] != identities[2] and identities[0] != identities[2], "one distinct identity for each of the three outputs")
	before = [settlement.storage.to_slot_dict(), bag.to_slot_dict()]
	t.assert_true(not CraftingService.craft(recipe, settlement, progression, bag).success, "repeat craft cannot spend previously consumed materials")
	t.assert_equal([settlement.storage.to_slot_dict(), bag.to_slot_dict()], before, "repeated failed craft cannot add items")
	var storage_recipe := recipe.duplicate() as RecipeDefinition
	storage_recipe.output_to_player_inventory = false
	settlement.storage.add_item(&"moss_fiber", 2)
	settlement.storage.add_item(&"rusty_scrap", 1)
	t.assert_true(CraftingService.craft(storage_recipe, settlement, progression).success, "crafted equipment can enter shared storage directly")
	var granted := {}
	for stack in settlement.storage.stacks():
		granted[stack.instance_id] = true
	t.assert_true(granted.size() == 3 and not granted.has(""), "storage craft also grants distinct nonempty IDs")

func _test_offline_secure_failure(t: Node) -> void:
	GameSession.start_new_game()
	var kit := _stack(&"leaf_vest", "already-secured-vest", 31)
	GameSession.settlement.storage.add_stack(kit)
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	var expedition := GameSession.adventure.active_session
	var loot := expedition.get_player_adventure(1).unsecured_loot
	loot.add_stack(kit)
	var before := loot.to_slot_dict()
	var message := GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(message.contains("Duplicate") and GameSession.adventure.active_session == expedition \
		and GameSession.phase == GameSession.Phase.ADVENTURE, "offline escape rejects invalid loot before retiring the expedition")
	t.assert_true(loot.to_slot_dict() == before and GameSession.settlement.storage.stacks()[0].to_dict() == kit.to_dict(), "invalid secure preserves the original expedition and storage layouts")
	GameSession.start_new_game()

func _test_invalid_save_equipment(t: Node) -> void:
	GameSession.start_new_game()
	var path := "user://item_boundary_wrong_slot.json"
	var player := GameSession.player
	player.equipment.equip(_stack(&"acorn_necklace", "saved-necklace", 36))
	player.effects.apply_effect(ContentRegistry.get_definition(&"quick_paws") as EffectDefinition)
	player.effects.tick(2.5)
	player.set_health(108.0)
	t.assert_true(SaveManager.save_game(path) and SaveManager.load_game(path), "valid Save v5 restores equipped gear and a timed buff")
	player = GameSession.player
	t.assert_true(player.health == 108.0 and player.stats.value(&"max_health") == 110.0 \
		and is_equal_approx(player.stats.value(&"move_speed"), 218.5), "restore retains equipped max health and temporary speed modifier")
	t.assert_equal(player.effects.active_effects[&"quick_paws"].remaining, 57.5, "restore keeps the timed effect's exact remaining time")
	var before := GameSession.export_persistent_state()
	var staged := before.duplicate(true)
	var owner := String(GameSession.get_local_player_id())
	staged.players[owner].player_state.equipment["2"] = _stack(&"leaf_vest", "wrong-slot-vest", 20).to_dict()
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(staged))
	file.close()
	var original := FileAccess.get_file_as_string(path)
	t.assert_true(not SaveManager.load_game(path), "Save v5 rejects an item in the wrong equipment slot")
	t.assert_equal(GameSession.export_persistent_state(), before, "failed load preserves the complete canonical state")
	t.assert_equal(FileAccess.get_file_as_string(path), original, "failed load leaves source bytes untouched")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
