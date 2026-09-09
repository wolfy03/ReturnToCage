extends RefCounted

var _player_states: Dictionary[StringName, PlayerState] = {}
var _test_ids: Array[StringName] = []

func run(t: Node) -> void:
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition
	var progression := ProgressionState.new()
	progression.reset(start)
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	settlement.reset(start, ContentRegistry)
	for player_id in [&"player_a", &"player_b", &"player_c"]:
		progression.ensure_personal_progression(player_id)
		var state := PlayerState.new(Callable(ContentRegistry, "get_item"))
		state.reset(start, ContentRegistry)
		_player_states[player_id] = state
	var personal_kill := _quest(&"_test_personal_kill", QuestDefinition.Scope.PERSONAL, QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, &"sewer_beetle")
	var party_kill := _quest(&"_test_party_kill", QuestDefinition.Scope.PARTY, QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, &"sewer_beetle")
	var personal_collect := _quest(&"_test_personal_collect", QuestDefinition.Scope.PERSONAL, QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry")
	var party_collect := _quest(&"_test_party_collect", QuestDefinition.Scope.PARTY, QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry")
	_test_scope_validation(t, personal_kill)
	var system := QuestSystem.new(progression, settlement, ContentRegistry, Callable(self, "_resolve_player_state"))
	for player_id in _player_states:
		t.assert_true(system.start_quest(personal_kill.id, player_id).success, "personal quest starts for %s" % player_id)
		t.assert_true(system.start_quest(personal_collect.id, player_id).success, "personal collect quest starts for %s" % player_id)
	t.assert_true(system.start_quest(party_kill.id, &"player_a").success, "party quest starts once in shared state")
	t.assert_true(system.start_quest(party_collect.id, &"player_a").success, "party collect quest starts once")

	system.report(GameplayEvent.kill_enemy(&"player_b", &"sewer_beetle"))
	t.assert_equal(_personal_state(progression, &"player_b", personal_kill.id).progress[0], 1, "killer receives PERSONAL kill credit")
	t.assert_equal(_personal_state(progression, &"player_a", personal_kill.id).progress[0], 0, "other player does not receive PERSONAL kill credit")
	t.assert_equal(_personal_state(progression, &"player_c", personal_kill.id).progress[0], 0, "third player personal progress remains isolated")
	t.assert_equal(progression.shared_quest_states[party_kill.id].progress[0], 1, "same kill advances shared PARTY quest")
	system.report(GameplayEvent.kill_enemy(&"", &"sewer_beetle"))
	t.assert_equal(progression.shared_quest_states[party_kill.id].progress[0], 1, "environment kill grants no quest credit")

	system.report(GameplayEvent.collect_item(&"player_b", &"berry", 1))
	t.assert_equal(_personal_state(progression, &"player_b", personal_collect.id).progress[0], 1, "collector receives PERSONAL collect credit")
	t.assert_equal(_personal_state(progression, &"player_a", personal_collect.id).progress[0], 0, "personal collect does not leak to another owner")
	t.assert_equal(progression.shared_quest_states[party_collect.id].progress[0], 1, "collect event also advances shared PARTY objective")

	var a_before := _player_states[&"player_a"].inventory.count(&"berry")
	var b_before := _player_states[&"player_b"].inventory.count(&"berry")
	var c_before := _player_states[&"player_c"].inventory.count(&"berry")
	var storage_before := settlement.storage.count(&"berry")
	t.assert_true(system.claim_reward(personal_kill.id, &"player_b").success, "PERSONAL reward is claimable by its owner")
	t.assert_equal(_player_states[&"player_b"].inventory.count(&"berry"), b_before + 1, "PERSONAL reward enters owner PlayerState inventory")
	t.assert_equal(_player_states[&"player_a"].inventory.count(&"berry"), a_before, "PERSONAL reward leaves A unchanged")
	t.assert_equal(_player_states[&"player_c"].inventory.count(&"berry"), c_before, "PERSONAL reward leaves C unchanged")
	t.assert_equal(settlement.storage.count(&"berry"), storage_before, "PERSONAL reward does not enter shared storage")
	t.assert_true(system.claim_reward(party_kill.id, &"player_a").success, "PARTY reward commits to settlement storage")
	t.assert_equal(settlement.storage.count(&"berry"), storage_before + 1, "PARTY reward destination remains shared storage")
	t.assert_true(not system.claim_reward(party_kill.id, &"player_b").success, "concurrent PARTY reward claim cannot duplicate reward")

	_test_snapshot_validation(t, progression, personal_kill)
	var save := progression.to_save_dict()
	t.assert_equal((save["quests"] as Array).size(), 2, "Save v3 exports shared quests only")
	_cleanup()

func _quest(id: StringName, scope: QuestDefinition.Scope, type: QuestObjectiveDefinition.ObjectiveType, target: StringName) -> QuestDefinition:
	var objective := QuestObjectiveDefinition.new()
	objective.type = type
	objective.target_id = target
	objective.required_amount = 1
	var definition := QuestDefinition.new()
	definition.id = id
	definition.title = String(id)
	definition.scope = scope
	definition.objectives = [objective]
	definition.reward_item_ids = [&"berry"]
	definition.reward_amounts = [1]
	ContentRegistry._definitions[id] = definition
	_test_ids.append(id)
	return definition

func _resolve_player_state(player_id: StringName) -> PlayerState:
	return _player_states.get(player_id)

func _personal_state(progression: ProgressionState, player_id: StringName, quest_id: StringName) -> QuestState:
	return progression.get_personal_progression(player_id).quest_states[quest_id]

func _test_snapshot_validation(t: Node, progression: ProgressionState, definition: QuestDefinition) -> void:
	var state := _personal_state(progression, &"player_b", definition.id)
	var snapshot := QuestStateSnapshot.from_state(definition, state, &"player_b", progression.quest_revision(definition.id, &"player_b"))
	var parsed := QuestStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry, &"player_b")
	t.assert_true(parsed.error_message.is_empty() and parsed.owner_player_id == &"player_b", "personal quest snapshot validates for its local owner")
	t.assert_true(not QuestStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry, &"player_a").error_message.is_empty(), "personal snapshot for another local player is rejected")
	var malformed := snapshot.to_payload()
	malformed["progress"] = [-1]
	t.assert_true(not QuestStateSnapshot.from_payload(malformed, ContentRegistry, &"player_b").error_message.is_empty(), "negative quest snapshot progress is rejected")
	malformed = snapshot.to_payload()
	malformed["owner_player_id"] = ""
	t.assert_true(not QuestStateSnapshot.from_payload(malformed, ContentRegistry, &"player_b").error_message.is_empty(), "empty personal quest snapshot owner is rejected")
	malformed = snapshot.to_payload()
	malformed["quest_id"] = "missing_quest"
	t.assert_true(not QuestStateSnapshot.from_payload(malformed, ContentRegistry, &"player_b").error_message.is_empty(), "unknown quest snapshot is rejected")
	var mirror := ProgressionState.new()
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition
	mirror.reset(start)
	mirror.ensure_personal_progression(&"player_b")
	t.assert_true(mirror.accept_quest_revision(definition.id, &"player_b", 5), "new quest revision is accepted")
	t.assert_true(not mirror.accept_quest_revision(definition.id, &"player_b", 5), "stale quest revision is rejected")

func _test_scope_validation(t: Node, personal_dependency: QuestDefinition) -> void:
	var invalid_scope := _quest(&"_test_invalid_scope", QuestDefinition.Scope.PARTY, QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry")
	invalid_scope.scope = 99 as QuestDefinition.Scope
	t.assert_true(_has_error(invalid_scope.validate_definition(ContentRegistry), "invalid quest scope"), "quest content rejects an invalid scope enum")
	var invalid_party_dependency := _quest(&"_test_invalid_party_dependency", QuestDefinition.Scope.PARTY, QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, &"berry")
	invalid_party_dependency.prerequisite_quest_ids = [personal_dependency.id]
	t.assert_true(_has_error(invalid_party_dependency.validate_definition(ContentRegistry), "incompatible quest scope dependency"), "PARTY quest cannot depend on PERSONAL completion")

func _has_error(errors: PackedStringArray, fragment: String) -> bool:
	for error in errors:
		if error.contains(fragment):
			return true
	return false

func _cleanup() -> void:
	for id in _test_ids:
		ContentRegistry._definitions.erase(id)
	_test_ids.clear()
	_player_states.clear()
