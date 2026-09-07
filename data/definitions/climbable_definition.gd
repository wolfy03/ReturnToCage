class_name ClimbableDefinition
extends ContentDefinition

enum Kind { LADDER, ROPE }
@export var display_name: String = ""
@export var kind: Kind = Kind.LADDER
@export_range(0.1, 5.0) var speed_multiplier: float = 0.65
@export_range(1.0, 100.0) var alignment_tolerance: float = 28.0
@export_range(1.0, 1000.0) var alignment_speed: float = 100.0
@export var allow_top_exit: bool = true
@export var allow_bottom_exit: bool = true
@export var allow_jump_exit: bool = true
@export var requires_interaction: bool = false
@export var drop_on_damage: bool = true

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if not is_finite(speed_multiplier) or speed_multiplier <= 0.0 or not is_finite(alignment_tolerance) or alignment_tolerance <= 0.0 or not is_finite(alignment_speed) or alignment_speed <= 0.0:
		errors.append("%s: invalid climb speed or alignment" % id)
	return errors
