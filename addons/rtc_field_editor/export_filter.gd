@tool
extends EditorExportPlugin

func _get_name() -> String:
	return "ReturnToCageFieldEditor"

func _export_file(path: String, _type: String, _features: PackedStringArray) -> void:
	if path.begins_with("res://addons/rtc_field_editor/"):
		skip()
