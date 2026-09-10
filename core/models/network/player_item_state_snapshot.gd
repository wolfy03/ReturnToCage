class_name PlayerItemStateSnapshot
extends RefCounted

const MAX_INVENTORY_CAPACITY := 1024

var owner_player_id: StringName
var revision: int = 0
var inventory_capacity: int = 0
var inventory: Array[ItemStack] = []
var protected_capacity: int = 0
var protected_inventory: Array[ItemStack] = []
var equipment: Dictionary[int, ItemStack] = {}
var error_message: String = ""

func to_payload() -> Dictionary:
	var inventory_payload: Array[Dictionary] = []
	for stack in inventory:
		inventory_payload.append(stack.to_dict())
	var equipment_payload: Array[Dictionary] = []
	var protected_payload: Array[Dictionary] = []
	for stack in protected_inventory:
		protected_payload.append(stack.to_dict())
	var slots: Array = equipment.keys()
	slots.sort()
	for slot in slots:
		equipment_payload.append({"slot": slot, "stack": equipment[slot].to_dict()})
	return {
		"owner_player_id": String(owner_player_id),
		"revision": revision,
		"inventory_capacity": inventory_capacity,
		"inventory": inventory_payload,
		"protected_capacity": protected_capacity,
		"protected_inventory": protected_payload,
		"equipment": equipment_payload,
	}

static func from_state(owner: StringName, state: PlayerState) -> PlayerItemStateSnapshot:
	var result := PlayerItemStateSnapshot.new()
	if owner.is_empty() or state == null:
		result.error_message = "Player item snapshot requires an owner and state"
		return result
	result.owner_player_id = owner
	result.revision = state.item_state_revision
	result.inventory_capacity = state.inventory.capacity
	result.inventory = state.inventory.stacks()
	result.protected_capacity = state.protected_inventory.capacity
	result.protected_inventory = state.protected_inventory.stacks()
	for slot in EquipmentDefinition.EquipmentSlot.values():
		var stack := state.equipment.equipped(slot)
		if stack != null:
			result.equipment[slot] = stack
	return result

static func from_payload(payload: Dictionary, registry: Node, expected_owner: StringName) -> PlayerItemStateSnapshot:
	var result := PlayerItemStateSnapshot.new()
	if not SaveData.is_text(payload.get("owner_player_id", null)) \
			or not payload.get("revision", null) is int \
			or not payload.get("inventory_capacity", null) is int \
			or not payload.get("inventory", null) is Array \
			or not payload.get("protected_capacity", null) is int \
			or not payload.get("protected_inventory", null) is Array \
			or not payload.get("equipment", null) is Array:
		result.error_message = "Invalid player item snapshot fields"
		return result
	result.owner_player_id = StringName(payload["owner_player_id"])
	result.revision = payload["revision"]
	result.inventory_capacity = payload["inventory_capacity"]
	result.protected_capacity = payload["protected_capacity"]
	if result.owner_player_id.is_empty() or result.owner_player_id != expected_owner \
			or result.revision < 0 or result.inventory_capacity < 1 \
			or result.inventory_capacity > MAX_INVENTORY_CAPACITY \
			or result.protected_capacity < 0 or result.protected_capacity > MAX_INVENTORY_CAPACITY:
		result.error_message = "Invalid player item snapshot owner, revision, or capacity"
		return result
	var raw_inventory: Array = payload["inventory"]
	if raw_inventory.size() > result.inventory_capacity:
		result.error_message = "Player inventory exceeds capacity"
		return result
	var instances: Dictionary[String, String] = {}
	for index in raw_inventory.size():
		var errors := PackedStringArray()
		var context := "player.inventory[%d]" % index
		var stack := StackValidation.from_record(raw_inventory[index], Callable(registry, "get_item"), errors, context)
		var definition: ItemDefinition = registry.get_item(stack.item_id) if stack != null else null
		if stack == null or not errors.is_empty() or not StackValidation.runtime_error(stack, definition).is_empty() \
				or stack.quantity > definition.max_stack \
				or not StackValidation.accept_instance(stack, instances, errors, context):
			result.error_message = "Invalid player inventory record"
			return result
		result.inventory.append(stack)
	var raw_protected: Array = payload["protected_inventory"]
	if raw_protected.size() > result.protected_capacity:
		result.error_message = "Protected inventory exceeds capacity"
		return result
	for index in raw_protected.size():
		var errors := PackedStringArray()
		var context := "player.protected_inventory[%d]" % index
		var stack := StackValidation.from_record(raw_protected[index], Callable(registry, "get_item"), errors, context)
		var definition: ItemDefinition = registry.get_item(stack.item_id) if stack != null else null
		if stack == null or not errors.is_empty() or not StackValidation.runtime_error(stack, definition).is_empty() \
				or stack.quantity > definition.max_stack \
				or not StackValidation.accept_instance(stack, instances, errors, context):
			result.error_message = "Invalid protected inventory record"
			return result
		result.protected_inventory.append(stack)
	var seen_slots: Dictionary[int, bool] = {}
	for index in payload["equipment"].size():
		var raw: Variant = payload["equipment"][index]
		if not raw is Dictionary or not raw.get("slot", null) is int or not raw.get("stack", null) is Dictionary:
			result.error_message = "Invalid player equipment record"
			return result
		var slot: int = raw["slot"]
		if slot not in EquipmentDefinition.EquipmentSlot.values() or seen_slots.has(slot):
			result.error_message = "Invalid or duplicate player equipment slot"
			return result
		var errors := PackedStringArray()
		var context := "player.equipment[%d]" % slot
		var stack := StackValidation.from_record(raw["stack"], Callable(registry, "get_item"), errors, context)
		var definition := registry.get_item(stack.item_id) as EquipmentDefinition if stack != null else null
		if stack == null or not errors.is_empty() or definition == null \
				or not StackValidation.runtime_error(stack, definition).is_empty() \
				or stack.quantity != 1 or definition.equipment_slot != slot \
				or not StackValidation.accept_instance(stack, instances, errors, context):
			result.error_message = "Invalid player equipment item"
			return result
		seen_slots[slot] = true
		result.equipment[slot] = stack
	return result
