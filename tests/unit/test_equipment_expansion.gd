extends RefCounted

func run(t: Node) -> void:
	t.assert_equal(EquipmentDefinition.EquipmentSlot.values(), [0, 1, 2, 3, 4], "equipment slots preserve the legacy numbers and append three")
	_test_acquisition_and_restore(t)
	_test_effect_projection(t)

func _test_acquisition_and_restore(t: Node) -> void:
	GameSession.start_new_game()
	var owner := GameSession.get_local_player_id()
	var player := GameSession.player
	var storage := GameSession.settlement.storage
	storage.add_item(&"moss_fiber", 2)
	storage.add_item(&"rusty_scrap", 1)
	player.inventory.resize_capacity(3)
	var materials := storage.to_slot_dict()
	var carried := player.inventory.to_slot_dict()
	t.assert_true(not GameSession.execute_craft_command(&"field_gear_recipe", owner).success, "field gear craft fails without room for all outputs")
	t.assert_equal(storage.to_slot_dict(), materials, "failed field gear craft preserves materials")
	t.assert_equal(player.inventory.to_slot_dict(), carried, "failed field gear craft grants no partial outputs")
	player.inventory.expand_capacity(3)
	t.assert_true(GameSession.execute_craft_command(&"field_gear_recipe", owner).success, "workbench grants three gear pieces to the requester")
	t.assert_equal(storage.count(&"moss_fiber") + storage.count(&"rusty_scrap"), 0, "successful field gear craft consumes materials")
	var ids: Array[StringName] = [&"leaf_hat", &"acorn_necklace", &"seed_ring"]
	var stats: Array[StringName] = [&"defense", &"max_health", &"stamina_regen"]
	var values := [1.0, 110.0, 20.0]
	for i in ids.size():
		var definition := ContentRegistry.get_item(ids[i]) as EquipmentDefinition
		t.assert_true(definition != null and definition.equipment_slot == i + 2 and definition.validate_definition(ContentRegistry).is_empty(), "new definition has the intended validated slot")
		var stack := player.inventory.get_slot(3 + i)
		t.assert_equal(stack.durability, definition.max_durability, "crafted gear starts at its authored durability")
		var preview := player.preview_equipment_stats(stack)
		t.assert_true(not stack.instance_id.is_empty() and GameSession.execute_equip_command(1, stack.instance_id).success, "each new gear piece equips through the existing command")
		t.assert_equal(player.stats.value(stats[i]), preview.value(stats[i]), "preview equals the actual newly equipped stat")
		player.sync_equipment()
		t.assert_equal(player.stats.value(stats[i]), values[i], "gear rebuild does not apply a modifier twice")
		t.assert_true(GameSession.execute_unequip_command(1, i + 2).success, "each added slot can unequip through the existing command")
		t.assert_true(GameSession.execute_equip_command(1, stack.instance_id).success, "unequipped instance retains its identity")

	var expected := player.equipment.to_dict()
	var path := "user://expanded_equipment_v5.json"
	t.assert_true(SaveManager.save_game(path) and SaveManager.load_game(path), "Save v5 round trips new gear")
	t.assert_equal(GameSession.player.equipment.to_dict(), expected, "save reload preserves all equipment slots, IDs and durability")
	t.assert_equal(GameSession.player.stats.value(&"max_health"), 110.0, "restore rebuilds the added accessory stat")
	var payload := PlayerItemStateSnapshot.from_state(owner, GameSession.player).to_payload()
	var mirror := PlayerState.new(Callable(ContentRegistry, "get_item"), func() -> bool: return false)
	mirror.reset(GameSession.get_start_definition(), ContentRegistry)
	mirror.prepare_network_item_mirror()
	var snapshot := PlayerItemStateSnapshot.from_payload(payload, ContentRegistry, owner)
	t.assert_true(mirror.apply_item_network_mirror(snapshot), "owner accepts the extended v17 slot domain")
	t.assert_equal(mirror.equipment.to_dict(), expected, "owner snapshot preserves the expanded equipment")
	t.assert_true(not PlayerItemStateSnapshot.from_payload(payload, ContentRegistry, &"another_owner").error_message.is_empty(), "another owner cannot apply the extended snapshot")
	var malformed := payload.duplicate(true)
	malformed.equipment[1].slot = EquipmentDefinition.EquipmentSlot.BODY
	t.assert_true(not PlayerItemStateSnapshot.from_payload(malformed, ContentRegistry, owner).error_message.is_empty(), "wire rejects a head item in the body slot")
	var malformed_save := expected.duplicate(true)
	malformed_save["1"] = malformed_save["2"]
	malformed_save.erase("2")
	var standalone := EquipmentModel.new(Callable(ContentRegistry, "get_item"))
	t.assert_true(not standalone.restore(malformed_save).is_empty() and standalone.equipped(EquipmentDefinition.EquipmentSlot.BODY) == null, "restore rejects an item assigned to the wrong slot")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var backup := path + ".bak"
	if FileAccess.file_exists(backup):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(backup))
	GameSession.start_new_game()

func _test_effect_projection(t: Node) -> void:
	var worn := EquipmentDefinition.new()
	worn.id = &"test_old_necklace"
	worn.equipment_slot = EquipmentDefinition.EquipmentSlot.ACCESSORY_1
	worn.stat_modifiers = {&"max_health": 10.0}
	var replacement := EquipmentDefinition.new()
	replacement.id = &"test_new_necklace"
	replacement.equipment_slot = worn.equipment_slot
	replacement.stat_modifiers = {&"max_health": 20.0}
	var equipment_effect := EffectDefinition.new()
	equipment_effect.id = &"gear_multiplier"
	equipment_effect.target_stat = &"max_health"
	equipment_effect.operation = EffectDefinition.Operation.MULTIPLY
	equipment_effect.magnitude = 1.2
	worn.equip_effects = [equipment_effect]
	var new_effect := equipment_effect.duplicate() as EffectDefinition
	new_effect.magnitude = 1.4
	replacement.equip_effects = [new_effect]
	var temporary := EffectDefinition.new()
	temporary.id = &"timed_multiplier"
	temporary.target_stat = &"max_health"
	temporary.operation = EffectDefinition.Operation.MULTIPLY
	temporary.magnitude = 1.5
	temporary.duration_seconds = 15.0
	var resolver := func(id: StringName) -> ItemDefinition:
		match id:
			worn.id: return worn
			replacement.id: return replacement
		return ContentRegistry.get_item(id)
	var player := PlayerState.new(resolver)
	player.effects.apply_effect(temporary)
	player.effects.tick(4.0)
	var old_stack := ItemStack.new(worn.id, 1)
	old_stack.durability = 40
	player.equipment.equip(old_stack)
	player.set_health(155.0)
	var candidate := ItemStack.new(replacement.id, 1)
	candidate.durability = 40
	var broken := candidate.duplicate_stack()
	broken.durability = 0
	var baseline := player.to_save_dict(true)
	var revision := player.item_state_revision
	var signals := [0]
	player.stats.stat_changed.connect(func(_id: StringName, _value: float) -> void: signals[0] += 1)
	var expected := player.preview_equipment_stats(candidate)
	var broken_expected := player.preview_equipment_stats(broken)
	t.assert_true(is_equal_approx(expected.value(&"max_health"), 252.0), "replacement removes old additive and effect while retaining the temporary multiplier")
	t.assert_equal(broken_expected.value(&"max_health"), 150.0, "broken candidate removes the old gear but contributes no stats or effects")
	t.assert_equal(player.to_save_dict(true), baseline, "preview changes neither loadout, health nor effect timers")
	t.assert_equal(player.item_state_revision, revision, "preview does not publish an item revision")
	t.assert_equal(signals[0], 0, "preview does not emit live stat signals")
	player.equipment.equip(candidate)
	t.assert_equal(player.stats.value(&"max_health"), expected.value(&"max_health"), "actual replacement equals preview with both effect sources")
	player.equipment.equip(broken)
	t.assert_equal(player.stats.value(&"max_health"), broken_expected.value(&"max_health"), "broken equipment agrees with the same preview path")
	t.assert_equal(player.effects.active_effects[temporary.id].remaining, 11.0, "equipping preserves the remaining timed buff")
