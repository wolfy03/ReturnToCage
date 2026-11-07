class_name InventoryModel
extends RefCounted

signal changed

# Matches the existing owner-item snapshot ceiling; no wire limit is increased.
const MAX_CAPACITY := 1024
var _capacity: int = 0
var capacity: int:
	get:
		return _capacity
	set(value):
		resize_capacity(value)
var restore_overflow: Array[ItemStack] = []
var _slots: Array[ItemStack] = []
var _update_depth: int = 0
var _change_pending: bool = false
var _layout_revision: int = 0
var definition_resolver: Callable
var mutation_guard: Callable

func _init(p_capacity: int = 16, p_resolver: Callable = Callable(), p_mutation_guard: Callable = Callable()) -> void:
	definition_resolver = p_resolver
	mutation_guard = p_mutation_guard
	_capacity = clampi(p_capacity, 0, MAX_CAPACITY)
	_slots.resize(_capacity)

## Dense legacy view, in occupied-index order. Never exposes model-owned stacks.
func stacks() -> Array[ItemStack]:
	var snapshot: Array[ItemStack] = []
	for stack in _slots:
		if stack != null:
			snapshot.append(stack.duplicate_stack())
	return snapshot

## Read-only layout snapshot: exactly capacity entries, including null holes.
func slots() -> Array[ItemStack]:
	var snapshot: Array[ItemStack] = []
	for stack in _slots:
		snapshot.append(stack.duplicate_stack() if stack != null else null)
	return snapshot

func get_slot(index: int) -> ItemStack:
	return _slots[index].duplicate_stack() if _valid_index(index) and _slots[index] != null else null

func count(item_id: StringName) -> int:
	var total := 0
	for stack in _slots:
		if stack != null and stack.item_id == item_id:
			total += stack.quantity
	return total

func resize_capacity(value: int) -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Inventory is a read-only mirror")
	if value < 0 or value > MAX_CAPACITY:
		return CommandResult.make(false, "Capacity must be between 0 and %d" % MAX_CAPACITY)
	var error := _layout_error()
	if not error.is_empty():
		return CommandResult.make(false, error)
	for index in range(value, _capacity):
		if _slots[index] != null:
			return CommandResult.make(false, "Cannot truncate an occupied slot")
	if value != _capacity:
		_slots.resize(value)
		_capacity = value
		_notify_changed()
	return CommandResult.make(true)

func expand_capacity(amount: int) -> CommandResult:
	if amount <= 0 or amount > MAX_CAPACITY - _capacity:
		return CommandResult.make(false, "Invalid capacity expansion")
	return resize_capacity(_capacity + amount)

func add_item(item_id: StringName, amount: int) -> InventoryResult:
	return add_stack(ItemStack.new(item_id, amount))

## Legacy partial acceptance is intentional (loot/drop remainder ownership).
func add_stack(incoming: ItemStack) -> InventoryResult:
	var amount := incoming.quantity if incoming != null else 0
	if not _mutation_allowed():
		return _rejected(amount, "Inventory is a read-only mirror")
	var error := _layout_error()
	if not error.is_empty():
		return _rejected(amount, error)
	var result := _add_stack(incoming)
	if result.changed > 0:
		_notify_changed()
	return result

func _add_stack(incoming: ItemStack) -> InventoryResult:
	var definition := _definition(incoming)
	var error := StackValidation.runtime_error(incoming, definition)
	if not error.is_empty():
		return _rejected(incoming.quantity if incoming != null else 0, error)
	if not incoming.instance_id.is_empty():
		for stack in _slots:
			if stack != null and stack.instance_id == incoming.instance_id:
				return _rejected(1, "duplicate instance: %s" % incoming.instance_id)
	var remaining := incoming.quantity
	var limit := _stack_limit(definition)
	if incoming.instance_id.is_empty() and not definition is EquipmentDefinition:
		for stack in _slots:
			if stack != null and _merge_compatible(stack, incoming) and stack.quantity < limit:
				var moved := mini(remaining, limit - stack.quantity)
				stack.quantity += moved
				remaining -= moved
				if remaining == 0:
					break
	for index in _slots.size():
		if remaining <= 0:
			break
		if _slots[index] == null:
			var stack := incoming.duplicate_stack()
			stack.quantity = mini(remaining, limit)
			_slots[index] = stack
			remaining -= stack.quantity
	return InventoryResult.make(incoming.quantity, incoming.quantity - remaining, "inventory full" if remaining > 0 else "")

func preview_exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	return _copy_layout()._apply_exchange(inputs, outputs)

func exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Inventory is a read-only mirror")
	var revision := _layout_revision
	var staged := _copy_layout()
	var result := staged._apply_exchange(inputs, outputs)
	if not result.success:
		return result
	if not _mutation_allowed() or revision != _layout_revision:
		return CommandResult.make(false, "Inventory changed during exchange")
	_commit_layout(staged._slots)
	return result

## Both layouts are staged before either owner changes. No Save/wire round trip.
func transfer_to(destination: InventoryModel, inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	if destination == null or destination == self or not _mutation_allowed() or not destination._mutation_allowed():
		return CommandResult.make(false, "Inventory transfer unavailable")
	var source_revision := _layout_revision
	var destination_revision := destination._layout_revision
	var source_stage := _copy_layout()
	var destination_stage := destination._copy_layout()
	var result := source_stage._apply_exchange(inputs, [])
	if result.success:
		result = destination_stage._apply_exchange([], outputs)
	if not result.success:
		return result
	if not _mutation_allowed() or not destination._mutation_allowed() or source_revision != _layout_revision or destination_revision != destination._layout_revision:
		return CommandResult.make(false, "Inventory changed during transfer")
	begin_update()
	destination.begin_update()
	_commit_layout(source_stage._slots)
	destination._commit_layout(destination_stage._slots)
	destination.end_update()
	end_update()
	return CommandResult.make(true)

func _apply_exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	var error := _layout_error()
	if not error.is_empty():
		return CommandResult.make(false, error)
	for stack in inputs:
		if not StackValidation.runtime_error(stack, _definition(stack)).is_empty():
			return CommandResult.make(false, "Invalid input stack")
		if stack.instance_id.is_empty():
			if count(stack.item_id) < stack.quantity:
				return CommandResult.make(false, "Not enough resources", inputs)
			_remove_item(stack.item_id, stack.quantity)
		else:
			var found := -1
			for index in _slots.size():
				var existing := _slots[index]
				if existing != null and existing.instance_id == stack.instance_id and existing.item_id == stack.item_id:
					found = index
					break
			if found < 0:
				return CommandResult.make(false, "Required instance missing: %s" % stack.instance_id, inputs)
			_slots[found] = null
	for stack in outputs:
		var added := _add_stack(stack)
		if not added.success:
			return CommandResult.make(false, added.message, outputs)
	return CommandResult.make(true)

func remove_item(item_id: StringName, amount: int) -> InventoryResult:
	if not _mutation_allowed():
		return _rejected(amount, "Inventory is a read-only mirror")
	var error := _layout_error()
	if amount <= 0 or item_id.is_empty() or not error.is_empty():
		return _rejected(amount, error if not error.is_empty() else "item id and positive amount required")
	var result := _remove_item(item_id, amount)
	if result.changed > 0:
		_notify_changed()
	return result

func _remove_item(item_id: StringName, amount: int) -> InventoryResult:
	var remaining := amount
	for index in range(_slots.size() - 1, -1, -1):
		var stack := _slots[index]
		if stack == null or stack.item_id != item_id:
			continue
		var moved := mini(remaining, stack.quantity)
		stack.quantity -= moved
		remaining -= moved
		if stack.quantity == 0:
			_slots[index] = null
		if remaining == 0:
			break
	return InventoryResult.make(amount, amount - remaining, "not enough items" if remaining > 0 else "")

func move_slot(from: int, to: int) -> CommandResult:
	var error := _slot_command_error(from, to)
	if not error.is_empty():
		return CommandResult.make(false, error)
	if _slots[from] == null:
		return CommandResult.make(false, "Source slot is empty")
	if from == to:
		return CommandResult.make(true)
	if _slots[to] != null and _merge_compatible(_slots[from], _slots[to]) and not _definition(_slots[from]) is EquipmentDefinition:
		return merge_slots(from, to)
	return swap_slots(from, to)

func swap_slots(a: int, b: int) -> CommandResult:
	var error := _slot_command_error(a, b)
	if not error.is_empty():
		return CommandResult.make(false, error)
	if a != b and (_slots[a] != null or _slots[b] != null):
		var temporary := _slots[a]
		_slots[a] = _slots[b]
		_slots[b] = temporary
		_notify_changed()
	return CommandResult.make(true)

func merge_slots(from: int, to: int) -> CommandResult:
	var error := _slot_command_error(from, to)
	if not error.is_empty():
		return CommandResult.make(false, error)
	var source := _slots[from]
	var target := _slots[to]
	if from == to or source == null or target == null or not _merge_compatible(source, target) or _definition(source) is EquipmentDefinition:
		return CommandResult.make(false, "Slots cannot be merged")
	var moved := mini(source.quantity, _stack_limit(_definition(target)) - target.quantity)
	if moved <= 0:
		return CommandResult.make(false, "Destination stack is full")
	target.quantity += moved
	source.quantity -= moved
	if source.quantity == 0:
		_slots[from] = null
	_notify_changed()
	return CommandResult.make(true)

func split_stack(from: int, to: int, amount: int) -> CommandResult:
	var error := _slot_command_error(from, to)
	if not error.is_empty():
		return CommandResult.make(false, error)
	var source := _slots[from]
	if from == to or source == null or _slots[to] != null or amount <= 0 or amount >= source.quantity or not source.instance_id.is_empty() or _definition(source) is EquipmentDefinition:
		return CommandResult.make(false, "Split requires a stackable source, a proper partial amount and an empty destination")
	var split := source.duplicate_stack()
	split.quantity = amount
	_slots[to] = split
	source.quantity -= amount
	_notify_changed()
	return CommandResult.make(true)

func sort_slots() -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Inventory is a read-only mirror")
	var error := _layout_error()
	if not error.is_empty():
		return CommandResult.make(false, error)
	var revision := _layout_revision
	var ordered := stacks()
	ordered.sort_custom(_sort_before)
	var staged := InventoryModel.new(capacity, definition_resolver)
	for stack in ordered:
		if not staged._add_stack(stack).success:
			return CommandResult.make(false, "Sorted items do not fit")
	if not _mutation_allowed() or revision != _layout_revision:
		return CommandResult.make(false, "Inventory changed during sort")
	_commit_layout(staged._slots)
	return CommandResult.make(true)

func move_item(from_index: int, to_index: int) -> bool:
	return move_slot(from_index, to_index).success

func discard_item(item_id: StringName, amount: int) -> InventoryResult:
	var definition: ItemDefinition = definition_resolver.call(item_id) as ItemDefinition if definition_resolver.is_valid() else null
	if definition == null or not definition.discardable or definition.quest_protected:
		return _rejected(amount, "item cannot be discarded")
	return remove_item(item_id, amount)

func total_weight() -> float:
	var result := 0.0
	for stack in _slots:
		if stack != null:
			var definition := _definition(stack)
			if definition != null:
				result += definition.weight * stack.quantity
	return result

func clear() -> void:
	if not _mutation_allowed():
		return
	_slots = []
	_slots.resize(capacity)
	_notify_changed()

## Dense legacy initialization; optional capacity replaces data and size atomically.
func initialize(stacks_to_copy: Array[ItemStack], target_capacity: int = -1) -> CommandResult:
	for stack in stacks_to_copy:
		if stack == null:
			return CommandResult.make(false, "Initial stack cannot be empty")
	return initialize_slots(stacks_to_copy, target_capacity)

## Domain-only replacement of a memory layout, not a Save/network record decoder.
func initialize_slots(slots_to_copy: Array[ItemStack], target_capacity: int = -1) -> CommandResult:
	if not _mutation_allowed():
		return CommandResult.make(false, "Inventory is a read-only mirror")
	var next_capacity := capacity if target_capacity == -1 else target_capacity
	if next_capacity < 0 or next_capacity > MAX_CAPACITY or slots_to_copy.size() > next_capacity:
		return CommandResult.make(false, "Initial stacks exceed valid capacity")
	var seen: Dictionary[String, String] = {}
	var errors := PackedStringArray()
	var next: Array[ItemStack] = []
	next.resize(next_capacity)
	for index in slots_to_copy.size():
		var stack := slots_to_copy[index]
		if stack == null:
			continue
		var error := _stored_stack_error(stack)
		if not error.is_empty():
			return CommandResult.make(false, error)
		if not StackValidation.accept_instance(stack, seen, errors, "initialize"):
			return CommandResult.make(false, errors[0])
		next[index] = stack.duplicate_stack()
	_slots = next
	_capacity = next_capacity
	restore_overflow.clear()
	_notify_changed()
	return CommandResult.make(true)

## Save v4 / Protocol v16 remain dense. Slot positions are deliberately not encoded.
func to_array() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for stack in _slots:
		if stack != null:
			result.append(stack.to_dict())
	return result

func restore(data: Array, instances: Dictionary[String, String] = {}, context: String = "inventory", target_capacity: int = -1) -> PackedStringArray:
	var errors := PackedStringArray()
	if not _mutation_allowed():
		errors.append("%s is a read-only mirror" % context)
		return errors
	var next_capacity := capacity if target_capacity == -1 else target_capacity
	if next_capacity < 0 or next_capacity > MAX_CAPACITY:
		errors.append("%s has invalid capacity" % context)
		return errors
	var staged := InventoryModel.new(next_capacity, definition_resolver)
	var overflow_items: Array[ItemStack] = []
	for index in data.size():
		var location := "%s[%d]" % [context, index]
		var stack := StackValidation.from_record(data[index], definition_resolver, errors, location)
		if stack == null or not StackValidation.accept_instance(stack, instances, errors, location):
			continue
		var definition := _definition(stack)
		if stack.quantity > _stack_limit(definition):
			errors.append("oversized stack split in %s: %s" % [location, stack.item_id])
		var result := staged._add_stack(stack)
		if result.remainder > 0:
			var overflow := stack.duplicate_stack()
			overflow.quantity = result.remainder
			overflow_items.append(overflow)
			errors.append("inventory overflow retained in %s: %s x%d" % [location, stack.item_id, result.remainder])
	_slots = staged._slots
	_capacity = next_capacity
	restore_overflow = overflow_items
	_notify_changed()
	return errors

func take_restore_overflow() -> Array[ItemStack]:
	var result := restore_overflow
	restore_overflow = []
	return result

func _copy_layout() -> InventoryModel:
	var copy := InventoryModel.new(capacity, definition_resolver)
	copy._slots = slots()
	return copy

func _commit_layout(next: Array[ItemStack]) -> void:
	var same := _slots.size() == next.size()
	if same:
		for index in _slots.size():
			if (_slots[index] == null) != (next[index] == null) or (_slots[index] != null and _slots[index].to_dict() != next[index].to_dict()):
				same = false
				break
	if not same:
		_slots = next
		_notify_changed()

func _valid_index(index: int) -> bool:
	return index >= 0 and index < capacity

func _slot_command_error(a: int, b: int) -> String:
	if not _mutation_allowed():
		return "Inventory is a read-only mirror"
	if not _valid_index(a) or not _valid_index(b):
		return "Slot index out of range"
	return _layout_error()

func _layout_error() -> String:
	if _slots.size() != capacity:
		return "Invalid slot layout size"
	var seen: Dictionary[String, bool] = {}
	for stack in _slots:
		if stack == null:
			continue
		var error := _stored_stack_error(stack)
		if not error.is_empty():
			return error
		if not stack.instance_id.is_empty():
			if seen.has(stack.instance_id):
				return "Duplicate inventory instance"
			seen[stack.instance_id] = true
	return ""

func _stored_stack_error(stack: ItemStack) -> String:
	var definition := _definition(stack)
	var error := StackValidation.runtime_error(stack, definition)
	if not error.is_empty():
		return error
	if stack.quantity > _stack_limit(definition):
		return "Stored stack exceeds max_stack"
	return ""

func _definition(stack: ItemStack) -> ItemDefinition:
	return definition_resolver.call(stack.item_id) as ItemDefinition if stack != null and definition_resolver.is_valid() else null

func _stack_limit(definition: ItemDefinition) -> int:
	return 1 if definition is EquipmentDefinition else definition.max_stack

func _merge_compatible(a: ItemStack, b: ItemStack) -> bool:
	return a.item_id == b.item_id and a.instance_id.is_empty() and b.instance_id.is_empty() and a.durability == b.durability

func _sort_before(a: ItemStack, b: ItemStack) -> bool:
	var a_definition := _definition(a)
	var b_definition := _definition(b)
	if a_definition.category != b_definition.category:
		return a_definition.category < b_definition.category
	if a.item_id != b.item_id:
		return String(a.item_id) < String(b.item_id)
	if a.instance_id != b.instance_id:
		return a.instance_id < b.instance_id
	if a.durability != b.durability:
		return a.durability < b.durability
	return a.quantity > b.quantity

func _rejected(amount: int, reason: String) -> InventoryResult:
	var result := InventoryResult.make(amount, 0, reason)
	result.success = false
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
	_layout_revision += 1
	if _update_depth > 0:
		_change_pending = true
	else:
		changed.emit()

func _mutation_allowed() -> bool:
	return not mutation_guard.is_valid() or bool(mutation_guard.call())
