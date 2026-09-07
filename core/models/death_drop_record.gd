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

func restore(data: Dictionary, registry: Node, instances: Dictionary[String, String] = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	id = SaveData.text_value(data, "id", "", errors)
	region_id = StringName(SaveData.text_value(data, "region_id", "", errors))
	session_id = SaveData.text_value(data, "session_id", "", errors)
	recovered = SaveData.boolean(data, "recovered", false, errors)
	position = SaveData.position(data, "position", Vector2.ZERO, errors)
	if not registry.get_definition(region_id) is RegionDefinition:
		errors.append("death drop retained for unavailable region: %s" % region_id)
	items.clear()
	if id.is_empty() or recovered:
		return errors
	var raw_items: Array = SaveData.array(data, "items", errors)
	for index in raw_items.size():
		var context: String = "death_drop[%s].items[%d]" % [id, index]
		# Preserve unavailable drop content for later recovery, unlike pending loot.
		var stack: ItemStack = StackValidation.from_record(raw_items[index], Callable(registry, "get_item"), errors, context, true)
		if stack != null and StackValidation.accept_instance(stack, instances, errors, context):
			items.append(stack)
	return errors
