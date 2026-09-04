class_name QuestDefinition
extends ContentDefinition

@export var title: String = ""
@export_multiline var description: String = ""
@export var prerequisite_quest_ids: Array[StringName] = []
@export var objectives: Array[QuestObjectiveDefinition] = []
@export var reward_item_ids: Array[StringName] = []
@export var reward_amounts: Array[int] = []
@export var follow_up_quest_ids: Array[StringName] = []
@export var repeatable: bool = false

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if objectives.is_empty():
		errors.append("%s: quest has no objectives" % id)
	if reward_item_ids.size() != reward_amounts.size():
		errors.append("%s: quest reward arrays differ" % id)
	for item_id in reward_item_ids:
		if not registry.has_id(item_id):
			errors.append("%s: missing reward item %s" % [id, item_id])
	for quest_id in prerequisite_quest_ids + follow_up_quest_ids:
		if not registry.has_id(quest_id):
			errors.append("%s: missing quest reference %s" % [id, quest_id])
	for objective in objectives:
		if objective.type in [QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY] and not registry.has_id(objective.target_id):
			errors.append("%s: missing objective target %s" % [id, objective.target_id])
	return errors
