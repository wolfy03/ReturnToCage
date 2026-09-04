class_name AdventureSession
extends RefCounted

enum Result { ACTIVE, NORMAL_ESCAPE, RETURN_ITEM_ESCAPE, DEATH, ABORTED }

var context: AdventureContext
var elapsed_seconds: float = 0.0
var starting_inventory: Array[Dictionary] = []
var unsecured_loot: InventoryModel
var discovered_escape_points: Array[StringName] = []
var enemy_kills: Dictionary[StringName, int] = {}
var result: Result = Result.ACTIVE

func _init(p_context: AdventureContext = null, resolver: Callable = Callable()) -> void:
	context = p_context
	unsecured_loot = InventoryModel.new(24, resolver)
	if context != null:
		starting_inventory = context.prepared_inventory.duplicate(true)

func record_kill(enemy_id: StringName) -> void:
	enemy_kills[enemy_id] = enemy_kills.get(enemy_id, 0) + 1

func discover_escape(point_id: StringName) -> void:
	if not discovered_escape_points.has(point_id):
		discovered_escape_points.append(point_id)
