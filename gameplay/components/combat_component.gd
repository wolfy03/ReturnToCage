class_name CombatComponent
extends Node

## Emitted when an attack actually commits, i.e. on entering ATTACK_ACTIVE after
## the strategy executed. Never on the input frame that starts the wind-up.
signal attacked

## Defensive bound for the timeline loop. Every phase must be a positive
## duration, so a single tick can legitimately cross at most startup, active and
## recovery; anything beyond that means the durations are broken.
const MAX_PHASE_STEPS_PER_TICK := 4
## A phase this close to finished is treated as finished. Without it, splitting a
## phase across frames leaves a sub-nanosecond remainder that stalls the timeline.
const PHASE_EPSILON := 0.0001

@export var hitbox_path: NodePath
var hitbox: HitboxComponent
var owner_actor: CharacterBody2D
## Canonical stamina lives in PlayerRuntimeState.combat; this is only a reference.
var combat_runtime: CombatRuntimeState
## Combat action axis (scene-local). This component drives it; it never calls back.
var action: CombatActionController
var strategies: Dictionary[int, AttackStrategy] = {WeaponDefinition.AttackMode.MELEE: MeleeAttackStrategy.new(), WeaponDefinition.AttackMode.PROJECTILE: ProjectileAttackStrategy.new()}
var stats: StatBlock
var stamina_regen_multiplier: float = 1.0

# One in-flight attack step. WeaponDefinition and AttackDefinition are immutable
# authored Resources held by reference. Runtime values whose meaning must not
# change mid-step (damage, resolved knockback, factions and effects) are
# snapshotted in DamageContext when that step's wind-up starts, per step.
var _pending_weapon: WeaponDefinition
var _pending_attack: AttackDefinition
var _pending_context: DamageContext
var _pending_facing: float = 1.0
var _phase_remaining: float = 0.0
## Which step of the current combo is running. Reset to zero whenever the combo
## ends for any reason, so an independent attack always starts from the first.
var _combo_index: int = 0
## Time spent inside the current step, used only to answer whether an authored
## follow-up window is open. Reset to zero on every new step, including a chain.
var _attack_elapsed: float = 0.0

func configure(
	actor: CharacterBody2D,
	p_stats: StatBlock,
	p_combat_runtime: CombatRuntimeState = null,
	p_action: CombatActionController = null
) -> void:
	owner_actor = actor
	stats = p_stats
	combat_runtime = p_combat_runtime
	action = p_action
	if combat_runtime == null:
		push_error("CombatComponent requires a CombatRuntimeState; attacks will be rejected")
	if action == null:
		push_error("CombatComponent requires a CombatActionController; attacks will be rejected")
	hitbox = get_node_or_null(hitbox_path) as HitboxComponent
	if hitbox == null:
		push_error("CombatComponent requires a HitboxComponent")

func _process(delta: float) -> void:
	_advance_attack(delta)
	if stats != null and combat_runtime != null:
		combat_runtime.set_max_stamina(stats.value(&"max_stamina"))
		combat_runtime.regenerate(stats.value(&"stamina_regen") * stamina_regen_multiplier * delta)

func current_stamina() -> float:
	return combat_runtime.stamina if combat_runtime != null else 0.0

func max_stamina() -> float:
	return combat_runtime.max_stamina if combat_runtime != null else 0.0

func can_spend_stamina(amount: float) -> bool:
	return combat_runtime != null and combat_runtime.can_spend(amount)

func spend_stamina(amount: float) -> bool:
	return combat_runtime != null and combat_runtime.spend(amount)

## Time left in the current attack phase. Zero while idle.
func phase_remaining() -> float:
	return _phase_remaining

## Starts an attack wind-up. Returning true means the request was valid and
## ATTACK_STARTUP began — the hitbox is NOT armed and no stamina is spent yet.
## Both happen when the timeline reaches ATTACK_ACTIVE.
func attack(facing: float) -> bool:
	# A new combo may only start from an idle combat action. The action state is
	# the single lock-out; there is no separate weapon cooldown any more, and
	# continuing an existing combo goes through chain_attack() instead.
	if action == null or not action.is_idle():
		return false
	if hitbox == null or (owner_actor is PlayerActor and (owner_actor.movement.mode == MovementComponent.Mode.CLIMB or owner_actor.return_channel > 0.0)):
		return false
	var weapon := equipped_weapon()
	if weapon == null:
		return false
	return _begin_step(weapon, 0, facing, false)

## Continues the combo into its next step, directly from ATTACK_RECOVERY. The
## authored chain window is the only thing that permits this, so a caller must
## have asked [method can_chain_attack_now] first — this re-checks it anyway.
func chain_attack(facing: float) -> bool:
	if not can_chain_attack_now():
		return false
	# Re-resolve rather than trusting the snapshot: a weapon swapped or broken
	# mid-combo ends the combo instead of continuing someone else's swing.
	var weapon := equipped_weapon()
	if weapon == null or weapon != _pending_weapon:
		return false
	return _begin_step(weapon, _combo_index + 1, facing, true)

## The weapon currently in the main hand, or null when there is nothing usable
## there. Broken equipment (zero durability) counts as nothing.
func equipped_weapon() -> WeaponDefinition:
	var actor_state: PlayerState = owner_actor.player_state() if owner_actor is PlayerActor else GameSession.player
	var equipped_stack := actor_state.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND) if actor_state != null else null
	if equipped_stack == null or equipped_stack.durability == 0:
		return null
	return ContentRegistry.get_definition(equipped_stack.item_id) as WeaponDefinition

## Index of the step currently running, or the one that just ran. Zero while idle.
func combo_index() -> int:
	return _combo_index

## Time spent inside the current step. Zero while idle.
func attack_elapsed() -> float:
	return _attack_elapsed

## True only while the current step's authored chain window is open and there is
## another step to chain into.
func can_chain_attack_now() -> bool:
	if action == null or action.current_state() != CombatActionController.State.ATTACK_RECOVERY:
		return false
	if _pending_weapon == null or _pending_attack == null or _pending_weapon.attack_combo == null:
		return false
	if not _pending_weapon.attack_combo.has_step(_combo_index + 1):
		return false
	return _pending_attack.can_chain_at(_attack_elapsed)

## True only while the current step's authored dodge-cancel window is open.
func can_dodge_cancel_now() -> bool:
	if action == null or action.current_state() != CombatActionController.State.ATTACK_RECOVERY:
		return false
	if _pending_attack == null:
		return false
	return _pending_attack.can_dodge_cancel_at(_attack_elapsed)

## Starts one combo step. [param chained] selects the direct
## ATTACK_RECOVERY -> ATTACK_STARTUP transition, which never passes through IDLE
## so no observer can see a combo momentarily end.
func _begin_step(weapon: WeaponDefinition, index: int, facing: float, chained: bool) -> bool:
	var combo := weapon.attack_combo
	if combo == null or not combo.validation_errors().is_empty():
		return false
	var attack_definition := combo.step(index)
	if attack_definition == null:
		return false
	if not can_spend_stamina(weapon.stamina_cost):
		return false
	var strategy: AttackStrategy = strategies.get(weapon.attack_mode)
	if strategy == null:
		return false
	# Snapshot everything the commit will need, so the step keeps the meaning it
	# had when the player pressed the button. Every step builds its own context:
	# knockback, effects and facing all belong to the swing that is starting, not
	# to the one before it.
	var damage := weapon.base_damage + stats.value(&"attack_power")
	var direction := -1.0 if facing < 0.0 else 1.0
	var authored_knockback := attack_definition.knockback
	var resolved_knockback := Vector2(authored_knockback.x * direction, authored_knockback.y)
	var context := DamageContext.new(damage, &"physical", owner_actor, &"player", resolved_knockback)
	context.target_factions = weapon.target_factions.duplicate()
	context.hit_effects = weapon.hit_effects.duplicate()
	var entered := action.chain_attack() if chained else action.begin_attack()
	if not entered:
		return false
	# The previous step is over the moment the next one is entered; its hitbox is
	# already down, but dropping it again keeps that true without depending on it.
	if chained and hitbox != null:
		hitbox.deactivate()
	_pending_weapon = weapon
	_pending_attack = attack_definition
	_pending_context = context
	_pending_facing = facing
	_combo_index = index
	_attack_elapsed = 0.0
	_phase_remaining = attack_definition.startup_seconds
	return true

## Cancels any in-flight attack and returns the action axis to IDLE, taking the
## hitbox down with it. Used by lifecycle cleanup (death, teardown); this stage
## has no gameplay cancel window. Safe to call repeatedly and from any phase.
func abort_attack() -> void:
	if hitbox != null:
		hitbox.deactivate()
	if action != null:
		action.reset()
	_clear_pending()

## Clears an in-flight attack before a direct ATTACK_* -> HURT transition.
## Unlike abort_attack(), this deliberately leaves the action state untouched so
## observers never see a transient ATTACK_* -> IDLE -> HURT sequence.
func interrupt_attack_for_hurt() -> void:
	if hitbox != null:
		hitbox.deactivate()
	_clear_pending()

## Clears an in-flight attack before a direct ATTACK_RECOVERY -> DODGE cancel.
## Like the hurt interrupt it leaves the action state alone, so observers see one
## clean transition into DODGE rather than a detour through IDLE. The dodge's own
## component owns the transition and the stamina it costs.
func interrupt_attack_for_dodge() -> void:
	if hitbox != null:
		hitbox.deactivate()
	_clear_pending()

## Ends the combo as well as the step. Called wherever an attack stops for good,
## so the next independent attack starts from the first step again.
func _clear_pending() -> void:
	_pending_weapon = null
	_pending_attack = null
	_pending_context = null
	_pending_facing = 1.0
	_phase_remaining = 0.0
	_combo_index = 0
	_attack_elapsed = 0.0

## Runs the attack timeline. Only the authoritative simulation reaches this: a
## presentation actor has this component's processing disabled.
func _advance_attack(delta: float) -> void:
	if action == null or not action.is_attacking() or delta <= 0.0:
		return
	var remaining_delta := delta
	var steps := 0
	while not action.is_idle():
		if _phase_remaining - remaining_delta > PHASE_EPSILON:
			_phase_remaining -= remaining_delta
			_attack_elapsed += remaining_delta
			return
		# The phase ended inside this tick; carry the surplus into the next one so
		# a long frame cannot stretch the attack. Elapsed tracks the delta actually
		# consumed, so a long frame reports the same position in the step that a
		# run of short frames would.
		remaining_delta -= _phase_remaining
		_attack_elapsed += _phase_remaining
		_phase_remaining = 0.0
		steps += 1
		if steps > MAX_PHASE_STEPS_PER_TICK:
			push_error("Attack timeline exceeded %d phase steps in one tick; aborting" % MAX_PHASE_STEPS_PER_TICK)
			abort_attack()
			return
		if not _enter_next_phase():
			return

## Advances one phase. Returns false when the timeline stopped (finished or
## aborted) and the caller must not keep looping.
func _enter_next_phase() -> bool:
	match action.current_state():
		CombatActionController.State.ATTACK_STARTUP:
			return _commit_attack()
		CombatActionController.State.ATTACK_ACTIVE:
			# Leaving ACTIVE ends the live window; the hitbox never bleeds into
			# recovery because this component, not the hitbox, times the phase.
			if hitbox != null:
				hitbox.deactivate()
			if not action.enter_attack_recovery():
				abort_attack()
				return false
			_phase_remaining = _pending_attack.recovery_seconds
			return true
		CombatActionController.State.ATTACK_RECOVERY:
			action.finish_attack()
			_clear_pending()
			return false
	return false

## The single commit point of an attack: entering ATTACK_ACTIVE makes the hitbox
## live (or spawns the projectile), exactly once, and only then is stamina spent.
## The hitbox stays live until this component leaves the ACTIVE phase.
func _commit_attack() -> bool:
	var weapon := _pending_weapon
	var attack_definition := _pending_attack
	if weapon == null or attack_definition == null or _pending_context == null:
		abort_attack()
		return false
	# Re-check affordability: the wind-up only reserved intent, not stamina.
	if not can_spend_stamina(weapon.stamina_cost):
		abort_attack()
		return false
	var strategy: AttackStrategy = strategies.get(weapon.attack_mode)
	if strategy == null:
		abort_attack()
		return false
	if not action.enter_attack_active():
		abort_attack()
		return false
	if not strategy.execute(weapon, attack_definition, _pending_context, owner_actor, hitbox, _pending_facing):
		push_error("Attack strategy failed to execute for weapon %s" % weapon.id)
		abort_attack()
		return false
	spend_stamina(weapon.stamina_cost)
	_phase_remaining = attack_definition.active_seconds
	attacked.emit()
	return true
