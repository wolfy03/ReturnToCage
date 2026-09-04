class_name ItemUseService
extends RefCounted

static func use_item(inventory: InventoryModel, survival: SurvivalComponent, effects: EffectController, item_id: StringName, resolver: Callable) -> bool:
	var definition: ItemDefinition = resolver.call(item_id) if resolver.is_valid() else null
	if definition == null or not definition.is_consumable() or inventory.count(item_id) <= 0:
		return false
	if inventory.remove_item(item_id, 1).changed != 1:
		return false
	if survival != null:
		survival.consume(definition)
	if effects != null:
		effects.apply_item(definition)
	return true
