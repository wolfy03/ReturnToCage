class_name EquipmentDefinition
extends ItemDefinition

enum EquipmentSlot { MAIN_HAND, BODY }

@export var equipment_slot: EquipmentSlot = EquipmentSlot.BODY
@export var stat_modifiers: Dictionary[StringName, float] = {}
@export_range(0, 999, 1) var max_durability: int = 100
@export var equip_effects: Array[EffectDefinition] = []

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if equipment_slot not in EquipmentSlot.values() or max_durability < 0:
		errors.append("%s: invalid equipment slot or durability" % id)
	for stat in stat_modifiers:
		if stat == &"" or not is_finite(stat_modifiers[stat]):
			errors.append("%s: invalid equipment stat modifier" % id)
	for effect in equip_effects:
		if effect == null:
			errors.append("%s: null equip effect" % id)
		else:
			errors.append_array(effect.validate_definition(registry))
	return errors
