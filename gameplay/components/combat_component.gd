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

# One in-flight attack. Captured when the wind-up starts so that equipment or
# stat changes during startup cannot redefine an attack that is already running.
var _pending_weapon: WeaponDefinition
var _pending_attack: AttackDefinition
var _pending_context: DamageContext
var _pending_facing: float = 1.0
var _phase_remaining: float = 0.0

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
	# A new attack may only start from an idle combat action. The action state is
	# the single lock-out; there is no separate weapon cooldown any more.
	if action == null or not action.is_idle():
		return false
	if hitbox == null or (owner_actor is PlayerActor and (owner_actor.movement.mode == MovementComponent.Mode.CLIMB or owner_actor.return_channel > 0.0)):
		return false
	var actor_state: PlayerState = owner_actor.player_state() if owner_actor is PlayerActor else GameSession.player
	var equipped_stack := actor_state.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND) if actor_state != null else null
	var weapon := ContentRegistry.get_definition(equipped_stack.item_id) as WeaponDefinition if equipped_stack != null else null
	if weapon == null or equipped_stack.durability == 0:
		return false
	var attack_definition := weapon.attack_definition
	if attack_definition == null or not attack_definition.validation_errors().is_empty():
		return false
	if not can_spend_stamina(weapon.stamina_cost):
		return false
	var strategy: AttackStrategy = strategies.get(weapon.attack_mode)
	if strategy == null:
		return false
	# Snapshot everything the commit will need, so the attack keeps the meaning it
	# had when the player pressed the button.
	var damage := weapon.base_damage + stats.value(&"attack_power")
	var context := DamageContext.new(damage, &"physical", owner_actor, &"player", Vector2(120.0 * signf(facing), -40.0))
	context.target_factions = weapon.target_factions.duplicate()
	context.hit_effects = weapon.hit_effects.duplicate()
	_pending_weapon = weapon
	_pending_attack = attack_definition
	_pending_context = context
	_pending_facing = facing
	if not action.begin_attack():
		_clear_pending()
		return false
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

func _clear_pending() -> void:
	_pending_weapon = null
	_pending_attack = null
	_pending_context = null
	_pending_facing = 1.0
	_phase_remaining = 0.0

## Runs the attack timeline. Only the authoritative simulation reaches this: a
## presentation actor has this component's processing disabled.
func _advance_attack(delta: float) -> void:
	if action == null or action.is_idle() or delta <= 0.0:
		return
	var remaining_delta := delta
	var steps := 0
	while not action.is_idle():
		if _phase_remaining - remaining_delta > PHASE_EPSILON:
			_phase_remaining -= remaining_delta
			return
		# The phase ended inside this tick; carry the surplus into the next one so
		# a long frame cannot stretch the attack.
		remaining_delta -= _phase_remaining
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
	if not strategy.execute(weapon, _pending_context, owner_actor, hitbox, _pending_facing):
		push_error("Attack strategy failed to execute for weapon %s" % weapon.id)
		abort_attack()
		return false
	spend_stamina(weapon.stamina_cost)
	_phase_remaining = attack_definition.active_seconds
	attacked.emit()
	return true
