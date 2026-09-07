class_name DeathDropRecord
extends RefCounted

var id: String = ""
var region_id: StringName
var position: Vector2
var items: Array[ItemStack] = []
var session_id: String = ""
var recovered: bool = false

func to_dict() -> Dictionary:
	var saved_items: Array[Dictionary] = []
	for stack in items:
		saved_items.append(stack.to_dict())
	return {"id": id, "region_id": String(region_id), "position": [position.x, position.y], "items": saved_items, "session_id": session_id, "recovered": recovered}

func restore(data: Dictionary, registry: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	id = SaveData.text_value(data, "id", "", errors)
	region_id = StringName(SaveData.text_value(data, "region_id", "", errors))
	session_id = SaveData.text_value(data, "session_id", "", errors)
	recovered = SaveData.boolean(data, "recovered", false, errors)
	position = SaveData.position(data, "position", Vector2.ZERO, errors)
	if not registry.get_definition(region_id) is RegionDefinition:
		errors.append("death drop retained for unavailable region: %s" % region_id)
	items.clear()
	for raw in SaveData.array(data, "items", errors):
		if raw is Dictionary and SaveData.valid_stack(raw, errors):
			var stack := ItemStack.from_dict(raw)
			if stack.quantity > 0:
				items.append(stack)
				if registry.get_item(stack.item_id) == null:
					errors.append("death drop retained for unavailable item: %s" % stack.item_id)
		else:
			errors.append("invalid death drop item")
	return errors
