class_name SettlementStateSnapshot
extends RefCounted

var revision: int = 0
var storage_capacity: int = 0
var storage: Array[ItemStack] = []
var pending_loot: Array[ItemStack] = []
var facility_levels: Dictionary[StringName, int] = {}
var resident_states: Dictionary[StringName, ResidentState] = {}
var error_message: String = ""

func to_payload() -> Dictionary:
	var storage_payload: Array[Dictionary] = []
	for stack in storage:
		storage_payload.append(stack.to_dict())
	var pending_payload: Array[Dictionary] = []
	for stack in pending_loot:
		pending_payload.append(stack.to_dict())
	var facilities: Array[Dictionary] = []
	for facility_id in facility_levels:
		facilities.append({"facility_id": String(facility_id), "level": facility_levels[facility_id]})
	var residents: Array[Dictionary] = []
	for resident_id in resident_states:
		var state: ResidentState = resident_states[resident_id]
		residents.append({"resident_id": String(resident_id), "unlocked": state.unlocked, "state": String(state.current_state)})
	return {
		"revision": revision,
		"storage_capacity": storage_capacity,
		"storage": storage_payload,
		"pending_loot": pending_payload,
		"facility_levels": facilities,
		"resident_states": residents,
	}

static func from_state(state: SettlementState) -> SettlementStateSnapshot:
	var result := SettlementStateSnapshot.new()
	result.revision = state.revision
	result.storage_capacity = state.storage.capacity
	result.storage = state.storage.stacks()
	for stack in state.pending_loot:
		result.pending_loot.append(stack.duplicate_stack())
	result.facility_levels = state.facility_levels.duplicate()
	for resident_id in state.resident_states:
		var source: ResidentState = state.resident_states[resident_id]
		var resident := ResidentState.new(source.resident_id)
		resident.unlocked = source.unlocked
		resident.current_state = source.current_state
		result.resident_states[resident_id] = resident
	return result

static func from_payload(payload: Dictionary, registry: Node) -> SettlementStateSnapshot:
	var result := SettlementStateSnapshot.new()
	if not payload.get("revision", null) is int or payload["revision"] < 0 \
			or not payload.get("storage_capacity", null) is int or payload["storage_capacity"] < 1 \
			or not payload.get("storage", null) is Array \
			or not payload.get("pending_loot", null) is Array \
			or not payload.get("facility_levels", null) is Array \
			or not payload.get("resident_states", null) is Array:
		result.error_message = "Invalid settlement snapshot fields"
		return result
	result.revision = payload["revision"]
	result.storage_capacity = payload["storage_capacity"]
	var raw_storage: Array = payload["storage"]
	if raw_storage.size() > result.storage_capacity:
		result.error_message = "Settlement storage exceeds capacity"
		return result
	var instances: Dictionary[String, String] = {}
	for index in raw_storage.size():
		var errors := PackedStringArray()
		var stack := StackValidation.from_record(raw_storage[index], Callable(registry, "get_item"), errors, "settlement.storage[%d]" % index)
		var definition: ItemDefinition = registry.get_item(stack.item_id) if stack != null else null
		if stack == null or not errors.is_empty() or not StackValidation.runtime_error(stack, definition).is_empty() \
				or stack.quantity > definition.max_stack \
				or not StackValidation.accept_instance(stack, instances, errors, "settlement.storage[%d]" % index):
			result.error_message = "Invalid settlement storage record"
			return result
		result.storage.append(stack)
	var raw_pending: Array = payload["pending_loot"]
	for index in raw_pending.size():
		var errors := PackedStringArray()
		var stack := StackValidation.from_record(raw_pending[index], Callable(registry, "get_item"), errors, "settlement.pending_loot[%d]" % index)
		var definition: ItemDefinition = registry.get_item(stack.item_id) if stack != null else null
		if stack == null or not errors.is_empty() or not StackValidation.runtime_error(stack, definition).is_empty() \
				or stack.quantity > definition.max_stack \
				or not StackValidation.accept_instance(stack, instances, errors, "settlement.pending_loot[%d]" % index):
			result.error_message = "Invalid settlement pending loot record"
			return result
		result.pending_loot.append(stack)
	var facility_ids: Array[StringName] = []
	for raw in payload["facility_levels"]:
		if not raw is Dictionary or not SaveData.is_text(raw.get("facility_id", null)) or not raw.get("level", null) is int:
			result.error_message = "Invalid facility snapshot record"
			return result
		var facility_id := StringName(raw["facility_id"])
		var definition := registry.get_definition(facility_id) as FacilityDefinition
		var level: int = raw["level"]
		if definition == null or facility_id.is_empty() or facility_ids.has(facility_id) or level < 0 or level > definition.max_level:
			result.error_message = "Unknown, duplicate, or invalid facility snapshot"
			return result
		facility_ids.append(facility_id)
		result.facility_levels[facility_id] = level
	var known_residents := _known_residents(registry)
	var resident_ids: Array[StringName] = []
	for raw in payload["resident_states"]:
		if not raw is Dictionary or not SaveData.is_text(raw.get("resident_id", null)) \
				or not raw.get("unlocked", null) is bool or not SaveData.is_text(raw.get("state", null)):
			result.error_message = "Invalid resident snapshot record"
			return result
		var resident_id := StringName(raw["resident_id"])
		var current_state := StringName(raw["state"])
		if resident_id.is_empty() or current_state.is_empty() or resident_ids.has(resident_id) or not known_residents.has(resident_id):
			result.error_message = "Unknown or duplicate resident snapshot"
			return result
		resident_ids.append(resident_id)
		var resident := ResidentState.new(resident_id)
		resident.unlocked = raw["unlocked"]
		resident.current_state = current_state
		result.resident_states[resident_id] = resident
	return result

static func _known_residents(registry: Node) -> Array[StringName]:
	var result: Array[StringName] = []
	for content in registry.all_definitions():
		if content is GameStartDefinition:
			for entry in content.residents:
				if entry != null and not result.has(entry.resident_id):
					result.append(entry.resident_id)
	return result
