@tool
extends Tree

signal drag_started(entry: Dictionary)

func _get_drag_data(at_position: Vector2) -> Variant:
	var item := get_item_at_position(at_position)
	if item == null or not item.get_metadata(0) is Dictionary:
		return null
	var entry: Dictionary = item.get_metadata(0)
	var preview := Label.new()
	preview.text = entry.label
	set_drag_preview(preview)
	drag_started.emit(entry)
	return entry
