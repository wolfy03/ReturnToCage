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

func _ready() -> void:
	current_health = max_health
	health_changed.emit(current_health, max_health)

func _process(delta: float) -> void:
	invulnerable_remaining = maxf(0.0, invulnerable_remaining - delta)

func receive_damage(context: DamageContext) -> bool:
	if god_mode or current_health <= 0.0 or invulnerable_remaining > 0.0:
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
