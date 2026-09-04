class_name FacilityLevelDefinition
extends Resource

@export_range(0, 20, 1) var level: int = 0
@export var cost_item_ids: Array[StringName] = []
@export var cost_amounts: Array[int] = []
@export var unlock_flags: Array[StringName] = []
@export var appearance_color: Color = Color.WHITE
@export var interaction_points: Array[StringName] = []
