class_name CombatComponent
extends Node

signal attacked

@export var hitbox_path: NodePath
var hitbox: HitboxComponent
var owner_actor: CharacterBody2D
var cooldown_remaining: float = 0.0
var stamina: float = 100.0
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
	if cooldown_remaining > 0.0 or hitbox == null:
		return false
	var equipped_stack := GameSession.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	var weapon := ContentRegistry.get_definition(equipped_stack.item_id) as WeaponDefinition if equipped_stack != null else null
	if weapon == null or stamina < weapon.stamina_cost:
		return false
	stamina -= weapon.stamina_cost
	cooldown_remaining = weapon.attack_cooldown
	hitbox.position.x = absf(hitbox.position.x) * signf(facing if facing != 0.0 else 1.0)
	var damage := weapon.base_damage + stats.value(&"attack_power")
	var context := DamageContext.new(damage, &"physical", owner_actor, &"player", Vector2(120.0 * signf(facing), -40.0))
	hitbox.arm(context)
	attacked.emit()
	return true
