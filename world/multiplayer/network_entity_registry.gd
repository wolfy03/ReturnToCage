class_name NetworkEntityRegistry
extends Node

const MAX_ENTITY_ID := 2147483647
const DEFAULT_SCOPE: StringName = &"__default__"
var world_id: StringName = &""
var _next_entity_ids: Dictionary[StringName, int] = {}
var _entities_by_world: Dictionary[StringName, Dictionary] = {}

func configure_world(p_world_id: StringName) -> void:
	if not p_world_id.is_empty():
		world_id = p_world_id

func _scope(p_world_id: StringName = &"") -> StringName:
	var scope := p_world_id if not p_world_id.is_empty() else world_id
	return scope if not scope.is_empty() else DEFAULT_SCOPE

func _entities(p_world_id: StringName = &"") -> Dictionary:
	var scope := _scope(p_world_id)
	if not _entities_by_world.has(scope):
		_entities_by_world[scope] = {}
	return _entities_by_world[scope]

func entity_count() -> int:
	return _entities().size()

func entity_count_in_world(p_world_id: StringName) -> int:
	return _entities(p_world_id).size()

func register_entity(node: Node) -> int:
	return register_entity_in_world(world_id, node)

func register_entity_in_world(p_world_id: StringName, node: Node) -> int:
	var scope := _scope(p_world_id)
	var next_id: int = _next_entity_ids.get(scope, 1)
	if node == null or next_id <= 0 or next_id > MAX_ENTITY_ID:
		return 0
	var entity_id := next_id
	_next_entity_ids[scope] = next_id + 1
	_entities(scope)[entity_id] = node
	return entity_id

func register_remote_entity(entity_id: int, node: Node) -> bool:
	return register_remote_entity_in_world(world_id, entity_id, node)

func register_remote_entity_in_world(p_world_id: StringName, entity_id: int, node: Node) -> bool:
	var scope := _scope(p_world_id)
	var entries := _entities(scope)
	if entity_id <= 0 or node == null or entries.has(entity_id):
		return false
	entries[entity_id] = node
	return true

func unregister_entity(entity_id: int) -> void:
	unregister_entity_in_world(world_id, entity_id)

func unregister_entity_in_world(p_world_id: StringName, entity_id: int) -> void:
	_entities(_scope(p_world_id)).erase(entity_id)

func get_entity(entity_id: int) -> Node:
	return get_entity_in_world(world_id, entity_id)

func get_entity_in_world(p_world_id: StringName, entity_id: int) -> Node:
	var entries := _entities(_scope(p_world_id))
	var entity: Node = entries.get(entity_id)
	if entity != null and not is_instance_valid(entity):
		entries.erase(entity_id)
		return null
	return entity

func has_entity(entity_id: int) -> bool:
	return get_entity(entity_id) != null

func has_entity_in_world(p_world_id: StringName, entity_id: int) -> bool:
	return get_entity_in_world(p_world_id, entity_id) != null
