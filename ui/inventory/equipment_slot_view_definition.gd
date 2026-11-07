class_name EquipmentSlotViewDefinition
extends Resource
## UI layout data, independent of item ownership and equipment mutations.

@export var slot: EquipmentDefinition.EquipmentSlot = EquipmentDefinition.EquipmentSlot.MAIN_HAND
@export var label: String = "Main hand"
@export var row: int = 0
@export var empty_icon: Texture2D
