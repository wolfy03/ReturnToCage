class_name PersonalProgressionState
extends RefCounted

var player_id: StringName
var quest_states: Dictionary[StringName, QuestState] = {}

func _init(p_player_id: StringName = &"") -> void:
	player_id = p_player_id
