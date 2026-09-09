class_name LootRollService
extends RefCounted

static func roll(table: LootTableDefinition, resolver: Callable, multiplier: float = 1.0, rng: RandomNumberGenerator = null) -> Array[ItemStack]:
	if table == null:
		return []
	var errors := table.validate_definition(ContentRegistry)
	if not errors.is_empty():
		return []
	var source := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		source.randomize()
	var results := table.roll(source, multiplier)
	for stack in results:
		var definition := resolver.call(stack.item_id) as ItemDefinition if resolver.is_valid() else null
		if not StackValidation.runtime_error(stack, definition).is_empty():
			return []
	return results
