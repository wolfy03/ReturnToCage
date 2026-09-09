class_name EnemySpawnManager
extends Node

const ENEMY_SCENE := preload("res://gameplay/actors/enemies/sewer_beetle.tscn")

var _registry: NetworkEntityRegistry
var _loot_manager: LootSpawnManager
var _enemies: Dictionary[int, EnemyAgent] = {}

func _ready() -> void:
	_registry = get_parent().get_node_or_null("NetworkEntityRegistry") as NetworkEntityRegistry
	_loot_manager = get_parent().get_node_or_null("LootSpawnManager") as LootSpawnManager
	if _registry == null or _loot_manager == null:
		push_error("EnemySpawnManager requires entity and loot managers")
	if NetworkManager.is_server():
		NetworkManager.peer_world_ready.connect(_on_peer_world_ready)

func _exit_tree() -> void:
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)

func spawn_enemy(enemy_id: StringName, position: Vector2) -> int:
	if not NetworkManager.is_authoritative_simulation() or _registry == null or not position.is_finite():
		return 0
	var definition := ContentRegistry.get_definition(enemy_id) as EnemyDefinition
	if definition == null:
		push_warning("Unknown enemy id: %s" % enemy_id)
		return 0
	var actor := ENEMY_SCENE.instantiate() as EnemyAgent
	var entity_id := _registry.register_entity(actor)
	if entity_id <= 0:
		actor.free()
		return 0
	actor.name = "Enemy_%d" % entity_id
	actor.setup_enemy(definition, entity_id, true)
	actor.global_position = position
	get_parent().add_child(actor, true)
	actor.finished.connect(_on_enemy_finished)
	_enemies[entity_id] = actor
	print("[ENEMY] Spawn %d (%s)" % [entity_id, enemy_id])
	if NetworkManager.is_server():
		for peer_id in NetworkManager.ready_remote_peer_ids():
			if NetworkManager.can_send_to_peer(peer_id):
				_spawn_enemy.rpc_id(peer_id, actor.network.make_snapshot().to_payload())
	return entity_id

func get_enemy(entity_id: int) -> EnemyAgent:
	var enemy: EnemyAgent = _enemies.get(entity_id)
	return enemy if is_instance_valid(enemy) else null

func _on_enemy_finished(actor: EnemyAgent) -> void:
	if actor == null or _enemies.get(actor.network_entity_id) != actor:
		return
	GameSession.record_enemy_kill(actor.definition.id)
	var table := ContentRegistry.get_definition(actor.definition.loot_table_id) as LootTableDefinition
	for stack in LootRollService.roll(table, Callable(ContentRegistry, "get_item"), GameSession.current_difficulty().loot_multiplier):
		_loot_manager.spawn_loot(stack, actor.global_position)
	print("[ENEMY] Death %d" % actor.network_entity_id)
	_despawn_authoritative(actor.network_entity_id)

func _despawn_authoritative(entity_id: int) -> void:
	var actor: EnemyAgent = _enemies.get(entity_id)
	_enemies.erase(entity_id)
	_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.queue_free()
	if NetworkManager.is_server():
		for peer_id in NetworkManager.ready_remote_peer_ids():
			if NetworkManager.can_send_to_peer(peer_id):
				_despawn_enemy.rpc_id(peer_id, entity_id)

func _on_peer_world_ready(peer_id: int) -> void:
	if not NetworkManager.can_send_to_peer(peer_id):
		return
	for actor in _enemies.values():
		if is_instance_valid(actor):
			_spawn_enemy.rpc_id(peer_id, (actor as EnemyAgent).network.make_snapshot().to_payload())

@rpc("authority", "call_remote", "reliable")
func _spawn_enemy(payload: Dictionary) -> void:
	if NetworkManager.is_server() or _registry == null:
		return
	var snapshot := EnemyRuntimeSnapshot.from_payload(payload)
	if not snapshot.error_message.is_empty() or _enemies.has(snapshot.entity_id):
		return
	var definition := ContentRegistry.get_definition(snapshot.enemy_id) as EnemyDefinition
	var actor := ENEMY_SCENE.instantiate() as EnemyAgent
	if not _registry.register_remote_entity(snapshot.entity_id, actor):
		actor.free()
		return
	actor.name = "Enemy_%d" % snapshot.entity_id
	actor.setup_enemy(definition, snapshot.entity_id, false)
	actor.global_position = snapshot.position
	get_parent().add_child(actor, true)
	_enemies[snapshot.entity_id] = actor
	actor.network.apply_snapshot(snapshot)

@rpc("authority", "call_remote", "reliable")
func _despawn_enemy(entity_id: int) -> void:
	if entity_id <= 0:
		return
	var actor: EnemyAgent = _enemies.get(entity_id)
	_enemies.erase(entity_id)
	if _registry != null:
		_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.queue_free()
