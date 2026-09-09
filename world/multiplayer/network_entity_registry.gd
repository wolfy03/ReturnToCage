class_name NetworkEntityRegistry
extends Node

const MAX_ENTITY_ID := 2147483647
var _next_entity_id: int = 1
var _entities: Dictionary[int, Node] = {}

func entity_count() -> int:
	return _entities.size()

func register_entity(node: Node) -> int:
	if node == null or _next_entity_id <= 0 or _next_entity_id > MAX_ENTITY_ID:
		return 0
	var entity_id := _next_entity_id
	_next_entity_id += 1
	_entities[entity_id] = node
	return entity_id

func register_remote_entity(entity_id: int, node: Node) -> bool:
	if entity_id <= 0 or node == null or _entities.has(entity_id):
		return false
	_entities[entity_id] = node
	return true

func unregister_entity(entity_id: int) -> void:
	_entities.erase(entity_id)

func get_entity(entity_id: int) -> Node:
	var entity: Node = _entities.get(entity_id)
	if entity != null and not is_instance_valid(entity):
		_entities.erase(entity_id)
		return null
	return entity

func has_entity(entity_id: int) -> bool:
	return get_entity(entity_id) != null
