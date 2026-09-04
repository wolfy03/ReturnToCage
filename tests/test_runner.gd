extends Node

var failures: Array[String] = []
var passed: int = 0

func _ready() -> void:
	run_all()

func run_all() -> void:
	test_item_stack_and_inventory()
	test_equipment()
	test_survival_and_item_use()
	test_effects_and_modifiers()
	test_loot_determinism()
	test_death_loss()
	test_registry_validation()
	test_quest_and_facility()
	test_save_migration_and_round_trip()
	test_integration_loop()
	await test_world_scene_integration()
	if failures.is_empty():
		print("TEST PASS: %d assertions" % passed)
		get_tree().quit(0)
	else:
		for failure in failures:
			push_error(failure)
		print("TEST FAIL: %d failures, %d passed" % [failures.size(), passed])
		get_tree().quit(1)

func test_item_stack_and_inventory() -> void:
	var stack := ItemStack.new(&"berry", -2)
	assert_equal(stack.quantity, 0, "ItemStack rejects negative quantity")
	var inventory := InventoryModel.new(2, Callable(ContentRegistry, "get_item"))
	var result := inventory.add_item(&"berry", 15)
	assert_equal(result.changed, 15, "inventory stacks across slots")
	assert_equal(inventory.stacks().size(), 2, "inventory uses two stacks")
	var overflow := inventory.add_item(&"berry", 10)
	assert_equal(overflow.changed, 5, "inventory returns partial add")
	assert_equal(overflow.remainder, 5, "inventory reports overflow")
	assert_equal(inventory.remove_item(&"berry", 6).changed, 6, "inventory removes quantity")
	assert_equal(inventory.count(&"berry"), 14, "inventory count after removal")
	var protected_inventory := InventoryModel.new(2, Callable(ContentRegistry, "get_item")); protected_inventory.add_item(&"return_seed", 1)
	assert_equal(protected_inventory.discard_item(&"return_seed", 1).changed, 0, "protected item cannot be discarded")
	assert_true(inventory.total_weight() > 0.0, "inventory calculates weight")

func test_equipment() -> void:
	var equipment := EquipmentModel.new(Callable(ContentRegistry, "get_item"))
	var vest := ItemStack.new(&"leaf_vest", 1)
	assert_true(equipment.equip(vest) == null, "first equip has no displaced item")
	assert_equal(equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY).item_id, &"leaf_vest", "armor equipped")
	assert_equal(equipment.unequip(EquipmentDefinition.EquipmentSlot.BODY).item_id, &"leaf_vest", "armor unequipped")

func test_survival_and_item_use() -> void:
	var survival := SurvivalComponent.new()
	add_child(survival)
	survival.configure(ContentRegistry.get_definition(&"survival_default") as SurvivalConfig, 1.0)
	survival.set_values(25.0, 20.0)
	var inventory := InventoryModel.new(3, Callable(ContentRegistry, "get_item"))
	inventory.add_item(&"berry", 1)
	assert_true(ItemUseService.use_item(inventory, survival, null, &"berry", Callable(ContentRegistry, "get_item")), "consumable use succeeds")
	assert_true(survival.hunger > 25.0, "food restores hunger")
	assert_equal(inventory.count(&"berry"), 0, "consumable is removed")
	var config := ContentRegistry.get_definition(&"survival_default") as SurvivalConfig
	assert_equal(config.stage_for_ratio(0.75), 0, "normal survival stage")
	assert_equal(config.stage_for_ratio(0.35), 1, "warning survival stage")
	assert_equal(config.stage_for_ratio(0.1), 2, "critical survival stage")
	assert_equal(config.stage_for_ratio(0.0), 3, "empty survival stage")
	survival.queue_free()

func test_effects_and_modifiers() -> void:
	var stats := StatBlock.new()
	stats.set_base(&"move_speed", 100.0)
	stats.add_modifier(StatModifier.new(&"test", &"move_speed", 20.0, 1.5))
	assert_equal(stats.value(&"move_speed"), 180.0, "modifier calculation")
	stats.remove_source(&"test")
	var controller := EffectController.new()
	add_child(controller)
	controller.configure(stats)
	var effect := ContentRegistry.get_definition(&"quick_paws") as EffectDefinition
	controller.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	assert_true(stats.value(&"move_speed") > 100.0, "effect applies modifier")
	controller.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	assert_equal(controller.active_effects[&"quick_paws"].stacks, 1, "refresh does not stack")
	var stacking := EffectDefinition.new(); stacking.id = &"stack_test"; stacking.target_stat = &"attack_power"; stacking.magnitude = 1.0; stacking.duration_seconds = 5.0; stacking.stack_policy = EffectDefinition.StackPolicy.STACK; stacking.max_stacks = 2
	controller.apply_effect(stacking); controller.apply_effect(stacking); controller.apply_effect(stacking)
	assert_equal(controller.active_effects[&"stack_test"].stacks, 2, "stack policy respects max stacks")
	controller._process(1000.0)
	assert_equal(controller.active_effects.size(), 0, "effect expires")
	controller.queue_free()

func test_loot_determinism() -> void:
	var table := ContentRegistry.get_definition(&"sewer_beetle_loot") as LootTableDefinition
	var first := RandomNumberGenerator.new(); first.seed = 4242
	var second := RandomNumberGenerator.new(); second.seed = 4242
	var a := table.roll(first)
	var b := table.roll(second)
	assert_equal(a[0].item_id, b[0].item_id, "loot item deterministic with seed")
	assert_equal(a[0].quantity, b[0].quantity, "loot amount deterministic with seed")

func test_death_loss() -> void:
	var stacks: Array[ItemStack] = [ItemStack.new(&"rusty_scrap", 5), ItemStack.new(&"return_seed", 1)]
	var difficulty := (ContentRegistry.get_definition(&"normal") as DifficultyDefinition).duplicate() as DifficultyDefinition
	difficulty.inventory_loss = DifficultyDefinition.InventoryLoss.NONE
	assert_equal(DeathLossPolicy.apply(stacks, difficulty, Callable(ContentRegistry, "get_item")).lost.size(), 0, "no loss policy")
	difficulty.inventory_loss = DifficultyDefinition.InventoryLoss.HALF
	assert_equal(DeathLossPolicy.apply(stacks, difficulty, Callable(ContentRegistry, "get_item")).lost_count(&"rusty_scrap"), 2, "half loss floors deterministically")
	difficulty.inventory_loss = DifficultyDefinition.InventoryLoss.ALL
	assert_equal(DeathLossPolicy.apply(stacks, difficulty, Callable(ContentRegistry, "get_item")).lost_count(&"rusty_scrap"), 5, "all loss policy")
	var gear: Array[ItemStack] = [ItemStack.new(&"twig_sword", 1)]; gear[0].durability = 60
	difficulty.equipment_loss = DifficultyDefinition.EquipmentLoss.DAMAGE
	assert_equal(DeathLossPolicy.apply_equipment(gear, difficulty).equipment_kept[0].durability, 45, "equipment durability loss")
	difficulty.equipment_loss = DifficultyDefinition.EquipmentLoss.LOSE
	assert_equal(DeathLossPolicy.apply_equipment(gear, difficulty).equipment_lost.size(), 1, "equipment loss policy")
	var protected := (ContentRegistry.get_item(&"return_seed") as ItemDefinition).duplicate() as ItemDefinition
	protected.quest_protected = true
	var resolver := func(id: StringName) -> ItemDefinition: return protected if id == &"return_seed" else ContentRegistry.get_item(id)
	assert_equal(DeathLossPolicy.apply(stacks, difficulty, resolver).lost_count(&"return_seed"), 0, "protected item is retained")

func test_registry_validation() -> void:
	assert_equal(ContentRegistry.validate_all().size(), 0, "sample content validates")
	var one := ItemDefinition.new(); one.id = &"duplicate"
	var two := ItemDefinition.new(); two.id = &"duplicate"
	assert_true(not ContentRegistry.validate_batch([one, two]).is_empty(), "duplicate id detected")
	var recipe := RecipeDefinition.new(); recipe.id = &"bad_recipe"; recipe.input_item_ids = [&"missing_item"]; recipe.input_amounts = [1]
	assert_true(not ContentRegistry.validate_batch([recipe]).is_empty(), "missing reference detected")

func test_quest_and_facility() -> void:
	GameSession.start_new_game()
	assert_true(GameSession.start_quest(&"sewer_supplies"), "quest starts")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"rusty_scrap", 3)
	GameSession.settlement_storage.add_item(&"rusty_scrap", 3)
	assert_true(GameSession.can_upgrade_facility(&"workbench"), "facility cost condition")
	assert_true(GameSession.upgrade_facility(&"workbench"), "facility upgrades")
	assert_true(GameSession.unlocked_flags.has(&"basic_crafting"), "facility level unlocks feature flag")
	assert_true(GameSession.quest_states[&"sewer_supplies"].completed, "quest objectives complete")

func test_save_migration_and_round_trip() -> void:
	var old := {"format_version": 1, "game_state": {}}
	var migrated := SaveManager.migrate(old)
	assert_equal(migrated.get("format_version"), 2, "save v1 migrates to v2")
	GameSession.start_new_game()
	GameSession.settlement_storage.add_item(&"rusty_scrap", 7)
	GameSession.facility_levels[&"workbench"] = 1
	GameSession.start_quest(&"sewer_supplies")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"rusty_scrap", 2)
	var path := "user://return_to_cage_test_save.json"
	assert_true(SaveManager.save_game(path), "round-trip save writes")
	GameSession.start_new_game()
	assert_true(SaveManager.load_game(path), "round-trip save loads")
	assert_equal(GameSession.settlement_storage.count(&"rusty_scrap"), 7, "inventory restored")
	assert_equal(GameSession.facility_levels[&"workbench"], 1, "facility restored")
	assert_equal(GameSession.quest_states[&"sewer_supplies"].progress[0], 2, "quest progress restored")
	assert_equal(InventoryModel.new(2, Callable(ContentRegistry, "get_item")).restore([]).size(), 0, "empty inventory restores")
	var unknown_inventory := InventoryModel.new(2, Callable(ContentRegistry, "get_item"))
	assert_true(not unknown_inventory.restore([{"item_id": "missing_item", "quantity": 1}]).is_empty(), "unknown save item detected")
	var absolute := ProjectSettings.globalize_path(path)
	DirAccess.remove_absolute(absolute)
	DirAccess.remove_absolute(absolute + ".bak")
	var corrupt_path := "user://return_to_cage_corrupt_test.json"
	var corrupt := FileAccess.open(corrupt_path, FileAccess.WRITE); corrupt.store_string("{broken"); corrupt.close()
	assert_true(not SaveManager.load_game(corrupt_path), "corrupt save fails safely")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(corrupt_path))

func test_integration_loop() -> void:
	GameSession.start_new_game()
	var original_loss := (ContentRegistry.get_definition(&"normal") as DifficultyDefinition).inventory_loss
	GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE)
	assert_equal(GameSession.current_difficulty().inventory_loss, DifficultyDefinition.InventoryLoss.NONE, "difficulty override applies")
	assert_equal((ContentRegistry.get_definition(&"normal") as DifficultyDefinition).inventory_loss, original_loss, "difficulty resource remains immutable")
	GameSession.clear_difficulty_override(&"inventory_loss")
	GameSession.start_quest(&"sewer_supplies")
	var context := GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	assert_true(context != null and context.game_session_id == GameSession.session_id, "adventure context created")
	GameSession.collect_adventure_loot(&"rusty_scrap", 4)
	GameSession.record_enemy_kill(&"sewer_beetle")
	GameSession.discover_escape(&"sewer_ladder")
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	assert_equal(GameSession.settlement_storage.count(&"rusty_scrap"), 4, "escaped loot secured")
	assert_true(GameSession.upgrade_facility(&"workbench"), "integrated facility upgrade")
	assert_true(GameSession.quest_states[&"sewer_supplies"].completed, "integrated quest complete")
	GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	GameSession.collect_adventure_loot(&"rusty_scrap", 5)
	GameSession.finish_adventure(AdventureSession.Result.DEATH)
	assert_equal(GameSession.settlement_storage.count(&"rusty_scrap"), 4, "normal death keeps deterministic half of five")

func test_world_scene_integration() -> void:
	GameSession.start_new_game()
	var world_layer := Node.new()
	add_child(world_layer)
	SceneRouter.register_world_layer(world_layer)
	assert_true(SceneRouter.go_to_settlement(), "settlement scene loads through router")
	await get_tree().process_frame
	assert_true(get_tree().get_first_node_in_group(&"player") != null, "settlement spawns controllable player")
	var context := GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	assert_true(SceneRouter.go_to_adventure(context), "adventure scene loads from region data")
	await get_tree().process_frame
	assert_true(world_layer.get_child_count() == 1 and world_layer.get_child(0).name == "SewerRegion", "adventure world replaces settlement")
	await get_tree().physics_frame
	world_layer.queue_free()

func assert_true(value: bool, message: String) -> void:
	if value:
		passed += 1
	else:
		failures.append(message)

func assert_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual == expected:
		passed += 1
	else:
		failures.append("%s (expected %s, got %s)" % [message, expected, actual])
