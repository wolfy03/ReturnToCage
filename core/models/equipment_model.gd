class_name EquipmentModel
extends RefCounted

signal changed

var _slots: Dictionary[int, ItemStack] = {}
var definition_resolver: Callable
var mutation_guard: Callable
var _update_depth: int = 0
var _change_pending: bool = false

func _init(p_resolver: Callable = Callable(), p_mutation_guard: Callable = Callable()) -> void:
	definition_resolver = p_resolver
	mutation_guard = p_mutation_guard

func equip(stack: ItemStack) -> ItemStack:
	if not _mutation_allowed():
		return stack
	var definition: EquipmentDefinition = definition_resolver.call(stack.item_id) as EquipmentDefinition if stack != null and definition_resolver.is_valid() else null
	if not StackValidation.runtime_error(stack, definition).is_empty() or stack.quantity != 1:
		return stack
	if not stack.instance_id.is_empty():
		for equipped_stack in _slots.values():
			if equipped_stack.instance_id == stack.instance_id:
				return stack
	var previous: ItemStack = _slots.get(definition.equipment_slot)
	_slots[definition.equipment_slot] = stack.duplicate_stack()
	_notify_changed()
	return previous

func unequip(slot: EquipmentDefinition.EquipmentSlot) -> ItemStack:
	if not _mutation_allowed():
		return null
	var previous: ItemStack = _slots.get(slot)
	if previous == null:
		return null
	_slots.erase(slot)
	_notify_changed()
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
	if not _mutation_allowed():
		errors.append("Equipment is a read-only mirror")
		return errors
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
	_notify_changed()
	return errors

func initialize(slots: Dictionary[int, ItemStack]) -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Equipment is a read-only mirror")
	var staged: Dictionary[int, ItemStack] = {}
	var instances: Dictionary[String, String] = {}
	for slot in slots:
		var stack: ItemStack = slots[slot]
		var definition: EquipmentDefinition = definition_resolver.call(stack.item_id) as EquipmentDefinition \
			if stack != null and definition_resolver.is_valid() else null
		var error := StackValidation.runtime_error(stack, definition)
		var context := "equipment[%s]" % slot
		var errors := PackedStringArray()
		if slot not in EquipmentDefinition.EquipmentSlot.values() or not error.is_empty() \
				or definition.equipment_slot != slot or stack.quantity != 1 \
				or not StackValidation.accept_instance(stack, instances, errors, context):
			return CommandResult.make(false, error if not error.is_empty() else "Invalid equipment snapshot")
		staged[slot] = stack.duplicate_stack()
	_slots = staged
	_notify_changed()
	return CommandResult.make(true)

func begin_update() -> void:
	_update_depth += 1

func end_update() -> void:
	if _update_depth <= 0:
		return
	_update_depth -= 1
	if _update_depth == 0 and _change_pending:
		_change_pending = false
		changed.emit()

func _notify_changed() -> void:
	if _update_depth > 0:
		_change_pending = true
	else:
		changed.emit()

func _mutation_allowed() -> bool:
	return not mutation_guard.is_valid() or bool(mutation_guard.call())
