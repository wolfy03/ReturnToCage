class_name PlayerHurtComponent
extends Node
## Scene-local owner of player hit-stun duration and its control lock.
##
## CombatActionController owns only state transitions, CombatComponent owns the
## attack timeline, PlayerDodgeComponent owns the dodge timeline, and
## MovementComponent owns locomotion/physics. This component coordinates those
## boundaries without owning damage or knockback.
##
## HURT is the single interrupt point: it is the only place that ends an attack
## or a dodge because the actor was hit, and it holds its own named control lock
## so an interrupted dodge cannot hand control back mid hit-stun.

@export_range(0.01, 5.0, 0.01) var duration_seconds: float = 0.25

var remaining: float = 0.0
var actor: PlayerActor
var action: CombatActionController
var combat: CombatComponent
var movement: MovementComponent
var dodge: PlayerDodgeComponent

func configure(
	p_actor: PlayerActor,
	p_action: CombatActionController,
	p_combat: CombatComponent,
	p_movement: MovementComponent,
	p_dodge: PlayerDodgeComponent = null
) -> void:
	actor = p_actor
	action = p_action
	combat = p_combat
	movement = p_movement
	dodge = p_dodge

func is_active() -> bool:
	return action != null and action.is_hurt()

## Starts hit-stun or refreshes its timer. Attack cleanup happens only after the
## direct HURT transition has been validated, and never inserts an IDLE state.
func begin_hurt() -> bool:
	if action == null or combat == null or movement == null \
			or not is_finite(duration_seconds) or duration_seconds <= 0.0:
		return false
	if action.is_hurt():
		remaining = duration_seconds
		movement.set_control_lock(MovementComponent.CONTROL_LOCK_HURT, true)
		return true
	if not action.can_transition_to(CombatActionController.State.HURT):
		return false
	if action.is_attacking():
		combat.interrupt_attack_for_hurt()
	elif action.is_dodging() and dodge != null:
		# Drops the i-frames and the dodge's own control lock, but never touches
		# velocity: the knockback impulse was already applied by the damage path.
		dodge.interrupt_for_hurt()
	if not action.enter_hurt():
		return false
	remaining = duration_seconds
	movement.set_control_lock(MovementComponent.CONTROL_LOCK_HURT, true)
	return true

## Ticked explicitly by the authoritative PlayerActor before locomotion.
func physics_tick(delta: float) -> void:
	if not is_active() or delta <= 0.0:
		return
	remaining = maxf(0.0, remaining - delta)
	if remaining > 0.0:
		return
	if action.finish_hurt():
		movement.set_control_lock(MovementComponent.CONTROL_LOCK_HURT, false)

## Lifecycle cleanup only. Attack cleanup remains CombatComponent's job.
func reset() -> void:
	remaining = 0.0
	if movement != null:
		movement.set_control_lock(MovementComponent.CONTROL_LOCK_HURT, false)
	if action != null and action.is_hurt():
		action.reset()
