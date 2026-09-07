extends RefCounted

func run(t: Node) -> void:
	var start: GameStartDefinition = GameSession.get_start_definition()
	var model := PlayerState.new(Callable(ContentRegistry, "get_item"))
	var healing := EffectDefinition.new()
	healing.id = &"reset_heal"
	healing.kind = EffectDefinition.EffectKind.PERIODIC_HEAL
	healing.magnitude = 2.0
	healing.duration_seconds = 10.0
	var vest := ItemStack.new(&"leaf_vest", 1)
	for iteration in 3:
		var old_stats: StatBlock = model.stats
		var old_effects: EffectRuntimeModel = model.effects
		model.reset(start, ContentRegistry)
		t.assert_true(model.effects.stats == model.stats, "reset connects canonical stats")
		t.assert_true(old_stats.stat_changed.get_connections().is_empty(), "reset disconnects retained old stats")
		t.assert_true(old_effects.periodic.get_connections().is_empty(), "reset disconnects retained old effect callback")
		t.assert_true(old_effects.paused, "retired effects cannot keep ticking")
		model.equipment.equip(vest)
		model.sync_equipment()
		t.assert_equal(model.stats.value(&"defense"), 2.0, "repeated reset never duplicates equipment modifier")
		model.set_health(50.0)
		old_effects.periodic.emit(20.0, false)
		old_stats.set_base(&"max_health", 1.0)
		t.assert_equal(model.health, 50.0, "retained old references cannot change live vitals")
		model.effects.apply_effect(healing)
		model.effects.tick(1.0)
		t.assert_equal(model.health, 52.0, "periodic callback runs exactly once after reset")
		t.assert_equal(model.effects.periodic.get_connections().size(), 1, "one periodic subscription")
		t.assert_equal(model.stats.stat_changed.get_connections().size(), 1, "one max health subscription")
		var saved: Dictionary = model.to_save_dict()
		saved["active_effects"] = [] # Local test effect is intentionally not registered content.
		old_stats = model.stats
		old_effects = model.effects
		model.restore(saved, start)
		t.assert_true(old_stats.stat_changed.get_connections().is_empty() and old_effects.periodic.get_connections().is_empty(), "restore detaches retired references")
		t.assert_equal(model.stats.value(&"defense"), 2.0, "restore rebuilds equipment once")
		t.assert_true(not model.effects.paused, "restore resumes new effect model")
		var signals: Array[int] = [0]
		var callback := func() -> void: signals[0] += 1
		model.vitals_changed.connect(callback)
		model.stats.set_base(&"max_health", 40.0)
		t.assert_equal(signals[0], 1, "max health clamp notifies once")
		model.vitals_changed.disconnect(callback)
	var warnings: PackedStringArray = model.restore({"player_health": -100}, start)
	t.assert_equal(model.health, 0.0, "PlayerState restore clamps negative health to zero")
	t.assert_true(not warnings.is_empty(), "health clamp warns")
	warnings = model.restore({"player_health": 99999}, start)
	t.assert_equal(model.health, model.stats.value(&"max_health"), "PlayerState clamps above maximum")
	for bad in [NAN, INF, "hello", [], null]:
		warnings = model.restore({"player_health": bad}, start)
		t.assert_true(not warnings.is_empty() and is_finite(model.health), "nonfinite and wrong health safely restored")
	warnings = model.restore({"last_safe_position": [1e300, 0]}, start)
	t.assert_true(not warnings.is_empty() and model.last_safe_position.is_finite(), "position rejects float32 overflow despite finite JSON number")
	var custom := start.duplicate(true) as GameStartDefinition
	custom.survival_config = start.survival_config.duplicate() as SurvivalConfig
	custom.survival_config.max_hunger = 80.0
	custom.survival_config.max_thirst = 140.0
	model.restore({"survival_state": {"hunger": -1000, "thirst": 100000, "progression_reduction": 999}}, custom)
	t.assert_equal(model.survival.hunger, 0.0, "domain survival clamps negative hunger")
	t.assert_equal(model.survival.thirst, 140.0, "domain survival respects configured maximum")
	t.assert_equal(model.survival.progression_reduction, 0.9, "domain progression reduction bounded")
	var source: String = FileAccess.get_file_as_string("res://autoload/game_session.gd")
	for name in ["player_stats", "player_inventory", "equipment", "settlement_storage", "protected_inventory", "quest_states", "facility_levels", "unlocked_regions", "unlocked_exits", "unlocked_flags", "discovered_escape_points", "resident_states", "difficulty_overrides", "active_adventure", "difficulty_id", "last_safe_position"]:
		var block: String = source.split("var %s:" % name)[1].split("\nvar ")[0]
		t.assert_true(not block.contains("set(value)"), "dangerous compatibility setter absent: %s" % name)
	GameSession.start_new_game()
	t.assert_true(GameSession.player_stats == GameSession.player.stats and GameSession.equipment == GameSession.player.equipment, "legacy object getters preserve canonical identity")
	t.assert_true(is_same(GameSession.facility_levels, GameSession.settlement.facility_levels), "legacy collection getter returns canonical object")
	var initial := StartingItemDefinition.new()
	initial.item_id = &"twig_sword"
	initial.instance_id = "explicit"
	initial.quantity = 2
	t.assert_true(initial.create_stack() == null, "starting instance quantity must be one")
	custom = start.duplicate(true) as GameStartDefinition
	custom.inventory_items = [initial]
	t.assert_true(not custom.validate_definition(ContentRegistry).is_empty(), "starting invalid instance rejected by content validation")
	initial.quantity = 1
	custom.protected_items = [initial]
	t.assert_true(not custom.validate_definition(ContentRegistry).is_empty(), "duplicate starting instance across containers rejected")
	custom.protected_items = []
	initial.durability = -2
	t.assert_true(not custom.validate_definition(ContentRegistry).is_empty(), "negative starting durability rejected")
	initial.durability = -1
	initial.instance_id = ""
	initial.quantity = 100
	custom.inventory_capacity = 1
	t.assert_true(not custom.validate_definition(ContentRegistry).is_empty(), "logically impossible starting capacity rejected")
