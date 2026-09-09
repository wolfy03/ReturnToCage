extends RefCounted

func run(t: Node) -> void:
	var start := GameSession.get_start_definition().duplicate(true) as GameStartDefinition
	start.storage_capacity = 1
	var model := SettlementState.new(Callable(ContentRegistry, "get_item"))
	var unique: Dictionary = {"item_id": "twig_sword", "quantity": 1, "instance_id": "overflow", "durability": 60}
	var data: Dictionary = {
		"settlement_storage": [ItemStack.new(&"berry", 10).to_dict(), unique],
		"pending_loot": [unique, ItemStack.new(&"water_drop", 3).to_dict(), {"item_id": "missing", "quantity": 4}, {"item_id": "workbench", "quantity": 1}]
	}
	var warnings: PackedStringArray = model.restore(data, start, ContentRegistry)
	t.assert_equal(model.storage.count(&"berry"), 10, "overflow restore keeps full primary storage")
	t.assert_equal(model.pending_loot.size(), 2, "pending merge retains valid overflow and unique ordinary loot")
	t.assert_equal(count(model.pending_loot, &"twig_sword"), 1, "overflow identity appears once despite duplicate pending record")
	t.assert_equal(count(model.pending_loot, &"water_drop"), 3, "existing valid pending quantities preserved")
	t.assert_equal(count(model.pending_loot, &"missing"), 0, "unknown pending item omitted")
	t.assert_equal(count(model.pending_loot, &"workbench"), 0, "wrong Resource type cannot become pending item")
	t.assert_true(warnings.size() >= 4, "unknown, mistyped, duplicate and overflow all report warnings")
	t.assert_true(model.storage.restore_overflow.is_empty(), "overflow ownership transferred out of temporary buffer")
	var before: Dictionary = model.to_save_dict()
	t.assert_true(not model.claim_pending_loot().success, "full storage cannot claim pending")
	t.assert_equal(model.to_save_dict(), before, "failed pending claim changes neither owner")
	model.storage.capacity = 3
	t.assert_true(model.claim_pending_loot().success, "all pending moves when every item fits")
	t.assert_true(model.pending_loot.is_empty(), "successful pending claim clears source")
	t.assert_equal(model.storage.count(&"twig_sword"), 1, "claimed instance not duplicated")
	t.assert_equal(model.storage.count(&"water_drop"), 3, "pending claim conserves ordinary quantity")
	model.storage.clear()
	model.storage.capacity = 0
	model.secure_loot([ItemStack.new(&"berry", 2)])
	model.storage.capacity = 3
	var reentered: Array[bool] = []
	var on_change := func() -> void: reentered.append(model.claim_pending_loot().success)
	model.storage.changed.connect(on_change)
	t.assert_true(model.claim_pending_loot().success, "pending claim outer transaction succeeds")
	t.assert_equal(reentered, [false], "signal reentrancy cannot duplicate pending loot")
	t.assert_equal(model.storage.count(&"berry"), 2, "reentrant pending claim conserves quantity")
	model.storage.changed.disconnect(on_change)
	var full: Dictionary = GameSession.export_state()
	var id_record: Dictionary = {"item_id": "twig_sword", "quantity": 1, "instance_id": "global", "durability": 60}
	full["player_inventory"] = [id_record]
	full["equipment"] = {"0": id_record}
	full["protected_inventory"] = [id_record]
	full["settlement_storage"] = [id_record]
	full["pending_loot"] = [id_record]
	full["death_drops"] = [{"id": "drop", "region_id": "sewer_region", "position": [0, 0], "items": [id_record]}]
	var snapshot: SessionSnapshot = SessionSnapshot.build(full, GameSession.get_start_definition(), ContentRegistry)
	t.assert_equal(snapshot.player.inventory.stacks().size(), 1, "session duplicate precedence starts with player inventory")
	t.assert_true(snapshot.player.equipment.all_equipped().is_empty(), "duplicate equipment removed")
	t.assert_true(snapshot.player.protected_inventory.stacks().is_empty(), "duplicate protected instance removed")
	t.assert_true(snapshot.settlement.storage.stacks().is_empty(), "duplicate storage instance removed")
	t.assert_true(snapshot.settlement.pending_loot.is_empty(), "duplicate pending instance removed")
	t.assert_true(snapshot.adventure.death_drops.is_empty(), "empty duplicate-only death record removed")
	t.assert_equal(snapshot.warnings.size(), 5, "one warning per global duplicate")
	var drops := AdventureState.new()
	warnings = drops.restore({"death_drops": [
		{"id": "first", "region_id": "sewer_region", "items": [id_record]},
		{"id": "second", "region_id": "sewer_region", "items": [id_record]}
	]})
	t.assert_equal(drops.death_drops.size(), 1, "duplicate instance across death records removed")
	t.assert_equal(warnings.size(), 1, "cross-drop duplicate warning is not repeated")
	var record := DeathDropRecord.new()
	var bad: Dictionary = id_record.duplicate()
	bad["quantity"] = 2
	warnings = record.restore({"id": "bad", "region_id": "sewer_region", "items": [bad]}, ContentRegistry)
	t.assert_true(record.items.is_empty() and warnings.size() == 1, "death drop cannot restore multi-quantity instance")

	test_reward_atomicity(t)

func count(items: Array[ItemStack], id: StringName) -> int:
	var quantity: int = 0
	for stack in items:
		if stack.item_id == id:
			quantity += stack.quantity
	return quantity

func test_reward_atomicity(t: Node) -> void:
	GameSession.start_new_game()
	var parent := QuestDefinition.new()
	parent.id = &"test_atomic_reward"
	parent.reward_item_ids = [&"berry"]
	parent.reward_amounts = [1]
	var objective := QuestObjectiveDefinition.new()
	objective.target_id = &"berry"
	parent.objectives = [objective]
	var child := QuestDefinition.new()
	child.id = &"test_atomic_followup"
	child.objectives = [objective]
	child.prerequisite_quest_ids = [&"sewer_supplies"]
	parent.follow_up_quest_ids = [child.id]
	ContentRegistry._definitions[parent.id] = parent
	ContentRegistry._definitions[child.id] = child
	GameSession.start_quest(parent.id)
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry", 1)
	GameSession.settlement.storage.capacity = 1
	GameSession.settlement.storage.add_item(&"berry", 10)
	t.assert_true(not GameSession.claim_quest_reward(parent.id), "full reward transaction fails")
	t.assert_true(not GameSession.progression.quest_states[parent.id].reward_claimed, "failed reward stays unclaimed")
	GameSession.settlement.storage.clear()
	var reentered: Array[bool] = []
	var callback := func() -> void: reentered.append(GameSession.claim_quest_reward(parent.id))
	GameSession.storage_changed.connect(callback)
	t.assert_true(GameSession.claim_quest_reward(parent.id), "reward retry succeeds")
	GameSession.storage_changed.disconnect(callback)
	t.assert_equal(reentered, [false], "storage signal cannot reenter reward payout")
	t.assert_equal(GameSession.settlement.storage.count(&"berry"), 1, "reward paid once")
	t.assert_true(GameSession.progression.quest_states[parent.id].reward_claimed, "successful reward committed")
	t.assert_true(not GameSession.progression.quest_states.has(child.id), "unmet followup prerequisite does not start child")
	t.assert_true(not GameSession.claim_quest_reward(parent.id), "followup failure does not roll back claimed reward")
	ContentRegistry._definitions.erase(parent.id)
	ContentRegistry._definitions.erase(child.id)
	GameSession.start_new_game()
