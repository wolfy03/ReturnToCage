class_name ItemDefinition
extends ContentDefinition

enum ItemCategory { RESOURCE, FOOD, DRINK, RETURN_ITEM, WEAPON, ARMOR, QUEST }
enum FoodSlot { NONE, STAPLE, DRINK, SNACK, INSTANT }

@export var display_name: String = ""
@export_multiline var description: String = ""
@export var icon: Texture2D
@export var category: ItemCategory = ItemCategory.RESOURCE
@export_range(1, 999, 1) var max_stack: int = 99
@export_range(0.0, 999.0, 0.01) var weight: float = 0.0
@export_range(0, 999999, 1) var base_value: int = 0
@export var discardable: bool = true
@export var quest_protected: bool = false
@export var hunger_restore: float = 0.0
@export var thirst_restore: float = 0.0
@export var food_slot: FoodSlot = FoodSlot.NONE
@export var use_cooldown: float = 0.0
@export var effects: Array[EffectDefinition] = []
@export var tags: Array[StringName] = []

func is_consumable() -> bool:
	return hunger_restore > 0.0 or thirst_restore > 0.0 or not effects.is_empty()

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if display_name.is_empty():
		errors.append("%s: display_name must not be empty" % id)
	if max_stack < 1:
		errors.append("%s: max_stack must be positive" % id)
	if weight < 0.0:
		errors.append("%s: weight must not be negative" % id)
	return errors
