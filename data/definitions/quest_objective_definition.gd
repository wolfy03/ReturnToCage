class_name QuestObjectiveDefinition
extends Resource

enum ObjectiveType { COLLECT_ITEM, KILL_ENEMY, DISCOVER_POINT, UPGRADE_FACILITY, TALK_TO_NPC }

@export var type: ObjectiveType = ObjectiveType.COLLECT_ITEM
@export var target_id: StringName
@export_range(1, 9999, 1) var required_amount: int = 1
@export var description: String = ""
