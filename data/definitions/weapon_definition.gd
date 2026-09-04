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
