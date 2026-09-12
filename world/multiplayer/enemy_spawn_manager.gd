class_name EnemySpawnManager
extends Node

var _registry: NetworkEntityRegistry
var _loot_manager: LootSpawnManager
var _enemies: Dictionary[int, EnemyAgent] = {}
var world_id: StringName = &""
var authoritative_runtime: bool = false

func configure_world(p_world_id: StringName, p_authoritative_runtime: bool = true) -> void:
	world_id = p_world_id
	authoritative_runtime = p_authoritative_runtime

func _ready() -> void:
	_registry = get_parent().get_node_or_null("NetworkEntityRegistry") as NetworkEntityRegistry
	_loot_manager = get_parent().get_node_or_null("LootSpawnManager") as LootSpawnManager
	if _registry == null or _loot_manager == null:
		push_error("EnemySpawnManager requires entity and loot managers")
	if world_id.is_empty():
		world_id = GameSession.get_peer_world_id(GameSession.get_local_peer_id())
	if _registry != null:
		_registry.configure_world(world_id)
	NetworkManager.enemy_spawn_received.connect(_on_enemy_spawn_received)
	NetworkManager.enemy_despawn_received.connect(_on_enemy_despawn_received)
	if authoritative_runtime and NetworkManager.is_server():
		NetworkManager.peer_world_ready.connect(_on_peer_world_ready)

func _exit_tree() -> void:
	if NetworkManager.enemy_spawn_received.is_connected(_on_enemy_spawn_received):
		NetworkManager.enemy_spawn_received.disconnect(_on_enemy_spawn_received)
	if NetworkManager.enemy_despawn_received.is_connected(_on_enemy_despawn_received):
		NetworkManager.enemy_despawn_received.disconnect(_on_enemy_despawn_received)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)

func spawn_enemy(enemy_id: StringName, position: Vector2, report_warning: bool = true) -> int:
	if not NetworkManager.is_authoritative_simulation() or _registry == null or not position.is_finite():
		return 0
	var definition := ContentRegistry.get_definition(enemy_id) as EnemyDefinition
	if definition == null:
		if report_warning:
			push_warning("Unknown enemy id: %s" % enemy_id)
		return 0
	return _spawn_definition(definition, position, report_warning)

func _spawn_definition(definition: EnemyDefinition, position: Vector2, report_warning: bool = true) -> int:
	if not NetworkManager.is_authoritative_simulation() or _registry == null or definition == null or not position.is_finite():
		return 0
	var actor := _instantiate_enemy_actor(definition, report_warning)
	if actor == null:
		return 0
	# Entity allocation happens only after content and scene-root validation, so a
	# malformed definition cannot consume or contaminate the registry.
	var entity_id := _registry.register_entity(actor)
	if entity_id <= 0:
		actor.free()
		return 0
	actor.name = "Enemy_%d" % entity_id
	actor.setup_enemy(definition, entity_id, true, world_id)
	actor.global_position = position
	get_parent().add_child(actor, true)
	actor.finished.connect(_on_enemy_finished)
	_enemies[entity_id] = actor
	print("[ENEMY] Spawn %d (%s)" % [entity_id, definition.id])
	if NetworkManager.is_server():
		NetworkManager.broadcast_enemy_spawn(world_id, actor.network.make_snapshot().to_payload())
	return entity_id

func _instantiate_enemy_actor(definition: EnemyDefinition, report_warning: bool = true) -> EnemyAgent:
	if definition == null or definition.actor_scene == null:
		if report_warning:
			push_warning("Enemy definition has no actor scene: %s" % (definition.id if definition != null else &""))
		return null
	var instance := definition.actor_scene.instantiate()
	var actor := instance as EnemyAgent
	if actor == null:
		if report_warning:
			push_warning("Enemy actor scene root must inherit EnemyAgent: %s" % definition.id)
		if instance != null:
			instance.free()
		return null
	return actor

func get_enemy(entity_id: int) -> EnemyAgent:
	var enemy: EnemyAgent = _enemies.get(entity_id)
	return enemy if is_instance_valid(enemy) else null

func _on_enemy_finished(actor: EnemyAgent) -> void:
	if actor == null or _enemies.get(actor.network_entity_id) != actor:
		return
	GameSession.record_enemy_kill_for_world(world_id, actor.definition.id, actor.last_damage_player_id)
	var table := ContentRegistry.get_definition(actor.definition.loot_table_id) as LootTableDefinition
	for stack in LootRollService.roll(table, Callable(ContentRegistry, "get_item"), GameSession.current_difficulty_for_world(world_id).loot_multiplier):
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
		NetworkManager.broadcast_enemy_despawn(world_id, entity_id)

func _on_peer_world_ready(peer_id: int) -> void:
	if not NetworkManager.can_send_to_peer(peer_id) or GameSession.get_peer_world_id(peer_id) != world_id:
		return
	var payloads: Array[Dictionary] = []
	for actor in _enemies.values():
		if is_instance_valid(actor):
			payloads.append((actor as EnemyAgent).network.make_snapshot().to_payload())
	NetworkManager.send_enemy_roster(peer_id, world_id, payloads)

func _on_enemy_spawn_received(p_world_id: StringName, payload: Dictionary) -> void:
	if authoritative_runtime or p_world_id != world_id or _registry == null:
		return
	var snapshot := EnemyRuntimeSnapshot.from_payload(payload)
	if not snapshot.error_message.is_empty() or _enemies.has(snapshot.entity_id):
		return
	var definition := ContentRegistry.get_definition(snapshot.enemy_id) as EnemyDefinition
	var actor := _instantiate_enemy_actor(definition)
	if actor == null:
		return
	if not _registry.register_remote_entity(snapshot.entity_id, actor):
		actor.free()
		return
	actor.name = "Enemy_%d" % snapshot.entity_id
	actor.setup_enemy(definition, snapshot.entity_id, false, world_id)
	actor.global_position = snapshot.position
	get_parent().add_child(actor, true)
	_enemies[snapshot.entity_id] = actor
	actor.network.apply_snapshot(snapshot)

func _on_enemy_despawn_received(p_world_id: StringName, entity_id: int) -> void:
	if authoritative_runtime or p_world_id != world_id or entity_id <= 0:
		return
	var actor: EnemyAgent = _enemies.get(entity_id)
	_enemies.erase(entity_id)
	if _registry != null:
		_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.queue_free()
