class_name EffectDefinition
extends ContentDefinition

enum EffectKind { STAT_MODIFIER, PERIODIC_HEAL, PERIODIC_DAMAGE }
enum Operation { ADD, MULTIPLY }
enum StackPolicy { REPLACE, REFRESH, STACK }

@export var display_name: String = ""
@export_multiline var description: String = ""
@export var kind: EffectKind = EffectKind.STAT_MODIFIER
@export var target_stat: StringName
@export var operation: Operation = Operation.ADD
@export var magnitude: float = 0.0
@export_range(0.0, 3600.0, 0.1) var duration_seconds: float = 0.0
@export var stack_policy: StackPolicy = StackPolicy.REFRESH
@export_range(1, 99, 1) var max_stacks: int = 1
@export var icon: Texture2D

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if max_stacks < 1:
		errors.append("%s: max_stacks must be positive" % id)
	if duration_seconds < 0.0:
		errors.append("%s: duration_seconds must not be negative" % id)
	return errors
