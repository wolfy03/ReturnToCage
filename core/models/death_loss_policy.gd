class_name DeathLossPolicy
extends RefCounted

static func apply(stacks: Array[ItemStack], difficulty: DifficultyDefinition, resolver: Callable) -> DeathLossResult:
	var result := DeathLossResult.new()
	for stack in stacks:
		var definition: ItemDefinition = resolver.call(stack.item_id) if resolver.is_valid() else null
		if definition != null and definition.quest_protected:
			result.kept.append(stack.duplicate_stack())
			continue
		var lose_amount := 0
		match difficulty.inventory_loss:
			DifficultyDefinition.InventoryLoss.NONE:
				lose_amount = 0
			DifficultyDefinition.InventoryLoss.HALF:
				lose_amount = stack.quantity / 2
			DifficultyDefinition.InventoryLoss.ALL:
				lose_amount = stack.quantity
		if lose_amount < stack.quantity:
			result.kept.append(ItemStack.new(stack.item_id, stack.quantity - lose_amount))
		if lose_amount > 0:
			var lost_stack := ItemStack.new(stack.item_id, lose_amount)
			result.lost.append(lost_stack)
			if difficulty.recovery_policy == DifficultyDefinition.RecoveryPolicy.DROP_AT_DEATH:
				result.world_drops.append(lost_stack.duplicate_stack())
	return result

static func apply_equipment(stacks: Array[ItemStack], difficulty: DifficultyDefinition) -> DeathLossResult:
	var result := DeathLossResult.new()
	for stack in stacks:
		var copy := stack.duplicate_stack()
		match difficulty.equipment_loss:
			DifficultyDefinition.EquipmentLoss.PROTECT:
				result.equipment_kept.append(copy)
			DifficultyDefinition.EquipmentLoss.DAMAGE:
				if copy.durability >= 0:
					copy.durability = maxi(0, copy.durability - maxi(1, copy.durability / 4))
				result.equipment_kept.append(copy)
			DifficultyDefinition.EquipmentLoss.LOSE:
				result.equipment_lost.append(copy)
	return result
