class_name RespawnPolicy
extends ContentDefinition

@export_range(0.01, 1.0) var health_ratio: float = 1.0
@export_range(0.0, 1.0) var hunger_ratio: float = 0.5
@export_range(0.0, 1.0) var thirst_ratio: float = 0.5

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if not is_finite(health_ratio) or health_ratio <= 0.0 or health_ratio > 1.0 or not is_finite(hunger_ratio) or hunger_ratio < 0.0 or hunger_ratio > 1.0 or not is_finite(thirst_ratio) or thirst_ratio < 0.0 or thirst_ratio > 1.0:
		errors.append("%s: invalid respawn recovery ratios" % id)
	return errors
