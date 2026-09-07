class_name CraftingService
extends RefCounted

static func craft(recipe: RecipeDefinition, settlement: SettlementState, progression: ProgressionState) -> CommandResult:
	if recipe == null:
		return CommandResult.make(false, "Unknown recipe")
	if not recipe.required_facility_id.is_empty() and (not settlement.facility_levels.has(recipe.required_facility_id) or settlement.facility_levels[recipe.required_facility_id] < recipe.required_facility_level):
		return CommandResult.make(false, "Required crafting facility level missing")
	for flag in recipe.unlock_flags:
		if not progression.unlocked_flags.has(flag):
			return CommandResult.make(false, "Crafting recipe locked")
	if recipe.input_item_ids.size() != recipe.input_amounts.size() or recipe.output_item_ids.size() != recipe.output_amounts.size():
		return CommandResult.make(false, "Invalid recipe data")
	for amount in recipe.input_amounts + recipe.output_amounts:
		if amount <= 0:
			return CommandResult.make(false, "Invalid recipe quantity")
	return settlement.storage.exchange(ProgressionService.item_amounts(recipe.input_item_ids, recipe.input_amounts), ProgressionService.item_amounts(recipe.output_item_ids, recipe.output_amounts))
