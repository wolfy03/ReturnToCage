class_name WeaponDefinition
extends EquipmentDefinition

enum AttackMode { MELEE, PROJECTILE }

@export var attack_mode: AttackMode = AttackMode.MELEE
@export_range(0.0, 9999.0, 0.1) var base_damage: float = 5.0
@export_range(0.05, 10.0, 0.05) var attack_cooldown: float = 0.6
@export_range(1.0, 1000.0, 1.0) var attack_range: float = 54.0
@export_range(0.0, 100.0, 0.1) var stamina_cost: float = 8.0
@export var attack_scene: PackedScene
@export var hit_effects: Array[EffectDefinition] = []
@export var target_factions: Array[StringName] = [&"hostile"]

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if not is_finite(attack_range) or not is_finite(attack_cooldown) or attack_range <= 0.0 or attack_cooldown <= 0.0 or target_factions.is_empty():
		errors.append("%s: invalid weapon range, cooldown or target factions" % id)
	if attack_mode == AttackMode.PROJECTILE and attack_scene == null:
		errors.append("%s: PROJECTILE requires attack_scene" % id)
	if attack_mode not in AttackMode.values() or not is_finite(base_damage) or base_damage < 0.0 or not is_finite(stamina_cost) or stamina_cost < 0.0:
		errors.append("%s: invalid attack mode, damage or stamina cost" % id)
	if attack_mode == AttackMode.PROJECTILE and attack_scene != null:
		var instance: Node = attack_scene.instantiate()
		if not instance is ProjectileAttack:
			errors.append("%s: projectile attack_scene must have a ProjectileAttack root" % id)
		instance.free()
	for effect in hit_effects:
		if effect == null:
			errors.append("%s: null hit effect" % id)
		else:
			errors.append_array(effect.validate_definition(registry))
	return errors
