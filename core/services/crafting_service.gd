class_name CraftingService
extends RefCounted

static func craft(recipe: RecipeDefinition, settlement: SettlementState, progression: ProgressionState, owner_inventory: InventoryModel = null) -> CommandResult:
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
	var inputs := ProgressionService.item_amounts(recipe.input_item_ids, recipe.input_amounts)
	var outputs := ProgressionService.item_amounts(recipe.output_item_ids, recipe.output_amounts)
	if recipe.output_to_player_inventory:
		if owner_inventory == null or not owner_inventory.definition_resolver.is_valid():
			return CommandResult.make(false, "Recipe requires a player inventory")
		for stack in outputs:
			var gear := owner_inventory.definition_resolver.call(stack.item_id) as EquipmentDefinition
			if gear != null and gear.max_durability > 0:
				stack.durability = gear.max_durability
		return settlement.storage.transfer_to(owner_inventory, inputs, outputs)
	return settlement.storage.exchange(inputs, outputs)
