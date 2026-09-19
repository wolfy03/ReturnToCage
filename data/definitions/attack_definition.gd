class_name AttackDefinition
extends Resource
## Timing and spatial properties of one attack step, embedded in the
## [AttackComboDefinition] that orders it.
##
## One of these is a single swing, not a whole attack: a weapon's combo is a list
## of them, and each step authors its own timing, geometry, knockback and
## follow-up windows independently.
##
## Deliberately a plain [Resource] and not a [ContentDefinition]: this is not
## standalone content with its own id registered in ContentRegistry, it only
## exists as a sub-resource of a weapon.
##
## Nothing here knows about the network. AttackDefinition/WeaponDefinition are
## immutable authored Resources held by reference during an attack; they are not
## deep-copied per use. Runtime combat values such as damage, resolved knockback,
## faction targets and effects are snapshotted when the attack starts.

## Wind-up before the attack commits. No hit can land during this phase.
@export_range(0.01, 10.0, 0.01) var startup_seconds: float = 0.10
## How long the attack is live. For melee this is exactly how long the hitbox
## stays armed, so it is the only source for that window.
@export_range(0.01, 10.0, 0.01) var active_seconds: float = 0.12
## Lock-out after the attack. Replaces the old per-weapon attack cooldown.
@export_range(0.01, 10.0, 0.01) var recovery_seconds: float = 0.33

## Semantic key consumed only by the presentation profile. Gameplay and
## headless validation never resolve this to a texture or animation asset.
@export var presentation_key: StringName = &"attack"

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

## When the next combo step may begin, measured from the start of this step.
## Disabled or absent means this step ends the combo.
@export var chain_window: CombatActionWindowDefinition
## When a dodge may cut this step short. Disabled or absent means the step must
## be seen through to the end.
@export var dodge_cancel_window: CombatActionWindowDefinition

## Full cycle from the input that starts the attack to being able to attack again.
func total_seconds() -> float:
	return startup_seconds + active_seconds + recovery_seconds

## When recovery begins. Every authored follow-up window must sit at or after
## this point: startup and active are commitment, and staying committed to a
## swing that is already live is what makes an attack a decision.
func recovery_start_seconds() -> float:
	return startup_seconds + active_seconds

func can_chain_at(elapsed: float) -> bool:
	return chain_window != null and chain_window.contains(elapsed)

func can_dodge_cancel_at(elapsed: float) -> bool:
	return dodge_cancel_window != null and dodge_cancel_window.contains(elapsed)

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
	if presentation_key.is_empty():
		errors.append("%sattack presentation_key must not be empty" % prefix)
	if not is_finite(range) or range <= 0.0:
		errors.append("%sattack range must be positive and finite" % prefix)
	if not is_finite(hitbox_size.x) or not is_finite(hitbox_size.y) \
			or hitbox_size.x <= 0.0 or hitbox_size.y <= 0.0:
		errors.append("%sattack hitbox_size components must be positive and finite" % prefix)
	if not is_finite(hitbox_offset.x) or not is_finite(hitbox_offset.y):
		errors.append("%sattack hitbox_offset components must be finite" % prefix)
	if not is_finite(knockback.x) or not is_finite(knockback.y):
		errors.append("%sattack knockback components must be finite" % prefix)
	# Follow-up windows live inside recovery only. A window that opened during
	# startup or the live hitbox would turn every attack into a feint.
	var recovery_start := recovery_start_seconds()
	var total := total_seconds()
	if chain_window != null:
		errors.append_array(chain_window.validation_errors(
			StringName("%schain" % prefix) if not prefix.is_empty() else &"chain",
			recovery_start,
			total
		))
	if dodge_cancel_window != null:
		errors.append_array(dodge_cancel_window.validation_errors(
			StringName("%sdodge cancel" % prefix) if not prefix.is_empty() else &"dodge cancel",
			recovery_start,
			total
		))
	return errors
