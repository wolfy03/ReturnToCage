class_name AdventureState
extends RefCounted

var active_session: AdventureSession

func reset() -> void:
	active_session = null

func to_save_dict() -> Dictionary:
	# v1/v2 intentionally resume at the settlement, never inside an expedition.
	return {}

func restore(_data: Dictionary) -> PackedStringArray:
	reset()
	return PackedStringArray()
