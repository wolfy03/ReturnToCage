class_name InventoryModel
extends RefCounted

signal changed

var _capacity: int = 16
var capacity: int:
	get:
		return _capacity
	set(value):
		if _mutation_allowed():
			_capacity = value
var restore_overflow: Array[ItemStack] = []
var _stacks: Array[ItemStack] = []
var _update_depth: int = 0
var _change_pending: bool = false
var definition_resolver: Callable
var mutation_guard: Callable

func _init(p_capacity: int = 16, p_resolver: Callable = Callable(), p_mutation_guard: Callable = Callable()) -> void:
	capacity = p_capacity
	definition_resolver = p_resolver
	mutation_guard = p_mutation_guard

func stacks() -> Array[ItemStack]:
	var snapshot: Array[ItemStack] = []
	for stack in _stacks:
		snapshot.append(stack.duplicate_stack())
	return snapshot

func count(item_id: StringName) -> int:
	var total := 0
	for stack in _stacks:
		if stack.item_id == item_id:
			total += stack.quantity
	return total

func add_item(item_id: StringName, amount: int) -> InventoryResult:
	return add_stack(ItemStack.new(item_id, amount))

func add_stack(incoming: ItemStack) -> InventoryResult:
	if not _mutation_allowed():
		var amount := incoming.quantity if incoming != null else 0
		var denied := InventoryResult.make(amount, 0, "Inventory is a read-only mirror")
		denied.success = false
		return denied
	var result: InventoryResult = _add_stack(incoming)
	if result.changed > 0:
		_notify_changed()
	return result

func _add_stack(incoming: ItemStack) -> InventoryResult:
	var definition: ItemDefinition = definition_resolver.call(incoming.item_id) as ItemDefinition if incoming != null and definition_resolver.is_valid() else null
	var error: String = StackValidation.runtime_error(incoming, definition)
	if not error.is_empty():
		var rejected := InventoryResult.make(incoming.quantity if incoming != null else 0, 0, error)
		rejected.success = false
		return rejected
	if not incoming.instance_id.is_empty():
		for stack in _stacks:
			if stack.instance_id == incoming.instance_id:
				return InventoryResult.make(1, 0, "duplicate instance: %s" % incoming.instance_id)
		if _stacks.size() >= capacity:
			return InventoryResult.make(1, 0, "inventory full")
		_stacks.append(incoming.duplicate_stack())
		return InventoryResult.make(1, 1)
	var remaining: int = incoming.quantity
	for stack in _stacks:
		if stack.item_id == incoming.item_id and stack.instance_id.is_empty() and stack.durability == incoming.durability and stack.quantity < definition.max_stack:
			var moved: int = mini(remaining, definition.max_stack - stack.quantity)
			stack.quantity += moved
			remaining -= moved
			if remaining == 0:
				break
	while remaining > 0 and _stacks.size() < capacity:
		var stack: ItemStack = incoming.duplicate_stack()
		stack.quantity = mini(remaining, definition.max_stack)
		_stacks.append(stack)
		remaining -= stack.quantity
	return InventoryResult.make(incoming.quantity, incoming.quantity - remaining, "inventory full" if remaining > 0 else "")

func preview_exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	var preview := InventoryModel.new(capacity, definition_resolver)
	preview._stacks = stacks()
	return preview._apply_exchange(inputs, outputs)

func exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Inventory is a read-only mirror")
	var result: CommandResult = preview_exchange(inputs, outputs)
	if not result.success:
		return result
	var staged := InventoryModel.new(capacity, definition_resolver)
	staged._stacks = stacks()
	result = staged._apply_exchange(inputs, outputs)
	if result.success:
		_stacks = staged._stacks
		_notify_changed()
	return result

func _apply_exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	for stack in inputs:
		if not StackValidation.basic_error(stack).is_empty():
			return CommandResult.make(false, "Invalid input stack")
		if stack.instance_id.is_empty():
			if not remove_item(stack.item_id, stack.quantity).success:
				return CommandResult.make(false, "Not enough resources", inputs)
		else:
			var found: int = -1
			for index in _stacks.size():
				if _stacks[index].instance_id == stack.instance_id and _stacks[index].item_id == stack.item_id:
					found = index
					break
			if found < 0:
				return CommandResult.make(false, "Required instance missing: %s" % stack.instance_id, inputs)
			_stacks.remove_at(found)
	for stack in outputs:
		var added: InventoryResult = _add_stack(stack)
		if not added.success:
			return CommandResult.make(false, added.message, outputs if stack != null else [])
	return CommandResult.make(true)

func remove_item(item_id: StringName, amount: int) -> InventoryResult:
	if not _mutation_allowed():
		var denied := InventoryResult.make(amount, 0, "Inventory is a read-only mirror")
		denied.success = false
		return denied
	if amount <= 0:
		return InventoryResult.make(amount, 0, "amount must be positive")
	var remaining := amount
	for index in range(_stacks.size() - 1, -1, -1):
		var stack := _stacks[index]
		if stack.item_id != item_id:
			continue
		var moved := mini(remaining, stack.quantity)
		stack.quantity -= moved
		remaining -= moved
		if stack.quantity == 0:
			_stacks.remove_at(index)
		if remaining == 0:
			break
	var result := InventoryResult.make(amount, amount - remaining, "not enough items" if remaining > 0 else "")
	if result.changed > 0:
		_notify_changed()
	return result

func move_item(from_index: int, to_index: int) -> bool:
	if not _mutation_allowed():
		return false
	if from_index < 0 or from_index >= _stacks.size() or to_index < 0 or to_index >= _stacks.size():
		return false
	var temporary := _stacks[from_index]
	_stacks[from_index] = _stacks[to_index]
	_stacks[to_index] = temporary
	_notify_changed()
	return true

func discard_item(item_id: StringName, amount: int) -> InventoryResult:
	var definition: ItemDefinition = definition_resolver.call(item_id) if definition_resolver.is_valid() else null
	if definition == null or not definition.discardable or definition.quest_protected:
		return InventoryResult.make(amount, 0, "item cannot be discarded")
	return remove_item(item_id, amount)

func total_weight() -> float:
	var result := 0.0
	for stack in _stacks:
		var definition: ItemDefinition = definition_resolver.call(stack.item_id) if definition_resolver.is_valid() else null
		if definition != null:
			result += definition.weight * stack.quantity
	return result

func clear() -> void:
	if not _mutation_allowed():
		return
	_stacks.clear()
	_notify_changed()

## Bulk initialization from validated typed start content; keeps the stack model.
func initialize(stacks_to_copy: Array[ItemStack]) -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Inventory is a read-only mirror")
	var seen: Dictionary[String, String] = {}
	var errors := PackedStringArray()
	if stacks_to_copy.size() > capacity:
		return CommandResult.make(false, "Initial stacks exceed capacity")
	for stack in stacks_to_copy:
		var definition: ItemDefinition = definition_resolver.call(stack.item_id) as ItemDefinition if stack != null and definition_resolver.is_valid() else null
		var error: String = StackValidation.runtime_error(stack, definition)
		if not error.is_empty():
			return CommandResult.make(false, error)
		if stack.quantity > definition.max_stack:
			return CommandResult.make(false, "Initial stack exceeds max_stack")
		if not StackValidation.accept_instance(stack, seen, errors, "initialize"):
			return CommandResult.make(false, errors[0])
	_stacks.clear()
	restore_overflow.clear()
	for stack in stacks_to_copy:
		_stacks.append(stack.duplicate_stack())
	_notify_changed()
	return CommandResult.make(true)

func to_array() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for stack in _stacks:
		result.append(stack.to_dict())
	return result

func restore(data: Array, instances: Dictionary[String, String] = {}, context: String = "inventory") -> PackedStringArray:
	var errors := PackedStringArray()
	if not _mutation_allowed():
		errors.append("%s is a read-only mirror" % context)
		return errors
	_stacks.clear()
	restore_overflow.clear()
	for index in data.size():
		var location: String = "%s[%d]" % [context, index]
		var stack: ItemStack = StackValidation.from_record(data[index], definition_resolver, errors, location)
		if stack == null or not StackValidation.accept_instance(stack, instances, errors, location):
			continue
		var definition := definition_resolver.call(stack.item_id) as ItemDefinition
		if stack.quantity > definition.max_stack:
			errors.append("oversized stack split in %s: %s" % [location, stack.item_id])
		var result: InventoryResult = _add_stack(stack)
		if result.remainder > 0:
			var overflow := stack.duplicate_stack()
			overflow.quantity = result.remainder
			restore_overflow.append(overflow)
			errors.append("inventory overflow retained in %s: %s x%d" % [location, stack.item_id, result.remainder])
	_notify_changed()
	return errors

func take_restore_overflow() -> Array[ItemStack]:
	var result: Array[ItemStack] = restore_overflow
	restore_overflow = []
	return result

## Defer observers until all owners in a domain transaction have committed.
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
