class_name QuestState
extends RefCounted

signal changed

var quest_id: StringName
var progress: PackedInt32Array = PackedInt32Array()
var completed: bool = false
var reward_claimed: bool = false

func _init(p_quest_id: StringName = &"") -> void:
	quest_id = p_quest_id

func initialize(definition: QuestDefinition) -> void:
	progress.resize(definition.objectives.size())
	progress.fill(0)

func apply_event(definition: QuestDefinition, objective_type: QuestObjectiveDefinition.ObjectiveType, target_id: StringName, amount: int = 1) -> bool:
	if completed:
		return false
	var updated := false
	for index in definition.objectives.size():
		var objective := definition.objectives[index]
		if objective.type == objective_type and objective.target_id == target_id:
			progress[index] = mini(objective.required_amount, progress[index] + amount)
			updated = true
	completed = true
	for index in definition.objectives.size():
		if progress[index] < definition.objectives[index].required_amount:
			completed = false
			break
	if updated:
		changed.emit()
	return updated

func to_dict() -> Dictionary:
	return {"quest_id": String(quest_id), "progress": Array(progress), "completed": completed, "reward_claimed": reward_claimed}

static func from_dict(data: Dictionary) -> QuestState:
	var state := QuestState.new(StringName(str(data.get("quest_id", ""))))
	state.progress = PackedInt32Array(data.get("progress", []))
	state.completed = bool(data.get("completed", false))
	state.reward_claimed = bool(data.get("reward_claimed", false))
	return state
