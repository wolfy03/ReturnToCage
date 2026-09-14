class_name WeaponDefinition
extends EquipmentDefinition

enum AttackMode { MELEE, PROJECTILE }

@export var attack_mode: AttackMode = AttackMode.MELEE
@export_range(0.0, 9999.0, 0.1) var base_damage: float = 5.0
## Every attack step this weapon can perform, in order. A weapon that swings
## once authors a one-step combo — there is no separate single-attack field to
## keep in sync, so the combo is the only source of attack timing and geometry.
@export var attack_combo: AttackComboDefinition
@export_range(0.0, 100.0, 0.1) var stamina_cost: float = 8.0
@export var attack_scene: PackedScene
@export var hit_effects: Array[EffectDefinition] = []
@export var target_factions: Array[StringName] = [&"hostile"]

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if target_factions.is_empty():
		errors.append("%s: weapon target factions cannot be empty" % id)
	if attack_combo == null:
		errors.append("%s: missing attack_combo" % id)
	else:
		errors.append_array(attack_combo.validation_errors(id))
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
