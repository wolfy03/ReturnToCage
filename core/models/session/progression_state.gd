class_name ProgressionState
extends RefCounted

var quest_states: Dictionary[StringName, QuestState] = {}
var unlocked_regions: Array[StringName] = []
var unlocked_exits: Array[StringName] = []
var unlocked_flags: Array[StringName] = []
var discovered_escape_points: Array[StringName] = []

func reset(start: GameStartDefinition) -> void:
	quest_states.clear()
	unlocked_regions = start.unlocked_regions.duplicate()
	unlocked_exits = start.unlocked_exits.duplicate()
	unlocked_flags = start.unlocked_flags.duplicate()
	discovered_escape_points = start.discovered_escape_points.duplicate()

func to_save_dict() -> Dictionary:
	var quests: Array[Dictionary] = []
	for state in quest_states.values():
		quests.append(state.to_dict())
	return {
		"quests": quests, "unlocked_regions": SaveData.strings(unlocked_regions),
		"unlocked_exits": SaveData.strings(unlocked_exits), "unlocked_flags": SaveData.strings(unlocked_flags),
		"discovered_escape_points": SaveData.strings(discovered_escape_points)
	}

func restore(data: Dictionary, registry: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	quest_states.clear()
	for raw in SaveData.array(data, "quests", errors):
		if not raw is Dictionary:
			errors.append("invalid quest record in save")
			continue
		var quest_id := StringName(SaveData.text_value(raw, "quest_id", "", errors))
		var definition := registry.get_definition(quest_id) as QuestDefinition
		if definition == null:
			errors.append("unknown quest in save: %s" % quest_id)
			continue
		var state := QuestState.new(quest_id)
		state.initialize(definition)
		var progress: Array = SaveData.array(raw, "progress", errors)
		if progress.size() != state.progress.size():
			errors.append("quest progress length differs in save: %s" % quest_id)
		for index in mini(progress.size(), state.progress.size()):
			if not SaveData.is_integer(progress[index]):
				errors.append("invalid quest progress in save: %s[%d], expected bounded integer" % [quest_id, index])
				continue
			var raw_progress: int = int(progress[index])
			state.progress[index] = clampi(raw_progress, 0, definition.objectives[index].required_amount)
			if state.progress[index] != raw_progress:
				errors.append("quest progress clamped in save: %s[%d] from %d to %d" % [quest_id, index, raw_progress, state.progress[index]])
		state.completed = SaveData.boolean(raw, "completed", false, errors)
		state.reward_claimed = SaveData.boolean(raw, "reward_claimed", false, errors)
		if not state.reward_claimed:
			var complete: bool = true
			for index in definition.objectives.size():
				if state.progress[index] < definition.objectives[index].required_amount:
					complete = false
			if complete != state.completed:
				errors.append("quest completion reconciled with objectives: %s" % quest_id)
			state.completed = complete
		quest_states[quest_id] = state
	unlocked_regions = SaveData.names(data, "unlocked_regions", errors)
	unlocked_exits = SaveData.names(data, "unlocked_exits", errors)
	unlocked_flags = SaveData.names(data, "unlocked_flags", errors)
	discovered_escape_points = SaveData.names(data, "discovered_escape_points", errors)
	return errors
