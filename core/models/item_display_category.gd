class_name ItemDisplayCategory
extends RefCounted

enum Kind { EQUIPMENT, CONSUMABLE, OTHER, QUEST }

static func for_item(definition: ItemDefinition) -> Kind:
	if definition is EquipmentDefinition:
		return Kind.EQUIPMENT
	if definition != null:
		if definition.category == ItemDefinition.ItemCategory.QUEST:
			return Kind.QUEST
		if definition.category in [ItemDefinition.ItemCategory.FOOD, ItemDefinition.ItemCategory.DRINK, ItemDefinition.ItemCategory.RETURN_ITEM] or definition.is_consumable():
			return Kind.CONSUMABLE
	return Kind.OTHER
