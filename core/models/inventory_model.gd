class_name InventoryModel
extends RefCounted

signal changed

var capacity: int = 16
var restore_overflow: Array[ItemStack] = []
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
	return add_stack(ItemStack.new(item_id, amount))

func add_stack(incoming: ItemStack) -> InventoryResult:
	if incoming.quantity <= 0:
		return InventoryResult.make(incoming.quantity, 0, "amount must be positive")
	var definition: ItemDefinition = definition_resolver.call(incoming.item_id) as ItemDefinition if definition_resolver.is_valid() else null
	if definition == null or definition.max_stack < 1:
		return InventoryResult.make(incoming.quantity, 0, "unknown item: %s" % incoming.item_id)
	var remaining: int = incoming.quantity
	for stack in _stacks:
		if stack.item_id == incoming.item_id and stack.instance_id.is_empty() and incoming.instance_id.is_empty() and stack.durability == incoming.durability and stack.quantity < definition.max_stack:
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
	var result := InventoryResult.make(incoming.quantity, incoming.quantity - remaining, "inventory full" if remaining > 0 else "")
	if result.changed > 0:
		changed.emit()
	return result

func preview_exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	var preview := InventoryModel.new(capacity, definition_resolver)
	preview.initialize(stacks())
	for stack in inputs:
		if stack.quantity <= 0 or not preview.remove_item(stack.item_id, stack.quantity).success:
			return CommandResult.make(false, "Not enough resources", inputs)
	for stack in outputs:
		var added: InventoryResult = preview.add_stack(stack)
		if not added.success:
			return CommandResult.make(false, "Not enough storage space", outputs)
	return CommandResult.make(true)

func exchange(inputs: Array[ItemStack], outputs: Array[ItemStack]) -> CommandResult:
	var result: CommandResult = preview_exchange(inputs, outputs)
	if not result.success:
		return result
	var staged := InventoryModel.new(capacity, definition_resolver)
	staged.initialize(stacks())
	for stack in inputs:
		staged.remove_item(stack.item_id, stack.quantity)
	for stack in outputs:
		staged.add_stack(stack)
	initialize(staged.stacks())
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

## Bulk initialization from validated typed start content; keeps the stack model.
func initialize(stacks_to_copy: Array[ItemStack]) -> void:
	_stacks.clear()
	for stack in stacks_to_copy:
		_stacks.append(stack.duplicate_stack())
	changed.emit()

func to_array() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for stack in _stacks:
		result.append(stack.to_dict())
	return result

func restore(data: Array) -> PackedStringArray:
	var errors := PackedStringArray()
	_stacks.clear()
	restore_overflow.clear()
	for raw in data:
		if not raw is Dictionary or not SaveData.valid_stack(raw, errors):
			errors.append("invalid inventory record")
			continue
		var stack := ItemStack.from_dict(raw)
		var definition: ItemDefinition = definition_resolver.call(stack.item_id) as ItemDefinition if definition_resolver.is_valid() else null
		if definition == null:
			errors.append("unknown item id in save: %s" % stack.item_id)
			continue
		if stack.quantity <= 0:
			errors.append("nonpositive item quantity in save: %s" % stack.item_id)
			continue
		if stack.quantity > definition.max_stack:
			errors.append("oversized stack split in save: %s" % stack.item_id)
		var result: InventoryResult = add_stack(stack)
		if result.remainder > 0:
			var overflow := stack.duplicate_stack()
			overflow.quantity = result.remainder
			restore_overflow.append(overflow)
			errors.append("inventory overflow retained for recovery: %s x%d" % [stack.item_id, result.remainder])
	changed.emit()
	return errors
