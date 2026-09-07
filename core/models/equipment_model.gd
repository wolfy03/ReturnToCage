class_name EquipmentModel
extends RefCounted

signal changed

var _slots: Dictionary[int, ItemStack] = {}
var definition_resolver: Callable

func _init(p_resolver: Callable = Callable()) -> void:
	definition_resolver = p_resolver

func equip(stack: ItemStack) -> ItemStack:
	var definition: EquipmentDefinition = definition_resolver.call(stack.item_id) if definition_resolver.is_valid() else null
	if definition == null:
		return stack
	var previous: ItemStack = _slots.get(definition.equipment_slot)
	_slots[definition.equipment_slot] = stack.duplicate_stack()
	changed.emit()
	return previous

func unequip(slot: EquipmentDefinition.EquipmentSlot) -> ItemStack:
	var previous: ItemStack = _slots.get(slot)
	_slots.erase(slot)
	changed.emit()
	return previous

func equipped(slot: EquipmentDefinition.EquipmentSlot) -> ItemStack:
	var stack: ItemStack = _slots.get(slot)
	return stack.duplicate_stack() if stack != null else null

func all_equipped() -> Array[ItemStack]:
	var result: Array[ItemStack] = []
	for stack in _slots.values():
		result.append(stack.duplicate_stack())
	return result

func to_dict() -> Dictionary:
	var result: Dictionary = {}
	for slot in _slots:
		result[str(slot)] = _slots[slot].to_dict()
	return result

func restore(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	_slots.clear()
	for slot_key in data:
		if not SaveData.is_text(slot_key) or not String(slot_key).is_valid_int() or not int(slot_key) in EquipmentDefinition.EquipmentSlot.values() or not data[slot_key] is Dictionary:
			errors.append("invalid equipment slot in save: %s" % slot_key)
			continue
		if not SaveData.valid_stack(data[slot_key], errors):
			continue
		var stack := ItemStack.from_dict(data[slot_key])
		var definition: EquipmentDefinition = definition_resolver.call(stack.item_id) as EquipmentDefinition if definition_resolver.is_valid() else null
		if definition != null and definition.equipment_slot == int(slot_key) and stack.quantity > 0:
			_slots[int(slot_key)] = stack
		else:
			errors.append("unknown or invalid equipment in save: %s" % stack.item_id)
	changed.emit()
	return errors
