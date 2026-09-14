class_name CombatTestFixtures
extends RefCounted
## Shared construction helpers for combat test fixtures.
##
## A weapon owns an [AttackComboDefinition] rather than a single attack, so most
## fixtures that used to assign one definition now need a one-step combo. Doing
## that in one place keeps the tests about behaviour instead of about wrapping.

## Wraps one step in the combo a weapon needs. Weapons that only ever swing once
## are authored exactly this way in production too.
static func single_step_combo(step: AttackDefinition) -> AttackComboDefinition:
	var combo := AttackComboDefinition.new()
	combo.steps = [step] as Array[AttackDefinition]
	return combo

static func combo_of(steps: Array[AttackDefinition]) -> AttackComboDefinition:
	var combo := AttackComboDefinition.new()
	combo.steps = steps.duplicate() as Array[AttackDefinition]
	return combo

## The first step of a weapon's combo, or null when it has none.
static func first_step(weapon: WeaponDefinition) -> AttackDefinition:
	if weapon == null or weapon.attack_combo == null:
		return null
	return weapon.attack_combo.step(0)

## An always-open window covering a whole recovery phase, for fixtures that care
## about chaining rather than about window timing.
static func open_window(start_seconds: float, end_seconds: float) -> CombatActionWindowDefinition:
	var window := CombatActionWindowDefinition.new()
	window.enabled = true
	window.start_seconds = start_seconds
	window.end_seconds = end_seconds
	return window
