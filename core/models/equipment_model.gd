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

func restore(data: Dictionary) -> void:
	_slots.clear()
	for slot_key in data:
		var stack := ItemStack.from_dict(data[slot_key])
		if definition_resolver.is_valid() and definition_resolver.call(stack.item_id) is EquipmentDefinition:
			_slots[int(slot_key)] = stack
	changed.emit()
