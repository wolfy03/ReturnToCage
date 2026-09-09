class_name EnemyDefinition
extends ContentDefinition

@export var display_name: String = ""
@export var actor_scene: PackedScene
@export_range(1.0, 99999.0, 1.0) var max_health: float = 20.0
@export_range(0.0, 9999.0, 0.1) var attack_damage: float = 4.0
@export_range(0.0, 1000.0, 1.0) var move_speed: float = 55.0
@export_range(0.0, 2000.0, 1.0) var chase_range: float = 230.0
@export_range(0.0, 1000.0, 1.0) var attack_range: float = 42.0
@export var faction: StringName = &"hostile"
@export var loot_table_id: StringName

func validate_definition(registry: Node) -> PackedStringArray:
	var errors := super.validate_definition(registry)
	if display_name.strip_edges().is_empty() or max_health <= 0.0 or attack_damage < 0.0 \
		or move_speed < 0.0 or chase_range < 0.0 or attack_range < 0.0 or faction.is_empty():
		errors.append("%s: invalid enemy combat definition" % id)
	if actor_scene == null:
		errors.append("%s: missing enemy actor scene" % id)
	else:
		var candidate := actor_scene.instantiate()
		if not candidate is EnemyAgent:
			errors.append("%s: enemy actor scene root must inherit EnemyAgent" % id)
		candidate.free()
	if not loot_table_id.is_empty() and not registry.get_definition(loot_table_id) is LootTableDefinition:
		errors.append("%s: missing loot table %s" % [id, loot_table_id])
	return errors
