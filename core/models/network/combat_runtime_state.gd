class_name CombatRuntimeState
extends RefCounted
## Transient, per-life combat state owned by [PlayerRuntimeState].
##
## This is the single canonical owner of a player's stamina. Scene components
## (CombatComponent) only reference it; nothing here is saved to disk and, in
## this stage, nothing is replicated. Rates and costs stay in StatBlock and
## WeaponDefinition — this object only holds the current values.

var stamina: float = 0.0
var max_stamina: float = 0.0

## Sets the maximum and refills stamina to it (initial spawn, respawn).
func reset(p_max_stamina: float) -> void:
	max_stamina = maxf(0.0, p_max_stamina) if is_finite(p_max_stamina) else 0.0
	stamina = max_stamina

## Applies a changed max (equipment/effect modifiers) without refilling.
func set_max_stamina(value: float) -> void:
	if not is_finite(value):
		return
	max_stamina = maxf(0.0, value)
	stamina = minf(stamina, max_stamina)

func can_spend(amount: float) -> bool:
	return is_finite(amount) and amount >= 0.0 and stamina >= amount

## Deducts [param amount] when affordable; returns false and leaves stamina
## untouched otherwise.
func spend(amount: float) -> bool:
	if not can_spend(amount):
		return false
	stamina -= amount
	return true

## Adds [param amount] (already multiplied by rate, multiplier and delta) and
## clamps to max_stamina. Negative or non-finite amounts are ignored.
func regenerate(amount: float) -> void:
	if not is_finite(amount) or amount <= 0.0:
		return
	stamina = minf(max_stamina, stamina + amount)
