class_name InventoryModel
extends RefCounted

signal changed

var capacity: int = 16
var _stacks: Array[ItemStack] = []
var definition_resolver: Callable

func _init(p_capacity: int = 16, p_resolver: Callable = Callable()) -> void:
	capacity = p_capacity
	definition_resolver = p_resolver

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
	if amount <= 0:
		return InventoryResult.make(amount, 0, "amount must be positive")
	var definition: ItemDefinition = definition_resolver.call(item_id) if definition_resolver.is_valid() else null
	if definition == null:
		return InventoryResult.make(amount, 0, "unknown item: %s" % item_id)
	var remaining := amount
	for stack in _stacks:
		if stack.item_id == item_id and stack.instance_id.is_empty() and stack.quantity < definition.max_stack:
			var moved := mini(remaining, definition.max_stack - stack.quantity)
			stack.quantity += moved
			remaining -= moved
			if remaining == 0:
				break
	while remaining > 0 and _stacks.size() < capacity:
		var moved := mini(remaining, definition.max_stack)
		_stacks.append(ItemStack.new(item_id, moved))
		remaining -= moved
	var result := InventoryResult.make(amount, amount - remaining, "inventory full" if remaining > 0 else "")
	if result.changed > 0:
		changed.emit()
	return result

func remove_item(item_id: StringName, amount: int) -> InventoryResult:
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
		changed.emit()
	return result

func move_item(from_index: int, to_index: int) -> bool:
	if from_index < 0 or from_index >= _stacks.size() or to_index < 0 or to_index >= _stacks.size():
		return false
	var temporary := _stacks[from_index]
	_stacks[from_index] = _stacks[to_index]
	_stacks[to_index] = temporary
	changed.emit()
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
	_stacks.clear()
	changed.emit()

func to_array() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for stack in _stacks:
		result.append(stack.to_dict())
	return result

func restore(data: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	_stacks.clear()
	for raw in data:
		if not raw is Dictionary:
			errors.append("invalid inventory record")
			continue
		var stack := ItemStack.from_dict(raw)
		if not definition_resolver.is_valid() or definition_resolver.call(stack.item_id) == null:
			errors.append("unknown item id in save: %s" % stack.item_id)
			continue
		if stack.quantity > 0 and _stacks.size() < capacity:
			_stacks.append(stack)
	changed.emit()
	return errors
