extends RefCounted

func run(t: Node) -> void:
	GameSession.start_new_game()
	var path: String = "user://reward_signal_boundary.json"
	GameSession.settlement.storage.clear()
	GameSession.settlement.pending_loot = [ItemStack.new(&"berry", 2)]
	var saves: Array[bool] = []
	var snapshots: Array[Dictionary] = []
	var capture := func() -> void:
		snapshots.append(GameSession.export_state())
		if saves.is_empty():
			saves.append(SaveManager.save_game(path))
	GameSession.storage_changed.connect(capture)
	t.assert_true(GameSession.claim_pending_loot().success, "pending claim succeeds with synchronous save observer")
	GameSession.storage_changed.disconnect(capture)
	t.assert_equal(saves, [true], "pending observer saves successfully")
	t.assert_equal(snapshots.size(), 1, "pending claim publishes one committed notification")
	for snapshot in snapshots:
		t.assert_true(snapshot["pending_loot"].is_empty(), "observer sees cleared pending source")
	t.assert_true(SaveManager.load_game(path), "pending observer save loads")
	GameSession.claim_pending_loot()
	t.assert_equal(GameSession.settlement.storage.count(&"berry"), 2, "save/load/reclaim cannot duplicate pending reward")

	var quest := QuestDefinition.new()
	quest.id = &"test_signal_reward"
	quest.reward_item_ids = [&"berry"]
	quest.reward_amounts = [2]
	var objective := QuestObjectiveDefinition.new()
	objective.target_id = &"berry"
	objective.required_amount = 3
	quest.objectives = [objective]
	ContentRegistry._definitions[quest.id] = quest
	GameSession.start_quest(quest.id)
	GameSession.report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry", 3)
	GameSession.settlement.storage.clear()
	saves.clear()
	snapshots.clear()
	GameSession.storage_changed.connect(capture)
	t.assert_true(GameSession.claim_quest_reward(quest.id), "quest reward succeeds with synchronous save observer")
	GameSession.storage_changed.disconnect(capture)
	t.assert_equal(saves, [true], "quest claim publishes one committed notification")
	for snapshot in snapshots:
		for record in snapshot["quests"]:
			if record["quest_id"] == String(quest.id):
				t.assert_true(record["reward_claimed"], "observer sees committed quest reward flag")
	t.assert_true(SaveManager.load_game(path), "quest observer save loads")
	t.assert_true(not GameSession.claim_quest_reward(quest.id), "saved reward cannot be claimed again")
	t.assert_equal(GameSession.settlement.storage.count(&"berry"), 2, "quest save/load/reclaim preserves quantity")

	for value in [1e100, -3, 1.5, INF, NAN, "3", null, 99999, 2.0]:
		var state := ProgressionState.new()
		var warnings: PackedStringArray = state.restore({"quests": [{"quest_id": String(quest.id), "progress": [value]}]}, ContentRegistry)
		var expected: int = 2 if value is float and value == 2.0 else (3 if value is int and value == 99999 else 0)
		t.assert_equal(state.quest_states[quest.id].progress[0], expected, "quest progress validates before integer conversion: %s" % str(value))
		var progress_warnings: int = 0
		for warning in warnings:
			if "quest progress" in warning:
				progress_warnings += 1
		t.assert_equal(progress_warnings, 0 if expected == 2 else 1, "one specific progress warning per malformed value")
	ContentRegistry._definitions.erase(quest.id)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path + ".bak"))
	GameSession.start_new_game()
