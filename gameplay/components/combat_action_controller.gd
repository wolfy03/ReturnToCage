class_name CombatActionController
extends Node
## Combat action axis for an actor, independent from locomotion.
##
## [MovementComponent.Mode] stays locomotion-only (GROUND/AIR/CLIMB); this node
## owns what the actor is doing in combat. The two are separate axes on purpose:
## merging them would require GROUND+ATTACK, AIR+ATTACK, CLIMB+HURT and every
## other combination as its own enum entry.
##
## This controller only stores the current state, validates transitions and
## reports changes. It calculates no damage or stamina, looks up no weapon,
## drives no hitbox or animation, and knows nothing about the network. It does
## not own timing either: [CombatComponent] drives the phase durations from the
## weapon's [AttackDefinition] and calls the transitions below.
##
## Scene-local by design: an attack has no reason to survive a world transition,
## so a new actor simply starts at IDLE. Values that must outlive the scene
## (stamina) live in [CombatRuntimeState] instead.

signal state_changed(previous: State, current: State)

enum State {
	IDLE,
	ATTACK_STARTUP,
	ATTACK_ACTIVE,
	ATTACK_RECOVERY,
}

var _state: State = State.IDLE

func current_state() -> State:
	return _state

func is_idle() -> bool:
	return _state == State.IDLE

## Explicit membership rather than "not IDLE", so adding DODGE/HURT/DEAD later
## cannot silently change what this means.
func is_attacking() -> bool:
	return _state == State.ATTACK_STARTUP \
		or _state == State.ATTACK_ACTIVE \
		or _state == State.ATTACK_RECOVERY

## The gameplay transition graph. Skipping a phase is rejected, so a caller
## cannot jump straight from IDLE into an active hitbox phase.
##
## [codeblock]
## IDLE            -> ATTACK_STARTUP
## ATTACK_STARTUP  -> ATTACK_ACTIVE | IDLE      (cancel)
## ATTACK_ACTIVE   -> ATTACK_RECOVERY | IDLE    (cancel)
## ATTACK_RECOVERY -> IDLE
## [/codeblock]
static func is_allowed_transition(from: State, to: State) -> bool:
	match from:
		State.IDLE:
			return to == State.ATTACK_STARTUP
		State.ATTACK_STARTUP:
			return to == State.ATTACK_ACTIVE or to == State.IDLE
		State.ATTACK_ACTIVE:
			return to == State.ATTACK_RECOVERY or to == State.IDLE
		State.ATTACK_RECOVERY:
			return to == State.IDLE
	return false

func can_transition_to(next_state: State) -> bool:
	return is_allowed_transition(_state, next_state)

## Applies a validated transition. Returns false and changes nothing when the
## transition is not part of the graph, including a request for the current
## state (which would otherwise emit a meaningless change).
func transition_to(next_state: State) -> bool:
	if not can_transition_to(next_state):
		return false
	_set_state(next_state)
	return true

func begin_attack() -> bool:
	return transition_to(State.ATTACK_STARTUP)

func enter_attack_active() -> bool:
	return transition_to(State.ATTACK_ACTIVE)

func enter_attack_recovery() -> bool:
	return transition_to(State.ATTACK_RECOVERY)

func finish_attack() -> bool:
	return transition_to(State.IDLE)

## Aborts an attack that has not reached recovery yet.
func cancel_attack() -> bool:
	if _state != State.ATTACK_STARTUP and _state != State.ATTACK_ACTIVE:
		return false
	return transition_to(State.IDLE)

## Returns to IDLE from any state. Used when an actor is (re)initialised or torn
## down; emits only when the state actually changed.
func reset() -> void:
	_set_state(State.IDLE)

func _set_state(next_state: State) -> void:
	if next_state == _state:
		return
	var previous := _state
	_state = next_state
	state_changed.emit(previous, _state)
