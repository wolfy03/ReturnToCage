class_name ProgressionService
extends RefCounted

static func check_quest_start(id: StringName, progression: ProgressionState, registry: Node, player_id: StringName = &"") -> CommandResult:
	var definition := registry.get_definition(id) as QuestDefinition
	if definition == null:
		return CommandResult.make(false, "Unknown quest")
	if definition.scope == QuestDefinition.Scope.PERSONAL and player_id.is_empty():
		return CommandResult.make(false, "Personal quest requires a player")
	var previous: QuestState = progression.get_quest_state(id, player_id, registry)
	if previous != null and not (definition.repeatable and previous.completed and previous.reward_claimed):
		return CommandResult.make(false, "Quest already started")
	for required in definition.prerequisite_quest_ids:
		var state: QuestState = progression.get_quest_state(required, player_id, registry)
		if state == null or not state.completed:
			return CommandResult.make(false, "Prerequisite quest incomplete")
	# Follow-up-only quests are also gated by their parent reward claim.
	for content in registry.all_definitions():
		if content is QuestDefinition and content.follow_up_quest_ids.has(id):
			var parent: QuestState = progression.get_quest_state(content.id, player_id, registry)
			if parent == null or not parent.reward_claimed:
				return CommandResult.make(false, "Parent quest reward not claimed")
	return CommandResult.make(true)

static func facility_check(id: StringName, settlement: SettlementState, progression: ProgressionState, registry: Node) -> CommandResult:
	var definition := registry.get_definition(id) as FacilityDefinition
	if definition == null:
		return CommandResult.make(false, "Unknown facility")
	var next_level: int = settlement.facility_levels.get(id, 0) + 1
	if next_level > definition.max_level:
		return CommandResult.make(false, "Maximum level")
	for required in definition.prerequisite_facility_ids:
		if settlement.facility_levels.get(required, 0) < 1:
			return CommandResult.make(false, "Prerequisite facility missing")
	for required in definition.prerequisite_quest_ids:
		var quest: QuestState = progression.quest_states.get(required)
		if quest == null or not quest.completed:
			return CommandResult.make(false, "Prerequisite quest incomplete")
	var level: FacilityLevelDefinition = definition.get_level_data(next_level)
	if level == null:
		return CommandResult.make(false, "Missing facility level data")
	return settlement.storage.preview_exchange(item_amounts(level.cost_item_ids, level.cost_amounts), [])

static func item_amounts(ids: Array[StringName], amounts: Array[int]) -> Array[ItemStack]:
	var result: Array[ItemStack] = []
	for index in mini(ids.size(), amounts.size()):
		if amounts[index] > 0:
			result.append(ItemStack.new(ids[index], amounts[index]))
	return result
