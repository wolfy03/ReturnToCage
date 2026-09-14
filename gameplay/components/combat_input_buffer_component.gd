class_name CombatInputBufferComponent
extends Node
## Authoritative scheduler for combat intents that arrive slightly too early.
##
## This is not client prediction and not an input convenience layer. Every intent
## reaching it has already been authenticated, sequenced and life-checked by the
## network boundary; this component decides only *when* a validated intent runs,
## by asking the owners that already know: [CombatComponent] for the attack
## timeline and its authored windows, [PlayerDodgeComponent] for the dodge.
##
## It holds exactly one pending intent. A queue would let a player bank a string
## of inputs and watch them play out without them, which is a different game; the
## most recent intent is the one the player currently wants, so a new one simply
## replaces the old.
##
## It knows nothing about the network — no peers, no RPCs, no routing. It reports
## what it executed through signals and lets the network components turn that into
## presentation. That is also why a buffered intent produces no presentation event
## until it actually runs: nothing has happened yet.

## Emitted the moment an attack actually begins, whether it ran immediately or
## waited in the buffer. Carries the sequence of the command that asked for it.
signal attack_executed(sequence: int, facing: float)
## Emitted the moment a dodge actually begins, immediate or buffered.
signal dodge_executed(sequence: int, direction: float)

enum Intent { NONE, ATTACK, DODGE }
## What happened to a submitted intent. REJECTED means it will never run;
## BUFFERED means it is waiting for a window; EXECUTED means it already ran.
enum SubmitResult { REJECTED, BUFFERED, EXECUTED }

## How long a pending intent survives. Without a definition nothing is ever
## buffered — intents still execute immediately when they can.
@export var definition: CombatInputBufferDefinition

var actor: PlayerActor
var action: CombatActionController
var combat: CombatComponent
var dodge: PlayerDodgeComponent
var _intent: Intent = Intent.NONE
var _sequence: int = -1
## Facing snapshotted when an attack intent arrived. A buffered swing keeps the
## direction the player asked for, even if the actor has since turned.
var _facing: float = 1.0
## Direction carried by a dodge command, already canonical when it arrives.
var _direction: float = 0.0
var _remaining: float = 0.0

func configure(
	p_actor: PlayerActor,
	p_action: CombatActionController,
	p_combat: CombatComponent,
	p_dodge: PlayerDodgeComponent
) -> void:
	actor = p_actor
	action = p_action
	combat = p_combat
	dodge = p_dodge
	if definition == null or not definition.validation_errors().is_empty():
		push_error("CombatInputBufferComponent requires a valid CombatInputBufferDefinition; intents will not be buffered")

func pending_intent() -> Intent:
	return _intent

func pending_sequence() -> int:
	return _sequence

func has_pending() -> bool:
	return _intent != Intent.NONE

## Seconds the pending intent has left. Zero when nothing is pending.
func remaining() -> float:
	return _remaining if _intent != Intent.NONE else 0.0

## Submits an attack intent. [param facing] is snapshotted here, at input time.
func submit_attack(sequence: int, facing: float) -> SubmitResult:
	return _submit(Intent.ATTACK, sequence, facing, 0.0)

## Submits a dodge intent. [param direction] is the canonical facing the command
## carried; it is stored as-is and never re-derived later.
func submit_dodge(sequence: int, direction: float) -> SubmitResult:
	return _submit(Intent.DODGE, sequence, 0.0, direction)

## Drops the pending intent without running it. The command's sequence stays
## consumed, so the discarded intent can never be replayed, and it produces no
## presentation event because it never happened.
func clear() -> void:
	_intent = Intent.NONE
	_sequence = -1
	_facing = 1.0
	_direction = 0.0
	_remaining = 0.0

## Ticked explicitly by the authoritative PlayerActor. Expiry is checked before
## execution, so an intent the player has effectively abandoned never fires on
## the frame its window happens to open.
func physics_tick(delta: float) -> void:
	if _intent == Intent.NONE or delta <= 0.0:
		return
	_remaining -= delta
	if _remaining <= 0.0:
		clear()
		return
	if not _is_eligible(_intent):
		return
	# Eligible means the moment has arrived. It gets exactly one attempt: a
	# gameplay refusal now (no stamina, no longer grounded) is a real refusal,
	# not a reason to keep retrying every frame until it happens to work.
	_execute(_intent, _sequence, _facing, _direction)
	clear()

func _submit(intent: Intent, sequence: int, facing: float, direction: float) -> SubmitResult:
	if actor == null or action == null or combat == null or dodge == null:
		return SubmitResult.REJECTED
	if _is_eligible(intent):
		# The action axis is free (or its window is open) right now, so there is
		# nothing to wait for. Whatever gameplay decides is final.
		if _execute(intent, sequence, facing, direction):
			clear()
			return SubmitResult.EXECUTED
		clear()
		return SubmitResult.REJECTED
	if not _can_buffer():
		return SubmitResult.REJECTED
	# Latest input wins: the previous intent is dropped, not queued behind this one.
	_intent = intent
	_sequence = sequence
	_facing = facing
	_direction = direction
	_remaining = definition.buffer_seconds
	return SubmitResult.BUFFERED

## Buffering answers "not yet", never "not allowed". Only a transient combat
## action can make an intent wait; an intent refused while the actor is free was
## refused on its merits, and time will not change that.
func _can_buffer() -> bool:
	if definition == null or not definition.validation_errors().is_empty():
		return false
	if actor == null or actor.is_death_handled():
		return false
	return action != null and not action.is_idle()

## Whether this intent could run this very moment: from a neutral actor, or
## through an authored window in the current attack's recovery.
func _is_eligible(intent: Intent) -> bool:
	if action == null or combat == null or actor == null or actor.is_death_handled():
		return false
	if action.is_idle():
		return true
	match intent:
		Intent.ATTACK:
			return combat.can_chain_attack_now()
		Intent.DODGE:
			return combat.can_dodge_cancel_now()
	return false

func _execute(intent: Intent, sequence: int, facing: float, direction: float) -> bool:
	match intent:
		Intent.ATTACK:
			return _execute_attack(sequence, facing)
		Intent.DODGE:
			return _execute_dodge(sequence, direction)
	return false

func _execute_attack(sequence: int, facing: float) -> bool:
	var started := combat.chain_attack(facing) if not action.is_idle() else combat.attack(facing)
	if not started:
		return false
	# The snapshot, not the actor's current facing: a buffered swing lands the way
	# the player asked for it, even if they have turned since.
	attack_executed.emit(sequence, facing)
	return true

func _execute_dodge(sequence: int, direction: float) -> bool:
	var started := dodge.try_begin_from_attack_cancel(direction) if not action.is_idle() else dodge.try_begin(direction)
	if not started:
		return false
	dodge_executed.emit(sequence, dodge.direction)
	return true
