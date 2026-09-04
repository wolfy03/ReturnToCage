class_name EnemyDefinition
extends ContentDefinition

@export var display_name: String = ""
@export_range(1.0, 99999.0, 1.0) var max_health: float = 20.0
@export_range(0.0, 9999.0, 0.1) var attack_damage: float = 4.0
@export_range(0.0, 1000.0, 1.0) var move_speed: float = 55.0
@export_range(0.0, 2000.0, 1.0) var chase_range: float = 230.0
@export_range(0.0, 1000.0, 1.0) var attack_range: float = 42.0
@export var faction: StringName = &"hostile"
@export var loot_table: LootTableDefinition
