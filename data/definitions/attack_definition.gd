class_name AttackDefinition
extends Resource
## Timing and spatial properties of one attack, embedded in the
## [WeaponDefinition] that owns it.
##
## Deliberately a plain [Resource] and not a [ContentDefinition]: this is not
## standalone content with its own id registered in ContentRegistry, it only
## exists as a sub-resource of a weapon.
##
## Nothing here knows about the network. Values are authored as static content
## and snapshotted by the authoritative combat path when an attack starts.

## Wind-up before the attack commits. No hit can land during this phase.
@export_range(0.01, 10.0, 0.01) var startup_seconds: float = 0.10
## How long the attack is live. For melee this is exactly how long the hitbox
## stays armed, so it is the only source for that window.
@export_range(0.01, 10.0, 0.01) var active_seconds: float = 0.12
## Lock-out after the attack. Replaces the old per-weapon attack cooldown.
@export_range(0.01, 10.0, 0.01) var recovery_seconds: float = 0.33

## Logical reach metadata. Melee collision is defined independently by the
## rectangle geometry below; projectiles use this as their travel distance.
@export_range(1.0, 2000.0, 1.0) var range: float = 52.0
## Current melee rectangle dimensions. Shape-type abstraction is intentionally
## deferred until authored attacks require more than rectangles.
@export var hitbox_size: Vector2 = Vector2(52.0, 30.0)
## Attacker-local rectangle offset. Only x is mirrored by facing.
@export var hitbox_offset: Vector2 = Vector2(26.0, 0.0)
## Attacker-local impulse. Positive x means forward; y uses Godot world axes.
@export var knockback: Vector2 = Vector2(120.0, -40.0)

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
	if not is_finite(range) or range <= 0.0:
		errors.append("%sattack range must be positive and finite" % prefix)
	if not is_finite(hitbox_size.x) or not is_finite(hitbox_size.y) \
			or hitbox_size.x <= 0.0 or hitbox_size.y <= 0.0:
		errors.append("%sattack hitbox_size components must be positive and finite" % prefix)
	if not is_finite(hitbox_offset.x) or not is_finite(hitbox_offset.y):
		errors.append("%sattack hitbox_offset components must be finite" % prefix)
	if not is_finite(knockback.x) or not is_finite(knockback.y):
		errors.append("%sattack knockback components must be finite" % prefix)
	return errors
