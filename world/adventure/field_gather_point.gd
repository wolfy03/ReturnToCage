@tool
class_name FieldGatherPoint
extends Marker2D

const TARGET_SIZE := Vector2(42, 42)
const SERVER_DISTANCE := 90.0

@export var interaction_id: StringName
@export var item_id: StringName
@export_range(1, 9999, 1, "or_greater") var amount: int = 1
@export var enabled: bool = true
