class_name PlayerDodgeComponent
extends Node
## Scene-local owner of the player dodge: its timeline, its i-frame window and
## its named control lock.
##
## Boundaries mirror the attack timeline. [CombatActionController] owns the
## state transition, [MovementComponent] owns locomotion and collision,
## [HealthComponent] owns whether a hit lands, and [CombatRuntimeState] owns
## stamina. This component owns none of those — it only drives the timeline and
## tells each owner when its window opens and closes.
##
## Everything here runs on the authoritative simulation only. A remote
## presentation actor never ticks this component; it mirrors the dodge it is
## told about and decides nothing itself.

## Authored timing and cost. A missing or invalid definition rejects every
## dodge rather than falling back to numbers invented in code.
@export var definition: DodgeDefinition

## Seconds since the dodge started. Zero while idle.
var elapsed: float = 0.0
## Sign of the committed direction, frozen at the start of the dodge so that
## late input cannot steer a roll that is already running.
var direction: float = 0.0
var actor: PlayerActor
var action: CombatActionController
var combat: CombatComponent
var movement: MovementComponent
var health: HealthComponent
var _invulnerable: bool = false

func configure(
	p_actor: PlayerActor,
	p_action: CombatActionController,
	p_combat: CombatComponent,
	p_movement: MovementComponent,
	p_health: HealthComponent
) -> void:
	actor = p_actor
	action = p_action
	combat = p_combat
	movement = p_movement
	health = p_health
	if definition == null:
		push_error("PlayerDodgeComponent requires a DodgeDefinition; dodges will be rejected")

func is_active() -> bool:
	return action != null and action.is_dodging()

## True only inside the authored i-frame window, never merely because a dodge is
## running: the recovery tail of a dodge is punishable.
func is_invulnerable() -> bool:
	return _invulnerable

func remaining() -> float:
	if not is_active() or definition == null:
		return 0.0
	return maxf(0.0, definition.duration_seconds - elapsed)

## Starts a dodge. Returns true only when the dodge actually began, in which case
## stamina has been committed exactly once — a dodge is never refunded, not by
## a wall, not by a ledge, and not by being interrupted with hit-stun.
##
## Grounded start only: an air dodge would need its own locomotion rules, and
## this stage adds no locomotion mode. Rolling off a ledge mid-dodge is allowed
## and simply becomes a normal AIR fall under gravity.
##
## An in-progress return-item channel does not block a dodge; a committed dodge
## cancels it. A rejected dodge changes nothing at all.
func try_begin(requested_direction: float) -> bool:
	if definition == null or action == null or combat == null or movement == null \
			or not definition.validation_errors().is_empty():
		return false
	if actor == null or actor.is_death_handled():
		return false
	if health != null and health.current_health <= 0.0:
		return false
	# DODGE is only reachable from IDLE, so an attack cannot be rolled out of and
	# hit-stun cannot be escaped early. The action axis is the single lock-out.
	if not action.is_idle() or not action.can_transition_to(CombatActionController.State.DODGE):
		return false
	# Grounded means actually standing on something, not merely a locomotion mode
	# that says so. `mode` is written once per physics tick and can be one frame
	# stale, which would otherwise let an airborne actor start a ground dodge.
	if movement.mode != MovementComponent.Mode.GROUND or not actor.is_on_floor():
		return false
	if not combat.can_spend_stamina(definition.stamina_cost):
		return false
	var committed := _resolve_direction(requested_direction)
	if committed == 0.0:
		return false
	if not action.enter_dodge():
		return false
	if not combat.spend_stamina(definition.stamina_cost):
		# Stamina is the last thing committed; if it cannot be paid the dodge
		# never happened and the action axis goes straight back to IDLE.
		action.finish_dodge()
		return false
	# From here the dodge is committed, so it may now interrupt a return channel.
	# Doing this only after every check means a rejected dodge leaves an
	# in-progress channel — and `movement.enabled` — exactly as it found them.
	actor.cancel_return_channel_for_combat()
	direction = committed
	elapsed = 0.0
	movement.set_control_lock(MovementComponent.CONTROL_LOCK_DODGE, true)
	actor.facing = committed
	_apply_dodge_velocity()
	_refresh_invulnerability()
	return true

## Advances the dodge. Ticked explicitly by the authoritative PlayerActor before
## locomotion, so the roll velocity is already in place when the body moves.
func physics_tick(delta: float) -> void:
	if not is_active() or definition == null or delta <= 0.0:
		return
	elapsed += delta
	if elapsed >= definition.duration_seconds:
		_finish()
		return
	_apply_dodge_velocity()
	_refresh_invulnerability()

## Ends the dodge because the actor was hit. Only [PlayerHurtComponent] calls
## this, immediately before the DODGE -> HURT transition it owns.
##
## Deliberately leaves velocity alone: the damage path has already applied the
## knockback impulse, and zeroing it here would swallow the hit reaction.
func interrupt_for_hurt() -> void:
	_clear(false)

## Lifecycle cleanup (death, teardown). Returns the action axis to IDLE itself
## because no other owner is left to do it.
func reset() -> void:
	_clear(true)

## The dodge ran its full authored duration.
##
## Only the horizontal roll velocity this component wrote is cleared. Without
## that, the authored speed would survive the dodge and coast away under normal
## deceleration. Vertical velocity is left alone so a dodge that rolled off a
## ledge keeps falling at the speed gravity gave it.
func _finish() -> void:
	if actor != null:
		actor.velocity.x = 0.0
	_clear(false)
	if action != null:
		action.finish_dodge()

## Releases everything this component owns: the i-frame gate, the dodge control
## lock and the timeline. Never touches the attack timeline or velocity — it is
## shared by the normal finish, the hit-stun interrupt and lifecycle cleanup, and
## clearing velocity here would swallow the knockback of the hit that interrupted
## the dodge. Only [method _finish] clears the roll velocity.
func _clear(reset_action: bool) -> void:
	elapsed = 0.0
	direction = 0.0
	_set_invulnerable(false)
	if movement != null:
		movement.set_control_lock(MovementComponent.CONTROL_LOCK_DODGE, false)
	if reset_action and action != null and action.is_dodging():
		action.reset()

## Resolves the committed facing of the roll.
##
## Callers hand over a canonical direction: exactly -1 or +1 when the player
## expressed one, and 0 when they did not. Only 0 falls back to the actor's
## current facing; any other non-canonical value is a broken request and is
## rejected rather than rounded into a usable roll. Returning 0 means "no dodge".
func _resolve_direction(requested_direction: float) -> float:
	if not is_finite(requested_direction):
		return 0.0
	if requested_direction == 1.0 or requested_direction == -1.0:
		return requested_direction
	if requested_direction != 0.0:
		return 0.0
	if actor != null and is_finite(actor.facing):
		return signf(actor.facing)
	return 0.0

## Constant horizontal speed for the whole dodge. Vertical velocity is left to
## gravity and the body's own collision response, so the roll falls off ledges
## and is stopped by walls without this component knowing about either.
func _apply_dodge_velocity() -> void:
	if actor == null or definition == null:
		return
	actor.velocity.x = direction * definition.speed

func _refresh_invulnerability() -> void:
	_set_invulnerable(definition != null and definition.is_invulnerable_at(elapsed))

func _set_invulnerable(value: bool) -> void:
	_invulnerable = value
	if health != null:
		health.set_evasion_invulnerable(value)
