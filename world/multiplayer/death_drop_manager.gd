class_name DeathDropManager
extends Node

var world_id: StringName
var region_id: StringName
var authoritative: bool = false
var registry: NetworkEntityRegistry
var _targets: Dictionary[String, InteractionTarget] = {}
var _entity_ids: Dictionary[String, int] = {}

func configure(p_region_id: StringName, p_authoritative: bool) -> void:
	region_id = p_region_id
	world_id = PlayerWorldState.adventure_world_id(region_id)
	authoritative = p_authoritative

func _ready() -> void:
	registry = get_parent().get_node_or_null("NetworkEntityRegistry") as NetworkEntityRegistry
	NetworkManager.death_drop_state_received.connect(_on_state)
	if authoritative:
		GameSession.player_died.connect(_on_death)
		NetworkManager.peer_world_ready.connect(_on_ready_peer)
		for record in GameSession.adventure.death_drops:
			if record.region_id == region_id and not record.recovered:
				_spawn_record(record)

func _exit_tree() -> void:
	if NetworkManager.death_drop_state_received.is_connected(_on_state):
		NetworkManager.death_drop_state_received.disconnect(_on_state)
	if GameSession.player_died.is_connected(_on_death):
		GameSession.player_died.disconnect(_on_death)
	if NetworkManager.peer_world_ready.is_connected(_on_ready_peer):
		NetworkManager.peer_world_ready.disconnect(_on_ready_peer)

func target(drop_id: String) -> InteractionTarget:
	var found: InteractionTarget = _targets.get(drop_id)
	return found if is_instance_valid(found) else null

func _spawn_record(record: DeathDropRecord) -> void:
	if target(record.id) != null:
		return
	var created := _create_target(record.id, record.position)
	_entity_ids[record.id] = registry.register_entity_in_world(world_id, created)
	NetworkManager.broadcast_death_drop_state(world_id, _payload(record.id, true))

func _create_target(drop_id: String, position: Vector2) -> InteractionTarget:
	var created := WorldHelpers.add_interaction(get_parent(), StringName(drop_id), "Recover lost items", position,
		Vector2(34, 34), Color("d5a6e6"), 6)
	created.add_to_group(&"death_drop")
	created.activated.connect(func(actor: Node) -> void:
		if authoritative and actor is PlayerActor:
			NetworkManager._recover_death_drop(actor.peer_id, drop_id)
		else:
			NetworkManager.request_recover_death_drop(drop_id)
	)
	_targets[drop_id] = created
	return created

func update_record(record: DeathDropRecord) -> void:
	if not authoritative or record.region_id != region_id:
		return
	var payload := _payload(record.id, not record.recovered)
	if record.recovered:
		_remove(record.id)
	NetworkManager.broadcast_death_drop_state(world_id, payload)

func _payload(drop_id: String, available: bool) -> Dictionary:
	var found := target(drop_id)
	var position := found.position if found != null else Vector2.ZERO
	# Roster contains geometry only. Inventory, owner-private state, and contents
	# never ride the public entity channel.
	return {"drop_id": drop_id, "entity_id": _entity_ids.get(drop_id, 0),
		"available": available, "position": [position.x, position.y]}

func _on_death(_peer_id: int, result: RespawnResult) -> void:
	for record in result.drops:
		if record.region_id == region_id and not record.recovered:
			_spawn_record(record)

func _on_ready_peer(peer_id: int) -> void:
	if GameSession.get_peer_world_id(peer_id) != world_id:
		return
	for drop_id in _targets:
		NetworkManager.send_death_drop_state(peer_id, world_id, _payload(drop_id, true))

func _on_state(p_world_id: StringName, payload: Dictionary) -> void:
	if authoritative or p_world_id != world_id:
		return
	var drop_id: Variant = payload.get("drop_id")
	var entity_id: Variant = payload.get("entity_id")
	var available: Variant = payload.get("available")
	var coordinates: Variant = payload.get("position")
	if not drop_id is String or drop_id.is_empty() or not entity_id is int or entity_id <= 0 \
			or not available is bool or not coordinates is Array or coordinates.size() != 2:
		return
	if not available:
		_remove(drop_id)
		return
	if not (coordinates[0] is float or coordinates[0] is int) or not (coordinates[1] is float or coordinates[1] is int):
		return
	var position := Vector2(float(coordinates[0]), float(coordinates[1]))
	if not position.is_finite() or target(drop_id) != null:
		return
	var created := _create_target(drop_id, position)
	if not registry.register_remote_entity_in_world(world_id, entity_id, created):
		_remove(drop_id)
		return
	_entity_ids[drop_id] = entity_id

func _remove(drop_id: String) -> void:
	var found := target(drop_id)
	registry.unregister_entity_in_world(world_id, _entity_ids.get(drop_id, 0))
	_targets.erase(drop_id)
	_entity_ids.erase(drop_id)
	if found != null:
		found.enabled = false
		found.queue_free()
