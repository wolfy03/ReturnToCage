class_name EquipmentModel
extends RefCounted

signal changed

var _slots: Dictionary[int, ItemStack] = {}
var definition_resolver: Callable

func _init(p_resolver: Callable = Callable()) -> void:
	definition_resolver = p_resolver

func equip(stack: ItemStack) -> ItemStack:
	var definition: EquipmentDefinition = definition_resolver.call(stack.item_id) as EquipmentDefinition if stack != null and definition_resolver.is_valid() else null
	if not StackValidation.runtime_error(stack, definition).is_empty() or stack.quantity != 1:
		return stack
	if not stack.instance_id.is_empty():
		for equipped_stack in _slots.values():
			if equipped_stack.instance_id == stack.instance_id:
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

func restore(data: Dictionary, instances: Dictionary[String, String] = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	_slots.clear()
	# Slot order, not JSON object order, determines duplicate precedence.
	var keys: Array = data.keys()
	keys.sort_custom(func(a: Variant, b: Variant) -> bool: return str(a) < str(b))
	for slot_key in keys:
		if not SaveData.is_text(slot_key) or not String(slot_key).is_valid_int() or not int(slot_key) in EquipmentDefinition.EquipmentSlot.values():
			errors.append("invalid equipment slot in save: %s" % slot_key)
			continue
		var location: String = "equipment[%s]" % slot_key
		var stack: ItemStack = StackValidation.from_record(data[slot_key], definition_resolver, errors, location)
		if stack == null:
			continue
		var definition := definition_resolver.call(stack.item_id) as EquipmentDefinition
		if definition == null or definition.equipment_slot != int(slot_key) or stack.quantity != 1:
			errors.append("invalid equipment type, slot or quantity in %s" % location)
			continue
		if _slots.has(int(slot_key)):
			errors.append("duplicate equipment slot ignored: %s" % slot_key)
			continue
		if StackValidation.accept_instance(stack, instances, errors, location):
			_slots[int(slot_key)] = stack
	changed.emit()
	return errors
