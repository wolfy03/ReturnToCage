class_name EquipmentDefinition
extends ItemDefinition

enum EquipmentSlot { MAIN_HAND, BODY }

@export var equipment_slot: EquipmentSlot = EquipmentSlot.BODY
@export var stat_modifiers: Dictionary[StringName, float] = {}
@export_range(0, 999, 1) var max_durability: int = 100
@export var equip_effects: Array[EffectDefinition] = []
