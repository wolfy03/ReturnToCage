class_name AdventureSession
extends RefCounted

enum Result { ACTIVE, NORMAL_ESCAPE, RETURN_ITEM_ESCAPE, DEATH, ABORTED }

var rules: AdventureRulesSnapshot
var context: AdventureContext
var elapsed_seconds: float = 0.0
var starting_inventory: Array[Dictionary] = []
var player_adventures: Dictionary[int, PlayerAdventureState] = {}
var _compatibility_peer_id: int = 1
var unsecured_loot: InventoryModel:
	get:
		var state := get_player_adventure(_compatibility_peer_id)
		return state.unsecured_loot if state != null else null
var discovered_escape_points: Array[StringName] = []
var enemy_kills: Dictionary[StringName, int] = {}
var result: Result = Result.ACTIVE

func _init(p_context: AdventureContext = null, resolver: Callable = Callable()) -> void:
	context = p_context
	register_player(_compatibility_peer_id, resolver)
	if context != null:
		starting_inventory = context.prepared_inventory.duplicate(true)

func record_kill(enemy_id: StringName) -> void:
	enemy_kills[enemy_id] = enemy_kills.get(enemy_id, 0) + 1

func discover_escape(point_id: StringName) -> void:
	if not discovered_escape_points.has(point_id):
		discovered_escape_points.append(point_id)

func set_compatibility_peer_id(peer_id: int, resolver: Callable) -> void:
	_compatibility_peer_id = peer_id
	register_player(peer_id, resolver)

func register_player(peer_id: int, resolver: Callable) -> PlayerAdventureState:
	if peer_id <= 0:
		return null
	if not player_adventures.has(peer_id):
		player_adventures[peer_id] = PlayerAdventureState.new(peer_id, resolver)
	return player_adventures[peer_id]

func unregister_player(peer_id: int) -> void:
	player_adventures.erase(peer_id)

func get_player_adventure(peer_id: int) -> PlayerAdventureState:
	return player_adventures.get(peer_id)
