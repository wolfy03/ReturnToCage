class_name SurvivalConfig
extends ContentDefinition

@export_range(1.0, 1000.0, 1.0) var max_hunger: float = 100.0
@export_range(1.0, 1000.0, 1.0) var max_thirst: float = 100.0
@export_range(0.0, 100.0, 0.01) var hunger_drain_per_second: float = 0.12
@export_range(0.0, 100.0, 0.01) var thirst_drain_per_second: float = 0.18
@export_range(0.0, 1.0, 0.01) var warning_threshold: float = 0.5
@export_range(0.0, 1.0, 0.01) var critical_threshold: float = 0.2
@export_range(0.0, 100.0, 0.01) var starvation_damage_per_second: float = 1.0
@export_range(0.0, 1.0, 0.01) var critical_stamina_multiplier: float = 0.6

func stage_for_ratio(ratio: float) -> int:
	if ratio <= 0.0:
		return 3
	if ratio < critical_threshold:
		return 2
	if ratio < warning_threshold:
		return 1
	return 0

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if critical_threshold >= warning_threshold:
		errors.append("%s: critical threshold must be below warning threshold" % id)
	return errors
