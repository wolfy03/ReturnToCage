class_name CombatRuntimeState
extends RefCounted
## Transient, per-life combat state owned by [PlayerRuntimeState].
##
## This is the single canonical owner of a player's stamina. Scene components
## (CombatComponent) only reference it and nothing here is saved to disk. Rates
## and costs stay in StatBlock and WeaponDefinition — this object only holds the
## current values.
##
## The authoritative server owns these values; a client mirrors them through
## [method apply_values]. This model deliberately knows nothing about
## NetworkManager, RPCs or peer routing — replication lives in the network layer.

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

## Applies an externally authoritative pair at once. Callers that mirror another
## simulation must use this instead of [method set_max_stamina] plus a direct
## assignment, so the clamp order never leaks outside this model. Returns false
## and changes nothing when the pair is not a valid combat state.
func apply_values(p_stamina: float, p_max_stamina: float) -> bool:
	if not is_finite(p_stamina) or not is_finite(p_max_stamina) \
		or p_max_stamina < 0.0 or p_stamina < 0.0 or p_stamina > p_max_stamina:
		return false
	max_stamina = p_max_stamina
	stamina = p_stamina
	return true

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
