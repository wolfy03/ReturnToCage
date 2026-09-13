class_name AttackDefinition
extends Resource
## Timing of one attack, embedded in the [WeaponDefinition] that owns it.
##
## Deliberately a plain [Resource] and not a [ContentDefinition]: this is not
## standalone content with its own id registered in ContentRegistry, it only
## exists as a sub-resource of a weapon.
##
## This stage covers timing only. Hitbox shape, offset and range stay on the
## weapon, and knockback is still unapplied — both are later stages. Nothing
## here knows about the network; the durations are read, never written, at
## runtime.

## Wind-up before the attack commits. No hit can land during this phase.
@export_range(0.01, 10.0, 0.01) var startup_seconds: float = 0.10
## How long the attack is live. For melee this is exactly how long the hitbox
## stays armed, so it is the only source for that window.
@export_range(0.01, 10.0, 0.01) var active_seconds: float = 0.12
## Lock-out after the attack. Replaces the old per-weapon attack cooldown.
@export_range(0.01, 10.0, 0.01) var recovery_seconds: float = 0.33

## Full cycle from the input that starts the attack to being able to attack again.
func total_seconds() -> float:
	return startup_seconds + active_seconds + recovery_seconds

## Every phase must be a positive, finite duration: a zero-length phase would
## have no observable state and only complicate the timeline loop.
## [param owner_id] is prefixed to each message when the caller has one.
func validation_errors(owner_id: StringName = &"") -> PackedStringArray:
	var errors := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	for phase in [
		["startup_seconds", startup_seconds],
		["active_seconds", active_seconds],
		["recovery_seconds", recovery_seconds],
	]:
		var value: float = phase[1]
		if not is_finite(value) or value <= 0.0:
			errors.append("%sattack %s must be a positive finite duration" % [prefix, phase[0]])
	return errors
