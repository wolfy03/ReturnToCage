extends Node

var failures: Array[String] = []
var passed: int = 0

func _ready() -> void:
	var arguments: PackedStringArray = OS.get_cmdline_user_args()
	if arguments.has("--restart-write") or arguments.has("--restart-read"):
		test_restart_persistence(arguments.has("--restart-write"))
		_finish_tests()
		return
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
	test_session_start_and_ownership()
	test_start_resource_variation_and_validation()
	test_session_signals()
	test_legacy_save_compatibility()
	test_partial_restore()
	test_resident_and_survival_state()
	await test_world_scene_integration()
	await get_tree().process_frame
	await StabilityTests.new().run(self)
	preload("res://tests/unit/test_inventory_stability.gd").new().run(self)
	preload("res://tests/unit/test_player_state_restore.gd").new().run(self)
	preload("res://tests/unit/test_settlement_state_restore.gd").new().run(self)
	preload("res://tests/unit/test_save_migration.gd").new().run(self)
	preload("res://tests/unit/test_reward_save_boundary.gd").new().run(self)
	preload("res://tests/unit/test_network_player_registry.gd").new().run(self)
	preload("res://tests/unit/test_network_input_validation.gd").new().run(self)
	preload("res://tests/unit/test_multiplayer_combat_foundation.gd").new().run(self)
	await preload("res://tests/unit/test_multiplayer_lifecycle.gd").new().run(self)
	await preload("res://tests/integration/test_multiplayer_combat_loot.gd").new().run(self)
	await preload("res://tests/integration/test_session_stability.gd").new().run(self)
	_finish_tests()

func _finish_tests() -> void:
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
	assert_equal(migrated.get("format_version"), 3, "save v1 migrates through v2 to v3")
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
	var actor := get_tree().get_first_node_in_group(&"player") as PlayerActor
	assert_true(actor.survival.state == GameSession.player.survival, "world player binds persistent survival")
	actor.survival.set_values(38.0, 49.0)
	actor.survival.progression_reduction = 0.25
	GameSession.player.stats.set_base(&"max_health", 140.0)
	actor.health.heal(20.0)
	var path: String = "user://return_to_cage_scene_restore_test.json"
	assert_true(SaveManager.save_game(path), "world state saves")
	GameSession.start_new_game()
	assert_true(SaveManager.load_game(path), "world state loads")
	assert_true(SceneRouter.go_to_settlement(), "restored settlement scene loads")
	await get_tree().process_frame
	actor = get_tree().get_first_node_in_group(&"player") as PlayerActor
	assert_equal(actor.health.max_health, 140.0, "restored stats configure actor max health")
	assert_equal(actor.health.current_health, 120.0, "restored current health reaches actor")
	assert_true(actor.survival.state == GameSession.player.survival, "restored actor binds new survival state")
	assert_true(absf(actor.survival.hunger - 38.0) < 1.0, "restored survival reaches actor with normal drain")
	assert_equal(actor.survival.progression_reduction, 0.25, "restored survival reduction reaches actor")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bak"))
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

# These fixtures were exported by the unmodified v2 implementation before refactoring.
func _fixture(name: String) -> Dictionary:
	return JSON.parse_string(FileAccess.get_file_as_string("res://tests/fixtures/" + name)) as Dictionary

func _assert_saved_fields(actual: Dictionary, expected: Dictionary, label: String) -> void:
	var normalized: Dictionary = JSON.parse_string(JSON.stringify(actual))
	expected = expected.duplicate(true)
	# v3 adds three fields; legacy field values are still compared individually.
	for key in ["active_effects", "death_drops", "pending_loot"]:
		if not expected.has(key):
			expected[key] = []
	assert_equal(normalized.size(), expected.size(), label + " flat schema key count")
	for key in expected:
		assert_equal(normalized.get(key), expected[key], "%s: %s" % [label, key])

func test_session_start_and_ownership() -> void:
	assert_true(GameSession.start_new_game(), "validated start succeeds")
	var expected: Dictionary = _fixture("legacy_v2_new_game.json")["game_state"]
	expected["session_id"] = GameSession.session_id
	_assert_saved_fields(GameSession.export_state(), expected, "unchanged new game")
	assert_true(GameSession.player_inventory == GameSession.player.inventory, "inventory has one owner")
	assert_true(GameSession.player_stats == GameSession.player.stats, "stats have one owner")
	assert_true(GameSession.equipment == GameSession.player.equipment, "equipment has one owner")
	assert_true(GameSession.protected_inventory == GameSession.player.protected_inventory, "protected inventory has one owner")
	assert_true(GameSession.settlement_storage == GameSession.settlement.storage, "storage has one owner")
	GameSession.facility_levels[&"workbench"] = 1
	assert_equal(GameSession.settlement.facility_levels[&"workbench"], 1, "legacy facility mutation reaches owner")
	GameSession.player_health = 67.0
	assert_equal(GameSession.player.health, 67.0, "legacy health setter reaches owner")
	GameSession.player.health = 89.0
	assert_equal(GameSession.player_health, 89.0, "legacy health getter reads owner")
	GameSession.survival_state = {"hunger": 37.0, "thirst": 48.0, "progression_reduction": 0.2}
	assert_equal(GameSession.player.survival.hunger, 37.0, "legacy survival assignment reaches typed state")
	var saved: Dictionary = GameSession.export_state()
	saved["resident_states"]["milo"]["state"] = "snapshot-only"
	assert_equal(GameSession.settlement.resident_states[&"milo"].current_state, &"idle", "exported resident data is detached")
	GameSession.start_new_game()

func test_start_resource_variation_and_validation() -> void:
	var start: GameStartDefinition = GameSession.get_start_definition()
	var original: GameStartDefinition = start.duplicate(true) as GameStartDefinition
	# Temporarily edit the registered Resource to exercise start_new_game itself.
	start.inventory_items[0].quantity = 5
	var extra := StartingItemDefinition.new()
	extra.item_id = &"rusty_scrap"
	extra.quantity = 4
	start.storage_items = [extra]
	start.protected_items = [extra]
	start.equipment_items[0].durability = 17
	start.facility_levels[&"workbench"] = 1
	start.residents[0].unlocked = false
	start.residents[0].current_state = &"resting"
	start.unlocked_regions = []
	start.unlocked_exits = [&"field_gate"]
	start.unlocked_flags = [&"test_flag"]
	start.discovered_escape_points = [&"test_point"]
	start.difficulty_id = &"story"
	start.player_health = 61.0
	start.player_stats[&"move_speed"] = 215.0
	start.hunger = 32.0
	start.thirst = 43.0
	start.progression_reduction = 0.3
	start.last_safe_position = Vector2(210, 490)
	assert_true(GameSession.start_new_game(), "edited starting Resource starts game")
	assert_equal(GameSession.player.inventory.count(&"berry"), 5, "Resource controls initial inventory")
	assert_equal(GameSession.settlement.storage.count(extra.item_id), 4, "Resource controls initial storage")
	assert_equal(GameSession.player.protected_inventory.count(extra.item_id), 4, "Resource controls protected inventory")
	assert_equal(GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND).durability, 17, "Resource controls initial durability")
	assert_equal(GameSession.settlement.facility_levels[&"workbench"], 1, "Resource controls initial facility")
	assert_true(not GameSession.settlement.resident_states[&"milo"].unlocked, "Resource controls resident unlock")
	assert_equal(GameSession.settlement.resident_states[&"milo"].current_state, &"resting", "Resource controls resident state")
	assert_equal(GameSession.progression.unlocked_regions, start.unlocked_regions, "Resource controls regions")
	assert_equal(GameSession.progression.unlocked_exits, start.unlocked_exits, "Resource controls exits")
	assert_equal(GameSession.progression.unlocked_flags, start.unlocked_flags, "Resource controls flags")
	assert_equal(GameSession.progression.discovered_escape_points, start.discovered_escape_points, "Resource controls discoveries")
	assert_equal(GameSession.difficulty.id, start.difficulty_id, "Resource controls difficulty")
	assert_equal(GameSession.player.health, 61.0, "Resource controls health")
	assert_equal(GameSession.player.stats.value(&"move_speed"), 215.0, "Resource controls player stats")
	assert_equal(GameSession.player.survival.hunger, 32.0, "Resource controls hunger")
	assert_equal(GameSession.player.survival.thirst, 43.0, "Resource controls thirst")
	assert_equal(GameSession.player.survival.progression_reduction, 0.3, "Resource controls progression reduction")
	assert_equal(GameSession.player.last_safe_position, start.last_safe_position, "Resource controls safe position")
	GameSession.progression.unlocked_exits.clear()
	GameSession.settlement.facility_levels.clear()
	assert_equal(start.unlocked_exits.size(), 1, "runtime unlocks do not mutate Resource")
	assert_equal(start.facility_levels.size(), 1, "runtime facilities do not mutate Resource")
	for property in start.get_property_list():
		if int(property["usage"]) & PROPERTY_USAGE_STORAGE and property["name"] != "script":
			start.set(property["name"], original.get(property["name"]))
	GameSession.start_new_game()
	var invalid: GameStartDefinition = start.duplicate(true) as GameStartDefinition
	invalid.inventory_items[0].item_id = &"missing_item"
	invalid.inventory_items[1].quantity = 0
	invalid.equipment_items[0].item_id = &"berry"
	invalid.facility_levels = {&"missing_facility": 0}
	invalid.unlocked_regions = [&"missing_region"]
	invalid.unlocked_exits = [&"missing_exit"]
	invalid.difficulty_id = &"missing_difficulty"
	invalid.residents.append(null)
	assert_true(invalid.validate_definition(ContentRegistry).size() >= 8, "start validation catches all required reference categories")
	assert_equal(ContentRegistry.validate_all().size(), 0, "validation leaves registered content intact")

func test_session_signals() -> void:
	var counts: Array[int] = [0, 0, 0, 0, 0, 0, 0, 0]
	var on_inventory := func() -> void: counts[0] += 1
	var on_storage := func() -> void: counts[1] += 1
	var on_reset := func() -> void: counts[2] += 1
	var on_difficulty := func(_id: StringName) -> void: counts[3] += 1
	var on_quest := func(_id: StringName) -> void: counts[4] += 1
	var on_facility := func(_id: StringName, _level: int) -> void: counts[5] += 1
	var on_started := func(_context: AdventureContext) -> void: counts[6] += 1
	var on_finished := func(_result: AdventureSession.Result, _summary: String) -> void: counts[7] += 1
	GameSession.inventory_changed.connect(on_inventory)
	GameSession.storage_changed.connect(on_storage)
	GameSession.session_reset.connect(on_reset)
	GameSession.difficulty_changed.connect(on_difficulty)
	GameSession.quest_changed.connect(on_quest)
	GameSession.facility_changed.connect(on_facility)
	GameSession.adventure_started.connect(on_started)
	GameSession.adventure_finished.connect(on_finished)
	for iteration in 3:
		GameSession.start_new_game()
		GameSession.restore_state(GameSession.export_state())
		GameSession._create_models()
		var inventory_before: int = counts[0]
		var storage_before: int = counts[1]
		GameSession.player.inventory.add_item(&"berry", 1)
		GameSession.settlement.storage.add_item(&"rusty_scrap", 1)
		assert_equal(counts[0] - inventory_before, 1, "inventory relay stays single after reset/restore %d" % iteration)
		assert_equal(counts[1] - storage_before, 1, "storage relay stays single after reset/restore %d" % iteration)
	assert_equal(counts[2], 6, "one session_reset per start or restore")
	GameSession.set_difficulty(&"story")
	GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE)
	GameSession.clear_difficulty_override(&"inventory_loss")
	assert_equal(counts[3], 3, "difficulty signals preserved")
	assert_true(not GameSession.set_difficulty_override(&"unknown", 1), "unknown override rejected")
	assert_true(not GameSession.set_difficulty_override(&"inventory_loss", {}), "mistyped override rejected")
	assert_true(not GameSession.set_difficulty_override(&"inventory_loss", 99), "invalid enum override rejected")
	assert_equal(counts[3], 3, "invalid overrides emit no change")
	GameSession.start_quest(&"sewer_supplies")
	GameSession.settlement.storage.add_item(&"rusty_scrap", 3)
	GameSession.upgrade_facility(&"workbench")
	assert_true(counts[4] >= 2, "quest start and progression signals preserved")
	assert_equal(counts[5], 1, "facility signal preserved")
	GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	assert_true(GameSession.active_adventure == GameSession.adventure.active_session, "adventure alias reads owner")
	var time_before: float = GameSession.play_time_seconds
	GameSession._process(2.0)
	assert_equal(GameSession.play_time_seconds, time_before + 2.0, "session play time ticks")
	assert_equal(GameSession.adventure.active_session.elapsed_seconds, 2.0, "domain adventure elapsed time ticks")
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	assert_equal(counts[6], 1, "adventure_started signal preserved")
	assert_equal(counts[7], 1, "adventure_finished signal preserved")
	GameSession.inventory_changed.disconnect(on_inventory)
	GameSession.storage_changed.disconnect(on_storage)
	GameSession.session_reset.disconnect(on_reset)
	GameSession.difficulty_changed.disconnect(on_difficulty)
	GameSession.quest_changed.disconnect(on_quest)
	GameSession.facility_changed.disconnect(on_facility)
	GameSession.adventure_started.disconnect(on_started)
	GameSession.adventure_finished.disconnect(on_finished)

func test_legacy_save_compatibility() -> void:
	var fixture: Dictionary = _fixture("legacy_v2_progress.json")
	assert_true(SaveManager.load_game("res://tests/fixtures/legacy_v2_progress.json"), "original v2 file loads")
	_assert_saved_fields(GameSession.export_state(), fixture["game_state"], "original v2 compatibility")
	var old: Dictionary = fixture.duplicate(true)
	old["format_version"] = 1
	old["game_state"].erase("difficulty_overrides")
	old["game_state"].erase("protected_inventory")
	var original: Dictionary = old.duplicate(true)
	var migrated: Dictionary = SaveManager.migrate(old)
	assert_equal(old, original, "migration never mutates caller envelope")
	assert_equal(migrated["format_version"], 3, "sequential v1 migration reaches v3")
	assert_equal(migrated["game_state"]["difficulty_overrides"], {}, "v1 migration adds overrides")
	assert_equal(migrated["game_state"]["protected_inventory"], [], "v1 migration adds protected inventory")
	var path: String = "user://return_to_cage_v1_fixture_test.json"
	_write_envelope(path, old)
	assert_true(SaveManager.load_game(path), "v1 save file loads through SaveManager")
	_assert_saved_fields(GameSession.export_state(), migrated["game_state"], "v1 restored fields")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for invalid in [{"format_version": []}, {"format_version": 0}, {"format_version": 4}, {"format_version": 1.5}, {"format_version": 2, "game_state": []}]:
		assert_true(SaveManager.migrate(invalid).is_empty(), "invalid envelope rejected: %s" % invalid)
	var before: Dictionary = GameSession.export_state()
	_write_envelope(path, {"format_version": 2, "game_state": "wrong"})
	assert_true(not SaveManager.load_game(path), "invalid game_state fails without mutation")
	assert_equal(GameSession.export_state(), before, "rejected save preserves current session")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	# Real save -> mutate all domains -> load, with full schema comparison.
	GameSession.restore_state(fixture["game_state"])
	assert_true(SaveManager.save_game(path), "all-domain round trip writes")
	GameSession.start_new_game()
	assert_true(SaveManager.load_game(path), "all-domain round trip loads")
	_assert_saved_fields(GameSession.export_state(), fixture["game_state"], "all-domain round trip")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bak"))

func test_partial_restore() -> void:
	var data: Dictionary = _fixture("legacy_v2_progress.json")["game_state"]
	data["player_inventory"].append({"item_id": "missing_item", "quantity": 1})
	data["player_inventory"].append({"item_id": "berry", "quantity": {}})
	data["equipment"]["1"] = {"item_id": "missing_equipment", "quantity": 1}
	data["quests"].append({"quest_id": "missing_quest"})
	data["quests"].append(null)
	data["quests"][0]["progress"] = [2]
	data["resident_states"]["broken"] = []
	data["last_safe_position"] = [1]
	var errors: PackedStringArray = GameSession.restore_state(data)
	assert_true(errors.size() >= 8, "partial restore reports all damaged records")
	assert_equal(GameSession.player.inventory.count(&"berry"), 2, "unknown and malformed items do not discard valid items")
	assert_equal(GameSession.player.health, 73.0, "partial restore retains valid health")
	assert_equal(GameSession.settlement.storage.count(&"rusty_scrap"), 7, "partial restore retains valid storage")
	assert_equal(GameSession.progression.quest_states.size(), 1, "unknown quest skipped")
	assert_equal(GameSession.progression.quest_states[&"sewer_supplies"].progress.size(), 2, "quest progress padded before gameplay indexing")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY, &"workbench")
	assert_equal(GameSession.player.last_safe_position, GameSession.get_start_definition().last_safe_position, "short position uses configured fallback")
	assert_true(GameSession.adventure.active_session == null, "restore discards active adventure")
	var messages: Array[String] = []
	var on_load := func(success: bool, message: String) -> void:
		assert_true(success, "partially damaged file still loads")
		messages.append(message)
	var path: String = "user://return_to_cage_partial_test.json"
	_write_envelope(path, {"format_version": 2, "game_state": data})
	SaveManager.load_finished.connect(on_load)
	SaveManager.load_game(path)
	SaveManager.load_finished.disconnect(on_load)
	assert_true(messages.size() == 1 and messages[0].contains("warnings") and messages[0].contains("missing_item") and messages[0].contains("missing_quest"), "load_finished exposes unknown-content warnings")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	for position in [null, {}, "bad", [], [1], [1, {}], [false, 2], [1, 2, 3]]:
		assert_true(not GameSession.restore_state({"last_safe_position": position}).is_empty(), "invalid position safely warned: %s" % str(position))
	var malformed: Dictionary = {
		"session_id": [], "play_time_seconds": {}, "player_stats": {"max_health": []},
		"player_inventory": {}, "equipment": {"bad": [], "0": {"item_id": "twig_sword", "quantity": 1, "durability": []}},
		"settlement_storage": null, "protected_inventory": false, "facility_levels": {"workbench": []},
		"quests": [{"quest_id": "sewer_supplies", "progress": [{}], "completed": {}, "reward_claimed": []}],
		"unlocked_regions": {}, "unlocked_exits": [false], "unlocked_flags": null,
		"discovered_escape_points": 12, "resident_states": {"milo": {"unlocked": [], "state": {}}},
		"difficulty_id": "missing_difficulty", "difficulty_overrides": {"inventory_loss": 99, "loot_multiplier": {}},
		"survival_state": {"hunger": {}, "thirst": [], "progression_reduction": false}, "player_health": []
	}
	var before: Dictionary = GameSession.export_state()
	errors = GameSession.restore_state(malformed)
	assert_true(not errors.is_empty(), "fatal core type errors reported")
	assert_equal(GameSession.export_state(), before, "fatal core types preserve the live session")
	malformed["player_inventory"] = []
	malformed["settlement_storage"] = []
	malformed["protected_inventory"] = []
	errors = GameSession.restore_state(malformed)
	assert_true(errors.size() >= 20, "recoverable nested field types collected without exceptions")
	assert_true(GameSession.current_difficulty() != null, "unknown difficulty recovers configured preset")
	assert_true(GameSession.restore_state({}).is_empty(), "missing optional fields restore safely")
	assert_equal(GameSession.player.survival.hunger, GameSession.get_start_definition().hunger, "partial saves do not inherit previous session hunger")

func test_resident_and_survival_state() -> void:
	var resident := ResidentState.new(&"milo")
	var raw: Dictionary = {"unlocked": true, "state": "idle"}
	assert_true(resident.restore(raw).is_empty(), "resident legacy dictionary restores")
	assert_equal(resident.to_dict(), raw, "resident legacy JSON round trip")
	assert_equal(resident.resident_id, &"milo", "resident identity comes from containing save key")
	assert_equal(typeof(resident.current_state), TYPE_STRING_NAME, "resident current state is StringName")
	GameSession.start_new_game()
	var component := SurvivalComponent.new()
	add_child(component)
	component.configure(ContentRegistry.get_definition(&"survival_default") as SurvivalConfig, 1.0, GameSession.player.survival)
	assert_true(component.state == GameSession.player.survival, "component and player share one survival state")
	component.set_values(31.0, 42.0)
	component.progression_reduction = 0.4
	assert_equal(GameSession.player.survival.hunger, 31.0, "component updates persistent hunger directly")
	assert_equal(GameSession.player.survival.progression_reduction, 0.4, "progression reduction is immediately persistent")
	component._process(1.0)
	assert_true(GameSession.player.survival.thirst < 42.0, "component drain updates persistent state")
	component.queue_free()

func _write_envelope(path: String, envelope: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(envelope))
	file.close()

func test_restart_persistence(write_phase: bool) -> void:
	var path: String = "user://return_to_cage_restart_test.json"
	var expected: Dictionary = _fixture("legacy_v2_progress.json")["game_state"]
	if write_phase:
		GameSession.start_new_game()
		GameSession.restore_state(expected)
		assert_true(SaveManager.save_game(path), "restart phase 1 saves changed session")
	else:
		assert_true(GameSession.session_id.is_empty(), "restart phase 2 starts in a fresh process")
		assert_true(SaveManager.load_game(path), "restart phase 2 loads saved session")
		_assert_saved_fields(GameSession.export_state(), expected, "process restart restores all fields")
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bak"))
