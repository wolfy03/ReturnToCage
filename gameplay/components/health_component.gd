class_name HealthComponent
extends Node

signal health_changed(current: float, maximum: float)
signal damaged(context: DamageContext)
signal died(context: DamageContext)

@export var max_health: float = 100.0
@export var defense: float = 0.0
@export var invulnerability_seconds: float = 0.35
var current_health: float
var invulnerable_remaining: float = 0.0
var god_mode: bool = false
## Evasion gate owned by the actor's dodge, deliberately separate from both the
## post-hit contact window above and from god_mode. It has no timer of its own:
## [PlayerDodgeComponent] opens and closes it from the authored i-frame window,
## so there is exactly one owner of that duration.
var evasion_invulnerable: bool = false

func _ready() -> void:
	current_health = max_health
	health_changed.emit(current_health, max_health)

func _process(delta: float) -> void:
	invulnerable_remaining = maxf(0.0, invulnerable_remaining - delta)

## Opened and closed by the owning dodge. Kept as an explicit setter so the gate
## always has a single, visible owner.
func set_evasion_invulnerable(value: bool) -> void:
	evasion_invulnerable = value

func receive_damage(context: DamageContext) -> bool:
	if god_mode or current_health <= 0.0 or invulnerable_remaining > 0.0:
		return false
	# Evasion only turns aside hits a dodge is meant to beat. Starvation and
	# timed effects opt out with can_be_evaded = false and still land.
	if evasion_invulnerable and context != null and context.can_be_evaded:
		return false
	current_health = maxf(0.0, current_health - maxf(1.0, context.amount - defense))
	invulnerable_remaining = invulnerability_seconds
	damaged.emit(context)
	health_changed.emit(current_health, max_health)
	if current_health <= 0.0:
		died.emit(context)
	return true

func heal(amount: float) -> void:
	current_health = minf(max_health, current_health + maxf(0.0, amount))
	health_changed.emit(current_health, max_health)

func restore_state(data: Dictionary) -> void:
	max_health = float(data.get("max_health", max_health))
	current_health = clampf(float(data.get("current_health", max_health)), 0.0, max_health)
	health_changed.emit(current_health, max_health)

func receive_periodic_damage(amount: float) -> bool:
	# Timed effects use exact Resource ticks, independent of contact invulnerability.
	if god_mode or current_health <= 0.0 or amount <= 0.0:
		return false
	var context := DamageContext.new(amount, &"periodic", get_parent(), &"effect")
	context.causes_hurt = false
	context.can_be_evaded = false
	current_health = maxf(0.0, current_health - amount)
	damaged.emit(context)
	health_changed.emit(current_health, max_health)
	if current_health <= 0.0:
		died.emit(context)
	return true
