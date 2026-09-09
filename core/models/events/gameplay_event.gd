class_name GameplayEvent
extends RefCounted

var type: QuestObjectiveDefinition.ObjectiveType
var actor_player_id: StringName = &""
var target_id: StringName = &""
var amount: int = 1

func _init(
	p_type: QuestObjectiveDefinition.ObjectiveType = QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM,
	p_actor_player_id: StringName = &"",
	p_target_id: StringName = &"",
	p_amount: int = 1
) -> void:
	type = p_type
	actor_player_id = p_actor_player_id
	target_id = p_target_id
	amount = p_amount

static func kill_enemy(player_id: StringName, enemy_id: StringName) -> GameplayEvent:
	return GameplayEvent.new(QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, player_id, enemy_id, 1)

static func collect_item(player_id: StringName, item_id: StringName, quantity: int) -> GameplayEvent:
	return GameplayEvent.new(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, player_id, item_id, quantity)
