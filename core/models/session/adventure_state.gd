class_name AdventureState
extends RefCounted
var active_session: AdventureSession
var death_drops: Array[DeathDropRecord] = []

func reset() -> void:
	active_session = null
	death_drops.clear()

func to_save_dict() -> Dictionary:
	var drops: Array[Dictionary] = []
	for record in death_drops:
		drops.append(record.to_dict())
	return {"death_drops": drops}

func restore(data: Dictionary) -> PackedStringArray:
	reset()
	var errors := PackedStringArray()
	var ids: Array[String] = []
	for raw in SaveData.array(data, "death_drops", errors):
		if not raw is Dictionary:
			errors.append("invalid death drop record")
			continue
		var record := DeathDropRecord.new()
		errors.append_array(record.restore(raw, ContentRegistry))
		if record.id.is_empty() or ids.has(record.id):
			errors.append("empty or duplicate death drop id")
			continue
		ids.append(record.id)
		if not record.recovered and not record.items.is_empty():
			death_drops.append(record)
	return errors

func recover_drop(id: String) -> CommandResult:
	if active_session == null:
		return CommandResult.make(false, "Death drops can only be recovered during an expedition")
	for record in death_drops:
		if record.id != id or record.region_id != active_session.context.region_id or record.recovered:
			continue
		var remaining: Array[ItemStack] = []
		for stack in record.items:
			var added: InventoryResult = active_session.unsecured_loot.add_stack(stack)
			if added.remainder > 0:
				var rest := stack.duplicate_stack()
				rest.quantity = added.remainder
				remaining.append(rest)
		record.items = remaining
		if remaining.is_empty():
			record.recovered = true
			death_drops.erase(record)
			return CommandResult.make(true, "Death drop recovered")
		return CommandResult.make(false, "Unsecured loot full; remainder stays at death site", remaining)
	return CommandResult.make(false, "Death drop unavailable")
