class_name CombatComponent
extends Node

signal attacked

@export var hitbox_path: NodePath
var hitbox: HitboxComponent
var owner_actor: CharacterBody2D
var cooldown_remaining: float = 0.0
## Canonical stamina lives in PlayerRuntimeState.combat; this is only a reference.
var combat_runtime: CombatRuntimeState
## Combat action axis (scene-local). This component drives it; it never calls back.
var action: CombatActionController
var strategies: Dictionary[int, AttackStrategy] = {WeaponDefinition.AttackMode.MELEE: MeleeAttackStrategy.new(), WeaponDefinition.AttackMode.PROJECTILE: ProjectileAttackStrategy.new()}
var stats: StatBlock
var stamina_regen_multiplier: float = 1.0

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
	var had_cooldown := cooldown_remaining > 0.0
	cooldown_remaining = maxf(0.0, cooldown_remaining - delta)
	# The weapon cooldown is the recovery window until AttackDefinition supplies a
	# real one; no second timer is introduced for the action state.
	if had_cooldown and cooldown_remaining <= 0.0 and action != null \
			and action.current_state() == CombatActionController.State.ATTACK_RECOVERY:
		action.finish_attack()
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

func attack(facing: float) -> bool:
	# An attack may only start from an idle combat action. The weapon cooldown
	# still applies independently: it is the attack-rate rule, while the action
	# state is the timeline/cancel axis that later stages build on.
	if action == null or not action.is_idle():
		return false
	if cooldown_remaining > 0.0 or hitbox == null or (owner_actor is PlayerActor and (owner_actor.movement.mode == MovementComponent.Mode.CLIMB or owner_actor.return_channel > 0.0)):
		return false
	var actor_state: PlayerState = owner_actor.player_state() if owner_actor is PlayerActor else GameSession.player
	var equipped_stack := actor_state.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND) if actor_state != null else null
	var weapon := ContentRegistry.get_definition(equipped_stack.item_id) as WeaponDefinition if equipped_stack != null else null
	if weapon == null or equipped_stack.durability == 0 or not can_spend_stamina(weapon.stamina_cost):
		return false
	var damage := weapon.base_damage + stats.value(&"attack_power")
	var context := DamageContext.new(damage, &"physical", owner_actor, &"player", Vector2(120.0 * signf(facing), -40.0))
	context.target_factions = weapon.target_factions.duplicate()
	context.hit_effects = weapon.hit_effects.duplicate()
	var strategy: AttackStrategy = strategies.get(weapon.attack_mode)
	if strategy == null or not strategy.execute(weapon, context, owner_actor, hitbox, facing):
		return false
	spend_stamina(weapon.stamina_cost)
	cooldown_remaining = weapon.attack_cooldown
	# Only a committed attack moves the action state; every rejection above leaves
	# it untouched at IDLE. Startup/active are skipped on purpose while the attack
	# still resolves instantly — see enter_recovery_from_immediate_attack().
	action.enter_recovery_from_immediate_attack()
	attacked.emit()
	return true
