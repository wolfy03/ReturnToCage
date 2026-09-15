class_name AttackComboDefinition
extends Resource
## The ordered attack steps of one weapon.
##
## A plain [Resource] like the definitions it contains, not registry content.
## Every weapon has exactly one of these, including weapons that only ever swing
## once — those simply author a single step. There is no separate "single
## attack" path to keep in sync.
##
## The combo length is authored, never assumed: a weapon may have one step or
## five.
##
## Attack mode is not per-step in the current model. [WeaponDefinition] owns
## `attack_mode` and `attack_scene`, and the strategy is chosen from the weapon,
## so every step of one combo is executed the same way. A mixed combo
## (melee into projectile and back) would need those fields to move down here and
## is deliberately out of scope; each step owns only its timing, geometry,
## knockback and follow-up windows.

@export var steps: Array[AttackDefinition] = []

func step_count() -> int:
	return steps.size()

## The step at [param index], or null when the index is outside the combo. A
## null return is how callers discover that a combo has ended.
func step(index: int) -> AttackDefinition:
	if index < 0 or index >= steps.size():
		return null
	return steps[index]

func has_step(index: int) -> bool:
	return index >= 0 and index < steps.size()

func validation_errors(owner_id: StringName = &"") -> PackedStringArray:
	var errors := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	if steps.is_empty():
		errors.append("%sattack combo must author at least one step" % prefix)
	for index in steps.size():
		var step_definition := steps[index]
		if step_definition == null:
			errors.append("%sattack combo step %d is null" % [prefix, index])
			continue
		errors.append_array(step_definition.validation_errors(
			StringName("%s step %d" % [owner_id, index]) if not owner_id.is_empty() else StringName("step %d" % index)
		))
	return errors
