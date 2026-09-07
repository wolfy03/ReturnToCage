class_name ResidentState
extends RefCounted

var resident_id: StringName
var unlocked: bool = false
var current_state: StringName = &"idle"

func _init(id: StringName = &"") -> void:
	resident_id = id

func to_dict() -> Dictionary:
	# Identity remains the outer key in the v1/v2 resident_states object.
	return {"unlocked": unlocked, "state": String(current_state)}

func restore(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	unlocked = SaveData.boolean(data, "unlocked", false, errors)
	current_state = StringName(SaveData.text_value(data, "state", "idle", errors))
	return errors
