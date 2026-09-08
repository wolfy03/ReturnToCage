class_name StabilityTests
extends RefCounted

var t: Node
var temporary_ids: Array[StringName] = []
var world: Node

func run(runner: Node) -> void:
	t = runner
	test_input_map()
	test_death_and_snapshot()
	test_overflow_and_transactions()
	test_effects_and_equipment()
	test_domain_rules_and_validation()
	test_safe_restore()
	await test_world_and_climbing()
	await test_hud()
	for id in temporary_ids:
		ContentRegistry._definitions.erase(id)
	t.assert_equal(ContentRegistry.validate_all().size(), 0, "content valid after stability suite cleanup")

func register(definition: ContentDefinition) -> void:
	ContentRegistry._definitions[definition.id] = definition
	temporary_ids.append(definition.id)

func start_adventure(preset: StringName = &"survival") -> void:
	GameSession.start_new_game()
	GameSession.set_difficulty(preset)
	t.assert_true(GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region") != null, "authorized expedition starts")

func test_death_and_snapshot() -> void:
	GameSession.start_new_game()
	t.assert_true(SaveManager.can_save().success and SaveManager.can_load().success, "settlement permits persistence")
	GameSession.set_difficulty(&"survival")
	GameSession.player.inventory.add_item(&"rusty_scrap", 5)
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	GameSession.collect_adventure_loot(&"rusty_scrap", 7)
	var rules: DifficultyDefinition = GameSession.current_difficulty()
	GameSession.set_difficulty(&"story")
	GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE)
	GameSession.set_difficulty_override(&"loot_multiplier", 5.0)
	var snapshot: DifficultyDefinition = GameSession.current_difficulty()
	for property in DifficultyState.OVERRIDABLE_PROPERTIES:
		t.assert_equal(snapshot.get(property), rules.get(property), "expedition snapshot fixed: %s" % property)
	snapshot.inventory_loss = DifficultyDefinition.InventoryLoss.NONE
	t.assert_equal(GameSession.current_difficulty().inventory_loss, DifficultyDefinition.InventoryLoss.ALL, "snapshot accessor returns a detached copy")
	var before: Dictionary = GameSession.export_state()
	t.assert_true(not GameSession.restore_state(before).is_empty(), "facade restore cannot bypass expedition restriction")
	t.assert_true(not SaveManager.save_game("user://blocked_save.json"), "direct expedition save denied")
	t.assert_true(not SaveManager.load_game("res://tests/fixtures/legacy_v2_progress.json"), "direct expedition load denied")
	t.assert_equal(GameSession.export_state(), before, "blocked persistence preserves state")
	t.assert_true(not SceneRouter.go_to_settlement(), "router cannot bypass expedition escape")
	var result: RespawnResult = GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2(810, 510))
	t.assert_true(result.in_adventure, "death result identifies expedition")
	t.assert_true(result.health > 0.0 and GameSession.player.health == result.health, "death restores health before transition")
	t.assert_equal(GameSession.player.inventory.count(&"rusty_scrap"), 0, "captured survival rules remove all carried scrap")
	t.assert_equal(GameSession.player.inventory.count(&"return_seed"), 1, "protected carried item retained")
	t.assert_equal(result.equipment_damaged.size(), 1, "death result reports damaged gear")
	t.assert_equal(GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND).durability, 45, "gear damage uses captured survival rules")
	t.assert_equal(result.drops.size(), 1, "DROP_AT_DEATH creates one record")
	var record: DeathDropRecord = result.drops[0]
	t.assert_equal(record.position, Vector2(810, 510), "actual death position retained")
	t.assert_equal(_count(record.items, &"rusty_scrap"), 12, "carried and unsecured losses are recoverable")
	var saved: Dictionary = GameSession.export_state()
	t.assert_true(GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ZERO) == result, "duplicate death returns original result")
	t.assert_equal(GameSession.export_state(), saved, "duplicate death does not mutate items")
	GameSession.complete_respawn(GameSession.get_local_peer_id())
	t.assert_true(SaveManager.can_save().success, "settlement recovery permits save")
	var path: String = "user://death_drop_test.json"
	t.assert_true(SaveManager.save_game(path), "death drops save")
	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path), "death drops load")
	t.assert_equal(GameSession.adventure.death_drops[0].to_dict(), record.to_dict(), "death drop save round trip")
	_cleanup(path)
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_equal(GameSession.current_difficulty().inventory_loss, DifficultyDefinition.InventoryLoss.NONE, "next expedition receives changed global rules")
	GameSession.adventure.active_session.unsecured_loot.capacity = 1
	GameSession.adventure.active_session.unsecured_loot.add_item(&"rusty_scrap", 35)
	var recovery: CommandResult = GameSession.adventure.recover_drop(record.id)
	t.assert_true(not recovery.success, "partial recovery reports remainder")
	t.assert_equal(GameSession.adventure.active_session.unsecured_loot.count(&"rusty_scrap"), 40, "partial recovery transfers only available capacity")
	t.assert_equal(_count(GameSession.adventure.death_drops[0].items, &"rusty_scrap"), 7, "partial recovery retains exact remainder")
	GameSession.adventure.active_session.unsecured_loot.capacity = 10
	t.assert_true(GameSession.adventure.recover_drop(record.id).success, "full recovery succeeds after adding capacity")
	t.assert_true(GameSession.adventure.death_drops.is_empty(), "full recovery removes record")
	t.assert_true(not GameSession.adventure.recover_drop(record.id).success, "drop cannot be collected twice")
	# A second survival expedition loses recovered loot into a fresh record.
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	GameSession.set_difficulty(&"survival")
	GameSession.clear_difficulty_override(&"inventory_loss")
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	GameSession.collect_adventure_loot(&"rusty_scrap", 8)
	var second: RespawnResult = GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2(820, 510))
	t.assert_true(second.drops[0].id != record.id, "later death uses new record identity")
	GameSession.complete_respawn(GameSession.get_local_peer_id())
	GameSession.arm_player_life(GameSession.get_local_peer_id())
	var inventory_before: Array[Dictionary] = GameSession.player.inventory.to_array()
	var home: RespawnResult = GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2(200, 500))
	t.assert_true(not home.in_adventure and home.drops.is_empty(), "settlement death has no expedition drop")
	t.assert_equal(GameSession.player.inventory.to_array(), inventory_before, "settlement death preserves inventory")
	GameSession.start_new_game()

func test_overflow_and_transactions() -> void:
	start_adventure(&"normal")
	GameSession.settlement.storage.capacity = 1
	GameSession.settlement.storage.add_item(&"rusty_scrap", 39)
	GameSession.collect_adventure_loot(&"rusty_scrap", 2)
	GameSession.collect_adventure_loot(&"berry", 3)
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_equal(GameSession.settlement.storage.count(&"rusty_scrap"), 39, "multi-loot overflow never partially commits")
	t.assert_equal(_count(GameSession.settlement.pending_loot, &"rusty_scrap"), 2, "overflow scrap retained")
	t.assert_equal(_count(GameSession.settlement.pending_loot, &"berry"), 3, "overflow berry retained")
	t.assert_true(not GameSession.claim_pending_loot().success, "pending loot retry fails without capacity")
	GameSession.settlement.storage.capacity = 3
	t.assert_true(GameSession.claim_pending_loot().success, "pending loot claimed atomically after space available")
	t.assert_equal(GameSession.settlement.storage.count(&"rusty_scrap"), 41, "scrap total conserved")
	t.assert_equal(GameSession.settlement.storage.count(&"berry"), 3, "berry total conserved")
	GameSession.start_quest(&"sewer_supplies")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"rusty_scrap", 3)
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY, &"workbench", 1)
	t.assert_true(not GameSession.claim_quest_reward(&"sewer_supplies"), "quest reward denied with full storage")
	t.assert_true(not GameSession.progression.quest_states[&"sewer_supplies"].reward_claimed, "failed reward stays unclaimed")
	GameSession.settlement.storage.capacity = 4
	t.assert_true(GameSession.claim_quest_reward(&"sewer_supplies"), "quest reward can be retried")
	t.assert_equal(GameSession.settlement.storage.count(&"mushroom_stew"), 1, "quest reward paid exactly once")
	t.assert_true(not GameSession.claim_quest_reward(&"sewer_supplies"), "reward cannot be duplicated")
	var inventory := InventoryModel.new(1, Callable(ContentRegistry, "get_item"))
	inventory.add_item(&"berry", 9)
	var original: Array[Dictionary] = inventory.to_array()
	t.assert_true(not inventory.exchange([ItemStack.new(&"berry", 2)], [ItemStack.new(&"water_drop", 1)]).success, "craft output preview accounts for occupied input stack")
	t.assert_equal(inventory.to_array(), original, "failed exchange preserves materials")
	t.assert_true(inventory.exchange([ItemStack.new(&"berry", 9)], [ItemStack.new(&"water_drop", 1)]).success, "exchange can use slot freed by consumed input")

func test_effects_and_equipment() -> void:
	GameSession.start_new_game()
	var effect := ContentRegistry.get_definition(&"quick_paws") as EffectDefinition
	var speed: float = GameSession.player.stats.value(&"move_speed")
	GameSession.player.effects.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	var boosted: float = GameSession.player.stats.value(&"move_speed")
	GameSession.player.effects.tick(12.0)
	GameSession.player.effects.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), boosted, "refresh does not stack modifiers")
	GameSession.player.effects.tick(12.0)
	var path: String = "user://effect_state_test.json"
	t.assert_true(SaveManager.save_game(path), "active effects save")
	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path), "active effects restore")
	t.assert_equal(GameSession.player.effects.active_effects[&"quick_paws"].remaining, 48.0, "effect remaining lifetime restored")
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), boosted, "restored modifier applied once")
	GameSession.player.effects.tick(48.0)
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), speed, "expiry removes modifier")
	GameSession.player.effects.tick(48.0)
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), speed, "expiry is idempotent")
	_cleanup(path)
	var healing := EffectDefinition.new()
	healing.id = &"test_heal"
	healing.kind = EffectDefinition.EffectKind.PERIODIC_HEAL
	healing.magnitude = 3.0
	healing.duration_seconds = 3.0
	healing.tick_interval_seconds = 0.5
	GameSession.player.set_health(50.0)
	GameSession.player.effects.apply_effect(healing)
	GameSession.player.effects.tick(1.0)
	t.assert_equal(GameSession.player.health, 56.0, "periodic heal executes configured ticks")
	GameSession.player.effects.remove_effect(healing.id)
	var damage := healing.duplicate() as EffectDefinition
	damage.id = &"test_damage"
	damage.kind = EffectDefinition.EffectKind.PERIODIC_DAMAGE
	GameSession.player.effects.apply_effect(damage)
	GameSession.player.effects.tick(1.0)
	t.assert_equal(GameSession.player.health, 50.0, "periodic damage executes configured ticks")
	GameSession.player.effects.remove_effect(damage.id)
	var health := HealthComponent.new()
	t.add_child(health)
	health.invulnerable_remaining = 1.0
	health.receive_periodic_damage(0.5)
	health.receive_periodic_damage(0.5)
	t.assert_equal(health.current_health, 99.0, "periodic victim damage keeps exact ticks despite contact invulnerability")
	health.queue_free()
	var vest := ItemStack.new(&"leaf_vest", 1)
	vest.durability = 45
	GameSession.player.equipment.equip(vest)
	t.assert_equal(GameSession.player.stats.value(&"defense"), 2.0, "equipment modifiers applied")
	GameSession.player.sync_equipment()
	t.assert_equal(GameSession.player.stats.value(&"defense"), 2.0, "equipment resync does not duplicate modifiers")
	GameSession.player.equipment.unequip(EquipmentDefinition.EquipmentSlot.BODY)
	t.assert_equal(GameSession.player.stats.value(&"defense"), 0.0, "unequip removes equipment modifiers")
	vest.durability = 0
	GameSession.player.equipment.equip(vest)
	t.assert_equal(GameSession.player.stats.value(&"defense"), 0.0, "broken gear provides no bonuses")
	var gear := EquipmentDefinition.new()
	gear.id = &"test_effect_gear"
	gear.display_name = "Effect gear"
	gear.equip_effects = [effect]
	gear.stat_modifiers = {&"max_health": 50.0}
	register(gear)
	GameSession.player.equipment.equip(ItemStack.new(gear.id, 1))
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), boosted, "equip effects are active")
	GameSession.player.set_health(140.0)
	GameSession.player.sync_equipment()
	t.assert_equal(GameSession.player.health, 140.0, "gear resync preserves health without transient modifier removal")
	GameSession.player.effects.tick(100.0)
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), boosted, "equipped effect persists while equipped")
	GameSession.player.equipment.unequip(EquipmentDefinition.EquipmentSlot.BODY)
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), speed, "unequip removes equip effects")
	t.assert_equal(GameSession.player.health, 100.0, "unequip clamps persistent max health without actor")
	# Multiple effects from the same food slot are all replaced.
	var second := effect.duplicate() as EffectDefinition
	second.id = &"slot_second"
	var food := ItemDefinition.new()
	food.food_slot = ItemDefinition.FoodSlot.SNACK
	food.effects = [effect, second]
	GameSession.player.effects.apply_item(food)
	var replacement := ItemDefinition.new()
	replacement.food_slot = ItemDefinition.FoodSlot.SNACK
	GameSession.player.effects.apply_item(replacement)
	t.assert_true(GameSession.player.effects.active_effects.is_empty(), "food slot replacement removes every prior effect")

func test_domain_rules_and_validation() -> void:
	GameSession.start_new_game()
	t.assert_true(GameSession.can_use_exit(&"sewer_gate", &"sewer_region").success, "valid route accepted")
	t.assert_true(not GameSession.can_use_exit(&"field_gate", &"sewer_region").success, "development route cannot fake sewer connection")
	var exit := (ContentRegistry.get_definition(&"sewer_gate") as SettlementExitDefinition).duplicate() as SettlementExitDefinition
	exit.id = &"test_exit"
	exit.required_flags = [&"test_route"]
	exit.required_facility_levels = {&"workbench": 1}
	register(exit)
	GameSession.progression.unlocked_exits.append(exit.id)
	t.assert_true(not GameSession.can_use_exit(exit.id, &"sewer_region").success, "route flag enforced")
	GameSession.progression.unlocked_flags.append(&"test_route")
	t.assert_true(not GameSession.can_use_exit(exit.id, &"sewer_region").success, "route facility level enforced")
	GameSession.settlement.facility_levels[&"workbench"] = 1
	t.assert_true(GameSession.can_use_exit(exit.id, &"sewer_region").success, "route requirements satisfied")
	exit.entry_point_id = &"missing_entry"
	t.assert_true(not exit.validate_definition(ContentRegistry).is_empty(), "invalid region entry detected")
	t.assert_true(not GameSession.can_use_exit(exit.id, &"sewer_region").success, "domain rejects invalid entry")
	exit.entry_point_id = &"sewer_entrance"
	exit.connected_region_ids = [&"berry"]
	t.assert_true(not exit.validate_definition(ContentRegistry).is_empty(), "exit detects wrong Resource type")
	exit.connected_region_ids = [&"sewer_region"]
	var parent := QuestDefinition.new()
	parent.id = &"test_parent"
	parent.title = "Parent"
	var objective := QuestObjectiveDefinition.new()
	objective.type = QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM
	objective.target_id = &"berry"
	parent.objectives = [objective]
	var child := parent.duplicate(true) as QuestDefinition
	child.id = &"test_child"
	child.prerequisite_quest_ids = [parent.id]
	child.repeatable = true
	parent.follow_up_quest_ids = [child.id]
	register(parent)
	register(child)
	t.assert_true(not GameSession.start_quest(child.id), "quest prerequisite enforced")
	t.assert_true(GameSession.start_quest(parent.id), "parent quest starts")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry", 1)
	t.assert_true(GameSession.claim_quest_reward(parent.id), "parent reward claim succeeds")
	t.assert_true(GameSession.progression.quest_states.has(child.id), "follow-up quest starts after claim")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry", 1)
	GameSession.claim_quest_reward(child.id)
	t.assert_true(GameSession.start_quest(child.id), "repeatable quest restarts after reward")
	t.assert_true(not GameSession.start_quest(parent.id), "nonrepeatable quest cannot restart")
	var facility := (ContentRegistry.get_definition(&"workbench") as FacilityDefinition).duplicate(true) as FacilityDefinition
	facility.id = &"test_facility"
	facility.prerequisite_facility_ids = [&"workbench"]
	facility.prerequisite_quest_ids = [child.id]
	register(facility)
	t.assert_true(not GameSession.can_upgrade_facility(facility.id), "facility quest prerequisite enforced")
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry", 1)
	GameSession.settlement.facility_levels[&"workbench"] = 0
	t.assert_true(not GameSession.can_upgrade_facility(facility.id), "facility prerequisite level enforced")
	GameSession.settlement.facility_levels[&"workbench"] = 1
	t.assert_true(not GameSession.can_upgrade_facility(facility.id), "facility resources enforced")
	GameSession.settlement.storage.add_item(&"rusty_scrap", 3)
	t.assert_true(GameSession.upgrade_facility(facility.id), "facility prerequisites and transaction succeed")
	t.assert_true(not GameSession.can_upgrade_facility(facility.id) and GameSession.last_message.contains("Maximum"), "maximum facility level has distinct reason")
	GameSession.settlement.storage.add_item(&"berry", 2)
	GameSession.settlement.storage.add_item(&"moss_fiber", 1)
	t.assert_true(GameSession.craft(&"stew_recipe").success, "Resource recipe crafts with valid facility")
	t.assert_equal(GameSession.settlement.storage.count(&"mushroom_stew"), 1, "craft output delivered")
	var region := (ContentRegistry.get_definition(&"sewer_region") as RegionDefinition).duplicate() as RegionDefinition
	region.enemy_ids = [&"berry"]
	region.major_resource_ids = [&"workbench"]
	region.entry_point_ids = [&"sewer_entrance", &"sewer_entrance"]
	region.escape_point_ids = [&"missing_escape"]
	t.assert_true(region.validate_definition(ContentRegistry).size() >= 4, "region detects types, duplicate points and scene mismatch")
	var loot := (ContentRegistry.get_definition(&"sewer_beetle_loot") as LootTableDefinition).duplicate() as LootTableDefinition
	loot.item_ids = [&"workbench"]
	loot.weights = [1.0]
	loot.min_amounts = [-1]
	loot.max_amounts = [1]
	t.assert_true(loot.validate_definition(ContentRegistry).size() >= 2, "loot type and negative quantity detected")
	var weapon := WeaponDefinition.new()
	weapon.id = &"test_invalid_projectile"
	weapon.display_name = "Invalid projectile"
	weapon.attack_mode = WeaponDefinition.AttackMode.PROJECTILE
	t.assert_true(not weapon.validate_definition(ContentRegistry).is_empty(), "projectile without attack scene rejected")

func test_safe_restore() -> void:
	GameSession.start_new_game()
	var before: Dictionary = GameSession.export_state()
	var invalid: Dictionary = before.duplicate(true)
	invalid["player_inventory"] = "wrong"
	var staged: SessionSnapshot = GameSession.prepare_restore(invalid)
	t.assert_true(not staged.fatal_error.is_empty(), "fatal save type identified before applying")
	t.assert_equal(GameSession.export_state(), before, "staging failure preserves current state")
	t.assert_true(SaveManager.migrate({"format_version": 3}).is_empty(), "missing game_state envelope rejected")
	var path: String = "user://fatal_snapshot_test.json"
	t._write_envelope(path, {"format_version": 3, "game_state": invalid})
	t.assert_true(not SaveManager.load_game(path), "fatal snapshot rejected by SaveManager")
	t.assert_equal(GameSession.export_state(), before, "fatal file does not partially overwrite session")
	_cleanup(path)
	var data: Dictionary = before.duplicate(true)
	data["player_inventory"] = [{"item_id": "berry", "quantity": -5}, {"item_id": "rusty_scrap", "quantity": 600}]
	data["difficulty_id"] = "missing"
	data["difficulty_overrides"] = {"inventory_loss": -1, "loot_multiplier": 999}
	data["facility_levels"] = {"workbench": 999}
	data["player_health"] = -20
	data["survival_state"] = {"hunger": -10, "thirst": 999, "progression_reduction": 5}
	data["last_safe_position"] = [1]
	data["resident_states"] = {"milo": []}
	data["equipment"] = {"1": {"item_id": "twig_sword", "quantity": 1}}
	var warnings: PackedStringArray = GameSession.restore_state(data)
	t.assert_true(warnings.size() >= 9, "recoverable save range problems reported")
	t.assert_equal(GameSession.difficulty.id, &"normal", "unknown difficulty falls back to normal")
	t.assert_equal(GameSession.player.inventory.count(&"rusty_scrap") + _count(GameSession.settlement.pending_loot, &"rusty_scrap"), 600, "restore overcapacity preserves valid items in pending storage")
	for stack in GameSession.player.inventory.stacks():
		t.assert_true(stack.quantity <= ContentRegistry.get_item(stack.item_id).max_stack, "restored stacks respect max_stack")
	t.assert_true(GameSession.player.health > 0.0, "restored settlement health positive")
	t.assert_equal(GameSession.player.survival.hunger, 0.0, "negative hunger clamped")
	t.assert_equal(GameSession.player.survival.thirst, 100.0, "excess thirst clamped")
	var drop := DeathDropRecord.new()
	warnings = drop.restore({"id": "unavailable", "region_id": "missing_region", "position": [4, 5], "items": [{"item_id": "missing_item", "quantity": 2}]}, ContentRegistry)
	t.assert_equal(drop.items.size(), 1, "unavailable death-drop content retained")
	t.assert_true(warnings.size() >= 2, "unavailable death-drop content warned")
	var changed_quest := QuestDefinition.new()
	changed_quest.id = &"test_updated_objectives"
	var objective := QuestObjectiveDefinition.new()
	objective.target_id = &"berry"
	changed_quest.objectives = [objective, objective.duplicate() as QuestObjectiveDefinition]
	register(changed_quest)
	var progression := ProgressionState.new()
	var record: Dictionary = {"quest_id": String(changed_quest.id), "progress": [1], "completed": true, "reward_claimed": false}
	warnings = progression.restore({"quests": [record]}, ContentRegistry)
	t.assert_equal(progression.quest_states[changed_quest.id].progress, PackedInt32Array([1, 0]), "new quest objective pads saved progress")
	t.assert_true(not progression.quest_states[changed_quest.id].completed, "new incomplete objective prevents premature reward")
	record["progress"] = [1, 1, 999]
	progression.restore({"quests": [record]}, ContentRegistry)
	t.assert_equal(progression.quest_states[changed_quest.id].progress, PackedInt32Array([1, 1]), "removed quest objective trims saved progress")
	for version in [1, 2]:
		var migrated: Dictionary = SaveManager.migrate({"format_version": version, "game_state": {}})
		t.assert_equal(migrated["format_version"], 3, "legacy migration reaches v3")
		for key in ["active_effects", "death_drops", "pending_loot"]:
			t.assert_equal(migrated["game_state"][key], [], "migration adds empty %s" % key)

func test_world_and_climbing() -> void:
	GameSession.start_new_game()
	world = Node.new()
	t.add_child(world)
	SceneRouter.register_world_layer(world)
	t.assert_true(SceneRouter.go_to_settlement(), "stability settlement scene loads")
	await frames(3)
	var actor: PlayerActor = player()
	actor.survival.drain_paused = true
	actor.consume_item(&"berry")
	t.assert_equal(GameSession.player.effects.active_effects[&"quick_paws"].applied_by, &"berry", "effect records source item provenance")
	var speed: float = GameSession.player.stats.value(&"move_speed")
	var remaining: float = GameSession.player.effects.active_effects[&"quick_paws"].remaining
	var context: AdventureContext = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(SceneRouter.go_to_adventure(context), "effect-bearing expedition scene loads")
	await frames(3)
	actor = player()
	t.assert_equal(GameSession.player.stats.value(&"move_speed"), speed, "scene transition preserves effect modifier")
	t.assert_true(GameSession.player.effects.active_effects[&"quick_paws"].remaining <= remaining and GameSession.player.effects.active_effects[&"quick_paws"].remaining > remaining - 1.0, "scene transition preserves remaining effect time")
	var enemy: EnemyAgent
	for child in world.get_child(0).get_children():
		if child is EnemyAgent:
			enemy = child
	var rules: DifficultyDefinition = GameSession.current_difficulty()
	GameSession.set_difficulty(&"story")
	t.assert_equal(enemy.health.max_health, enemy.definition.max_health * rules.enemy_health_multiplier, "enemy health uses expedition snapshot")
	t.assert_equal(enemy.effect_stats.value(&"attack_power"), enemy.definition.attack_damage * rules.enemy_damage_multiplier, "enemy damage uses expedition snapshot")
	t.assert_equal(actor.survival.drain_multiplier, rules.survival_drain_multiplier, "survival uses expedition snapshot")
	t.assert_equal(GameSession.current_difficulty().loot_multiplier, rules.loot_multiplier, "loot rules use expedition snapshot")
	GameSession.player.effects.tick(100.0)
	t.assert_equal(actor.movement.speed, 190.0, "effect expiry updates live actor movement")
	# Range and faction filtering use the actual combat adapter and hurtbox.
	t.assert_true(actor.combat.attack(1.0), "melee attack executes")
	var shape := actor.combat.hitbox.get_node("CollisionShape2D").shape as RectangleShape2D
	t.assert_equal(shape.size.x, 52.0, "weapon attack_range controls actual hitbox")
	var hit := DamageContext.new(2.0, &"test", actor, &"player")
	hit.target_factions = [&"neutral"]
	t.assert_true(not enemy.hurtbox.receive_hit(hit), "target faction filter denies wrong faction")
	hit.target_factions = [&"hostile"]
	hit.hit_effects = [ContentRegistry.get_definition(&"quick_paws") as EffectDefinition]
	t.assert_true(enemy.hurtbox.receive_hit(hit), "target faction filter permits hostile")
	t.assert_true(enemy.effects.model.active_effects.has(&"quick_paws"), "hit effects reach victim model")
	await test_projectile(actor, enemy)
	var hp_effect := EffectDefinition.new()
	hp_effect.id = &"test_max_health"
	hp_effect.target_stat = &"max_health"
	hp_effect.magnitude = 50.0
	hp_effect.duration_seconds = 10.0
	GameSession.player.effects.apply_effect(hp_effect)
	GameSession.player.set_health(140.0)
	GameSession.player.effects.apply_effect(hp_effect)
	t.assert_equal(actor.health.current_health, 140.0, "max health refresh does not transiently remove bonus")
	GameSession.player.effects.remove_effect(hp_effect.id)
	t.assert_equal(actor.health.current_health, 100.0, "max health expiry clamps live and persistent vitals")
	actor.global_position = Vector2(1200, 517)
	actor.velocity = Vector2.ZERO
	await frames(3)
	Input.action_press(&"move_up")
	await frames(8)
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "W outside volume never starts climb")
	Input.action_release(&"move_up")
	var ladder := world.get_child(0).get_node("EmergencyLadder") as ClimbableArea2D
	actor.global_position = ladder.bottom() + Vector2(15, 0)
	actor.velocity = Vector2.ZERO
	await frames(4)
	var x_before: float = actor.global_position.x
	Input.action_press(&"move_up")
	await frames(2)
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.CLIMB, "W inside ladder starts climb")
	t.assert_true(absf(actor.global_position.x - x_before) < 15.0, "climb alignment is gradual")
	await frames(20)
	var height: float = actor.global_position.y
	Input.action_release(&"move_up")
	await frames(15)
	t.assert_true(absf(actor.global_position.y - height) < 3.0, "climb with no input holds height")
	t.assert_equal(actor.velocity.y, 0.0, "climb gravity disabled")
	Input.action_press(&"move_down")
	await frames(8)
	t.assert_true(actor.global_position.y > height, "S descends ladder")
	Input.action_release(&"move_down")
	actor._on_quick_item()
	t.assert_equal(actor.return_channel, 0.0, "return channel cannot begin during climb")
	t.assert_true(not actor.combat.attack(1.0), "attack cannot begin during climb")
	actor.input.jump_requested.emit()
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB and actor.velocity.y < 0.0, "jump detaches and restores airborne movement")
	await frames(20)
	actor.global_position = ladder.bottom()
	actor.velocity = Vector2.ZERO
	await frames(4)
	Input.action_press(&"move_up")
	await frames(12)
	actor.movement.on_damage()
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "ladder damage policy drops player")
	Input.action_release(&"move_up")
	await frames(4)
	actor.global_position = ladder.bottom()
	actor.velocity = Vector2.ZERO
	await frames(4)
	actor._on_quick_item()
	Input.action_press(&"move_up")
	actor.movement.physics_tick(0.016)
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "return channel blocks climb entry")
	actor._cancel_return_channel()
	Input.action_release(&"move_up")
	await frames(4)
	# Complete actual climb, land on the one-way platform and interact at the top.
	Input.action_press(&"move_up")
	await frames(175)
	Input.action_release(&"move_up")
	await frames(8)
	t.assert_true(actor.global_position.y <= ladder.top().y + 3.0, "actual ladder climb reaches upper landing")
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "top exit restores ordinary movement")
	t.assert_true(actor.is_on_floor(), "upper one-way landing does not trap player")
	var escape: EscapePoint2D
	for child in world.get_child(0).get_children():
		if child is EscapePoint2D and child.interaction_id == &"sewer_ladder":
			escape = child
	t.assert_true(escape != null and escape.can_interact(actor), "upper escape available only after climb")
	actor._on_interact()
	await frames(4)
	t.assert_true(GameSession.adventure.active_session == null, "ladder-top E interaction ends expedition")
	t.assert_true(player().movement.mode != MovementComponent.Mode.CLIMB, "scene transition resets climb mode")
	# Real death -> delay -> settlement -> new actor, including recoverable world object.
	GameSession.set_difficulty(&"survival")
	context = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	SceneRouter.go_to_adventure(context)
	await frames(4)
	actor = player()
	GameSession.collect_adventure_loot(&"rusty_scrap", 3)
	var death_position: Vector2 = actor.global_position
	actor.health.receive_damage(DamageContext.new(9999, &"test", t, &"test"))
	await frames(70)
	t.assert_true(player() != actor, "death creates a new player actor")
	t.assert_true(player().health.current_health > 0.0, "new settlement actor has positive respawn health")
	t.assert_equal(GameSession.phase, GameSession.Phase.SETTLEMENT, "death completes settlement transition")
	context = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	SceneRouter.go_to_adventure(context)
	await frames(4)
	t.assert_equal(t.get_tree().get_nodes_in_group(&"death_drop").size(), 1, "return to region spawns one recovery object")
	var drop_node := t.get_tree().get_first_node_in_group(&"death_drop") as InteractionTarget
	t.assert_equal(drop_node.global_position, death_position, "recovery object uses recorded death location")
	t.assert_true(drop_node.interact(player()), "world recovery interaction works")
	t.assert_true(GameSession.adventure.death_drops.is_empty(), "world recovery removes completed record")
	var recovered_count: int = GameSession.adventure.active_session.unsecured_loot.count(&"rusty_scrap")
	var recovered_death: RespawnResult = GameSession.handle_player_death(GameSession.get_local_peer_id(), death_position)
	t.assert_equal(_count(recovered_death.drops[0].items, &"rusty_scrap"), recovered_count, "recovered unsecured loot transfers to next death record")
	SceneRouter.go_to_settlement()
	context = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	SceneRouter.go_to_adventure(context)
	await frames(4)
	# Rope speed and bottom exit use the same reusable movement component.
	actor = player()
	var rope := world.get_child(0).get_node("TestRope") as ClimbableArea2D
	actor.global_position = rope.bottom()
	actor.velocity = Vector2.ZERO
	await frames(4)
	Input.action_press(&"move_up")
	await frames(10)
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.CLIMB, "rope supports climb entry")
	t.assert_true(is_equal_approx(absf(actor.velocity.y), actor.movement.speed * rope.definition.speed_multiplier), "rope speed follows Resource multiplier")
	t.assert_true(rope.definition.speed_multiplier != ladder_speed(), "ladder and rope have distinct configured speeds")
	rope.definition = rope.definition.duplicate() as ClimbableDefinition
	rope.definition.drop_on_damage = false
	actor.movement.on_damage()
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.CLIMB, "configured rope retains climb on ordinary damage")
	actor.movement.on_damage(true)
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "forced knockback always exits climb")
	Input.action_release(&"move_up")
	await frames(2)
	actor.global_position = rope.bottom() - Vector2(0, 20)
	actor.velocity = Vector2.ZERO
	await frames(3)
	Input.action_press(&"move_down")
	await frames(15)
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "bottom exit restores ordinary movement")
	Input.action_release(&"move_down")
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	world.queue_free()
	await frames(3)
	GameSession.start_new_game()

func ladder_speed() -> float:
	return (ContentRegistry.get_definition(&"ladder_default") as ClimbableDefinition).speed_multiplier

func player() -> PlayerActor:
	return t.get_tree().get_first_node_in_group(&"player") as PlayerActor

func frames(count: int) -> void:
	for index in count:
		await t.get_tree().physics_frame
	await t.get_tree().process_frame

func _count(items: Array[ItemStack], id: StringName) -> int:
	var total: int = 0
	for stack in items:
		if stack.item_id == id:
			total += stack.quantity
	return total

func _cleanup(path: String) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bak"))

func test_projectile(actor: PlayerActor, enemy: EnemyAgent) -> void:
	var weapon := WeaponDefinition.new()
	weapon.id = &"test_projectile"
	weapon.display_name = "Test projectile"
	weapon.attack_mode = WeaponDefinition.AttackMode.PROJECTILE
	weapon.attack_range = 180.0
	weapon.attack_scene = load("res://tests/fixtures/projectile_attack.tscn") as PackedScene
	t.assert_true(weapon.validate_definition(ContentRegistry).is_empty(), "valid projectile scene accepted")
	var strategy := ProjectileAttackStrategy.new()
	enemy.set_physics_process(false)
	enemy.global_position = actor.global_position + Vector2(80, 0)
	enemy.health.invulnerable_remaining = 0.0
	var before: float = enemy.health.current_health
	var context := DamageContext.new(3.0, &"projectile", actor, &"player")
	context.target_factions = [&"hostile"]
	t.assert_true(strategy.execute(weapon, context, actor, actor.combat.hitbox, 1.0), "projectile strategy spawns scene")
	await frames(20)
	t.assert_true(enemy.health.current_health < before, "projectile moves and hits actual hostile hurtbox")
	await frames(18)
	var count: int = 0
	for child in actor.get_parent().get_children():
		if child is ProjectileAttack:
			count += 1
	t.assert_equal(count, 0, "projectile removes itself at configured range")
	enemy.set_physics_process(true)
	weapon.attack_scene = load("res://gameplay/actors/player/player.tscn") as PackedScene
	t.assert_true(not weapon.validate_definition(ContentRegistry).is_empty(), "wrong projectile root rejected by validator")

func test_hud() -> void:
	GameSession.start_new_game()
	var hud: CanvasLayer = load("res://ui/game_hud.gd").new()
	t.add_child(hud)
	GameSession.set_difficulty(&"survival")
	GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE)
	var path: String = "user://hud_sync_test.json"
	SaveManager.save_game(path)
	GameSession.set_difficulty(&"normal")
	GameSession.clear_difficulty_override(&"inventory_loss")
	t.assert_true(SaveManager.load_game(path), "HUD test reloads actual save")
	t.assert_equal(hud.difficulty.get_item_metadata(hud.difficulty.selected), &"survival", "loaded difficulty reflected in OptionButton")
	t.assert_true(hud.no_loss.button_pressed, "loaded override reflected in checkbox")
	t.assert_true(not hud.save_button.disabled and not hud.load_button.disabled, "settlement HUD permits persistence")
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(hud.save_button.disabled and hud.load_button.disabled and hud.difficulty.disabled and hud.no_loss.disabled, "expedition HUD locks all persistence and difficulty controls")
	t.assert_true(not hud.load_button.tooltip_text.is_empty(), "locked HUD explains reason")
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	hud.queue_free()
	await frames(2)
	_cleanup(path)

func test_input_map() -> void:
	var bindings: Dictionary[StringName, Key] = {&"move_left": KEY_A, &"move_right": KEY_D, &"move_up": KEY_W, &"move_down": KEY_S}
	for action in bindings:
		var key := InputEventKey.new()
		key.physical_keycode = bindings[action]
		key.pressed = true
		Input.parse_input_event(key)
		Input.flush_buffered_events()
		t.assert_true(Input.is_action_pressed(action), "physical key maps to action: %s" % action)
		var released := key.duplicate() as InputEventKey
		released.pressed = false
		Input.parse_input_event(released)
		Input.flush_buffered_events()
