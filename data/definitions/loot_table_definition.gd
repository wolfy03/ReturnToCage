class_name LootTableDefinition
extends ContentDefinition

@export var item_ids: Array[StringName] = []
@export var weights: Array[float] = []
@export var min_amounts: Array[int] = []
@export var max_amounts: Array[int] = []
@export var apply_difficulty_multiplier: bool = true

func roll(rng: RandomNumberGenerator, multiplier: float = 1.0) -> Array[ItemStack]:
	var results: Array[ItemStack] = []
	if item_ids.is_empty():
		return results
	var total := 0.0
	for weight in weights:
		total += maxf(weight, 0.0)
	if total <= 0.0:
		return results
	var pick := rng.randf_range(0.0, total)
	var chosen := item_ids.size() - 1
	for index in item_ids.size():
		pick -= weights[index]
		if pick <= 0.0:
			chosen = index
			break
	var amount := rng.randi_range(min_amounts[chosen], max_amounts[chosen])
	if apply_difficulty_multiplier:
		amount = maxi(1, roundi(amount * multiplier))
	results.append(ItemStack.new(item_ids[chosen], amount))
	return results

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if item_ids.size() != weights.size() or item_ids.size() != min_amounts.size() or item_ids.size() != max_amounts.size():
		errors.append("%s: loot arrays differ" % id)
		return errors
	for index in item_ids.size():
		if not registry.has_id(item_ids[index]):
			errors.append("%s: missing loot item %s" % [id, item_ids[index]])
		if weights[index] <= 0.0 or min_amounts[index] < 0 or max_amounts[index] < min_amounts[index]:
			errors.append("%s: invalid loot range at %d" % [id, index])
	return errors
