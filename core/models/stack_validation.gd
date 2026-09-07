class_name StackValidation
extends RefCounted
## Shared item boundary. -1 means unspecified durability, never damage below zero.

static func basic_error(stack: ItemStack) -> String:
	if stack == null or stack.item_id.is_empty() or stack.quantity <= 0 or not SaveData.is_integer(stack.quantity):
		return "item id and positive quantity required"
	if not stack.instance_id.is_empty() and stack.quantity != 1:
		return "instance quantity must be 1"
	return ""

static func runtime_error(stack: ItemStack, definition: ItemDefinition) -> String:
	var error: String = basic_error(stack)
	if not error.is_empty():
		return error
	if definition == null or definition.max_stack < 1:
		return "unknown or invalid item: %s" % stack.item_id
	if not SaveData.is_integer(stack.durability) or stack.durability < -1 or (definition is EquipmentDefinition and stack.durability > definition.max_durability):
		return "invalid durability: %s" % stack.item_id
	return ""

static func from_record(raw: Variant, resolver: Callable, errors: PackedStringArray, context: String, allow_unknown: bool = false) -> ItemStack:
	if not raw is Dictionary:
		errors.append("%s: expected stack object" % context)
		return null
	if not SaveData.valid_stack(raw, errors, context):
		return null
	var stack: ItemStack = ItemStack.from_dict(raw)
	var definition: ItemDefinition = resolver.call(stack.item_id) as ItemDefinition if resolver.is_valid() else null
	if definition == null and not allow_unknown:
		errors.append("unknown item in %s: %s" % [context, stack.item_id])
		return null
	if definition != null and definition.max_stack < 1:
		errors.append("invalid item definition in %s: %s" % [context, stack.item_id])
		return null
	var durability: int = stack.durability
	if durability < -1:
		stack.durability = 0
	if definition is EquipmentDefinition and stack.durability > definition.max_durability:
		stack.durability = definition.max_durability
	if durability != stack.durability:
		errors.append("%s: durability clamped from %d to %d" % [context, durability, stack.durability])
	if definition == null:
		errors.append("%s retained for unavailable item: %s" % [context, stack.item_id])
	return stack

static func accept_instance(stack: ItemStack, seen: Dictionary[String, String], errors: PackedStringArray, context: String) -> bool:
	if stack.instance_id.is_empty():
		return true
	if seen.has(stack.instance_id):
		errors.append("duplicate instance ignored in %s: %s (first in %s)" % [context, stack.instance_id, seen[stack.instance_id]])
		return false
	seen[stack.instance_id] = context
	return true
