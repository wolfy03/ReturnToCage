class_name CombatComponent
extends Node

signal attacked

@export var hitbox_path: NodePath
var hitbox: HitboxComponent
var owner_actor: CharacterBody2D
var cooldown_remaining: float = 0.0
var stamina: float = 100.0
var strategies: Dictionary[int, AttackStrategy] = {WeaponDefinition.AttackMode.MELEE: MeleeAttackStrategy.new(), WeaponDefinition.AttackMode.PROJECTILE: ProjectileAttackStrategy.new()}
var stats: StatBlock
var stamina_regen_multiplier: float = 1.0

func configure(actor: CharacterBody2D, p_stats: StatBlock) -> void:
	owner_actor = actor
	stats = p_stats
	hitbox = get_node_or_null(hitbox_path) as HitboxComponent
	if hitbox == null:
		push_error("CombatComponent requires a HitboxComponent")

func _process(delta: float) -> void:
	cooldown_remaining = maxf(0.0, cooldown_remaining - delta)
	if stats != null:
		stamina = minf(stats.value(&"max_stamina"), stamina + stats.value(&"stamina_regen") * stamina_regen_multiplier * delta)

func attack(facing: float) -> bool:
	if cooldown_remaining > 0.0 or hitbox == null or (owner_actor is PlayerActor and (owner_actor.movement.mode == MovementComponent.Mode.CLIMB or owner_actor.return_channel > 0.0)):
		return false
	var actor_state: PlayerState = owner_actor.player_state() if owner_actor is PlayerActor else GameSession.player
	var equipped_stack := actor_state.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND) if actor_state != null else null
	var weapon := ContentRegistry.get_definition(equipped_stack.item_id) as WeaponDefinition if equipped_stack != null else null
	if weapon == null or equipped_stack.durability == 0 or stamina < weapon.stamina_cost:
		return false
	var damage := weapon.base_damage + stats.value(&"attack_power")
	var context := DamageContext.new(damage, &"physical", owner_actor, &"player", Vector2(120.0 * signf(facing), -40.0))
	context.target_factions = weapon.target_factions.duplicate()
	context.hit_effects = weapon.hit_effects.duplicate()
	var strategy: AttackStrategy = strategies.get(weapon.attack_mode)
	if strategy == null or not strategy.execute(weapon, context, owner_actor, hitbox, facing):
		return false
	stamina -= weapon.stamina_cost
	cooldown_remaining = weapon.attack_cooldown
	attacked.emit()
	return true
