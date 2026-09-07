extends RefCounted

func run(t: Node) -> void:
	GameSession.start_new_game()
	var path: String = "user://stability_boundary_save.json"
	var valid: Dictionary = GameSession.export_state()
	for version in [1, 2, 3]:
		var state: Dictionary = valid.duplicate(true)
		if version < 3:
			for key in ["active_effects", "death_drops", "pending_loot"]:
				state.erase(key)
		if version == 1:
			state.erase("difficulty_overrides")
			state.erase("protected_inventory")
		var envelope: Dictionary = {"format_version": version, "game_state": state}
		var before: Dictionary = envelope.duplicate(true)
		var migrated: Dictionary = SaveManager.migrate(envelope)
		t.assert_equal(migrated["format_version"], 3, "save version reaches current format")
		t.assert_equal(envelope, before, "migration never mutates input envelope")
		if version == 3:
			t.assert_equal(migrated, envelope, "v3 performs no migration")
		t._write_envelope(path, envelope)
		t.assert_true(SaveManager.load_game(path), "actual v%d save loads" % version)
	for version in ["3", 3.5, -1, 999, null, INF, NAN, 1e100, false]:
		t.assert_true(SaveManager.migrate({"format_version": version, "game_state": {}}).is_empty(), "malformed version rejected safely")
	var broken: Dictionary = valid.duplicate(true)
	broken["player_health"] = "wrong"
	broken["survival_state"] = {"hunger": -1000, "thirst": 100000}
	broken["player_inventory"] = [null, {"item_id": "berry", "quantity": 1, "instance_id": []}]
	broken["facility_levels"] = {"workbench": 99999}
	broken["resident_states"] = {"milo": []}
	broken["difficulty_overrides"] = {"enemy_health_multiplier": "hello", "inventory_loss": 999999, "loot_multiplier": -1}
	broken["pending_loot"] = [42, {"item_id": "missing", "quantity": 1}]
	broken["death_drops"] = [null, {"id": "bad", "region_id": "missing", "items": [{"item_id": "berry", "quantity": -1}]}]
	broken["active_effects"] = [null, {"effect_id": "quick_paws", "remaining": 99999, "stacks": 1e100, "food_slot": 1e100, "tick_elapsed": -5}]
	broken["last_safe_position"] = [1, "wrong"]
	var snapshot: SessionSnapshot = GameSession.prepare_restore(broken)
	t.assert_true(snapshot.fatal_error.is_empty(), "recoverable corrupted fields do not fail whole snapshot")
	t.assert_true(snapshot.warnings.size() >= 12, "corrupted fields produce actionable warnings")
	t.assert_true(snapshot.player.inventory.stacks().is_empty() and snapshot.settlement.pending_loot.is_empty(), "invalid items excluded from all storage")
	t.assert_true(is_finite(snapshot.player.health), "corrupted health produces finite state")
	t.assert_true(snapshot.difficulty.overrides.is_empty(), "invalid overrides omitted")
	t._write_envelope(path, {"format_version": 3, "game_state": broken})
	var messages: Array[String] = []
	var callback := func(_ok: bool, message: String) -> void: messages.append(message)
	SaveManager.load_finished.connect(callback)
	t.assert_true(SaveManager.load_game(path), "recoverable corrupted file loads")
	t.assert_true(messages[-1].begins_with("Game loaded with warnings"), "load exposes warnings to users")
	SaveManager.load_finished.disconnect(callback)
	var before: Dictionary = GameSession.export_state()
	broken["player_inventory"] = "fatal container"
	t._write_envelope(path, {"format_version": 3, "game_state": broken})
	t.assert_true(not SaveManager.load_game(path), "fatal malformed container rejected")
	t.assert_equal(GameSession.export_state(), before, "fatal load preserves every existing field")
	for property in DifficultyState.OVERRIDABLE_PROPERTIES:
		for value in ["hello", null, [], {}, INF, NAN, 1e100]:
			t.assert_true(not GameSession.difficulty.set_override(property, value), "invalid override type/range rejected: %s" % property)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	GameSession.start_new_game()
