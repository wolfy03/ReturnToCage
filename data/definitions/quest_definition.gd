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
		if not registry.get_definition(item_id) is ItemDefinition:
			errors.append("%s: missing reward item %s" % [id, item_id])
	for quest_id in prerequisite_quest_ids + follow_up_quest_ids:
		if not registry.get_definition(quest_id) is QuestDefinition:
			errors.append("%s: missing quest reference %s" % [id, quest_id])
	for amount in reward_amounts:
		if amount < 0:
			errors.append("%s: negative quest reward" % id)
	for objective in objectives:
		if objective == null or objective.required_amount < 1:
			errors.append("%s: invalid quest objective" % id)
			continue
		var target: ContentDefinition = registry.get_definition(objective.target_id)
		var valid: bool = true
		match objective.type:
			QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM:
				valid = target is ItemDefinition
			QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY:
				valid = target is EnemyDefinition
			QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY:
				valid = target is FacilityDefinition
			QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT:
				valid = false
				for content in registry.all_definitions():
					if content is RegionDefinition and content.escape_point_ids.has(objective.target_id):
						valid = true
			QuestObjectiveDefinition.ObjectiveType.TALK_TO_NPC:
				valid = false
				for content in registry.all_definitions():
					if content is GameStartDefinition:
						for resident in content.residents:
							if resident != null and resident.resident_id == objective.target_id:
								valid = true
			_:
				valid = false
		if not valid:
			errors.append("%s: quest objective target type mismatch: %s" % [id, objective.target_id])
	return errors
