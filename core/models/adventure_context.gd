class_name AdventureContext
extends RefCounted

var region_id: StringName
var settlement_exit_id: StringName
var entry_point_id: StringName
var difficulty_id: StringName
var prepared_inventory: Array[Dictionary] = []
var game_session_id: String = ""

func _init(p_region_id: StringName = &"", p_exit_id: StringName = &"", p_entry_id: StringName = &"entry", p_difficulty_id: StringName = &"normal", p_session_id: String = "") -> void:
	region_id = p_region_id
	settlement_exit_id = p_exit_id
	entry_point_id = p_entry_id
	difficulty_id = p_difficulty_id
	game_session_id = p_session_id
