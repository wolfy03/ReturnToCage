class_name PlayerSpawnManager
extends Node

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")

@export var settlement_spawn_policy: bool = false
@export var settlement_safe_bounds := Rect2(0, 0, 1400, 570)
@export_range(1.0, 24.0, 1.0) var clearance_radius: float = 8.0
@export_range(1.0, 160.0, 1.0) var support_distance: float = 100.0

var _actors: Dictionary[int, PlayerActor] = {}
var _slots: Dictionary[int, int] = {}
var _initialized: bool = false
var _world_ready_peers: Dictionary[int, bool] = {}
var _local_spawn_assignment: PlayerSpawnAssignment

func get_actor(peer_id: int) -> PlayerActor:
	var actor: PlayerActor = _actors.get(peer_id)
	return actor if is_instance_valid(actor) else null

func local_spawn_assignment() -> PlayerSpawnAssignment:
	return _local_spawn_assignment

func _ready() -> void:
	GameSession.player_registered.connect(_on_player_registered)
	GameSession.player_unregistered.connect(_on_player_unregistered)
	call_deferred("initialize_spawns")

func initialize_spawns() -> void:
	if _initialized or not is_inside_tree():
		return
	_initialized = true
	if not NetworkManager.is_multiplayer_active():
		_prepare_authoritative_spawn(GameSession.get_local_peer_id(), false)
	elif NetworkManager.is_server():
		if not NetworkManager.is_authoritative_simulation():
			push_error("Cannot initialize player spawns before the host session is ready")
			return
		NetworkManager.begin_world_sync()
		_world_ready_peers[1] = true
		var peer_ids: Array[int] = []
		peer_ids.assign(GameSession.players.keys())
		peer_ids.sort()
		for peer_id in peer_ids:
			_prepare_authoritative_spawn(peer_id, NetworkManager.is_returning_peer(peer_id))
	else:
		var assignment := NetworkManager.consume_local_spawn_assignment()
		_local_spawn_assignment = assignment
		if assignment == null or not assignment.error_message.is_empty() \
				or not _spawn_local(GameSession.get_local_peer_id(), assignment.position):
			push_error("Cannot apply the authoritative local spawn assignment")
			return
		_request_world_roster.rpc_id(1)

func _exit_tree() -> void:
	if GameSession.player_registered.is_connected(_on_player_registered):
		GameSession.player_registered.disconnect(_on_player_registered)
	if GameSession.player_unregistered.is_connected(_on_player_unregistered):
		GameSession.player_unregistered.disconnect(_on_player_unregistered)

func _on_player_registered(peer_id: int, _state: PlayerState) -> void:
	if not _initialized or not NetworkManager.is_server() or not NetworkManager.is_authoritative_simulation():
		return
	_prepare_authoritative_spawn(peer_id, NetworkManager.is_returning_peer(peer_id))

func _prepare_authoritative_spawn(peer_id: int, returning: bool) -> PlayerSpawnAssignment:
	var state := GameSession.get_player(peer_id)
	if state == null:
		return _failed_assignment("Cannot spawn an unknown player")
	var points := _spawn_points()
	if points.size() < NetworkManager.MAX_PLAYERS:
		push_warning("Player spawn configuration has %d slots for %d players" % [points.size(), NetworkManager.MAX_PLAYERS])
	var available: Array[Vector2] = []
	for point in points:
		if not _slots.values().has(point.spawn_index):
			available.append(point.position)
	var fallback: Array[Vector2] = []
	for point in points:
		fallback.append(point.position)
	# Adventure entry remains slot-based. last_safe_position is a Settlement-only
	# recovery candidate, never an arbitrary expedition coordinate.
	var use_returning := returning and settlement_spawn_policy
	var assignment := PlayerSpawnPolicy.decide(
		GameSession.session_id,
		GameSession.get_player_id(peer_id),
		use_returning,
		state.last_safe_position,
		available,
		fallback,
		Callable(self, "_position_issue")
	)
	if not assignment.error_message.is_empty():
		push_error("Cannot determine spawn for peer %d: %s" % [peer_id, assignment.error_message])
		return assignment
	# Any decision that lands exactly on a configured slot reserves it for this
	# active attachment, including a fallback. This prevents an immediately
	# following fresh join from selecting the same marker before physics sync.
	_remember_slot(peer_id, assignment.position, points)
	if assignment.fallback_used:
		print("[NET] Returning player %s safe spawn invalid: %s; using Settlement fallback" % [
			_player_fingerprint(assignment.player_id), assignment.reason,
		])
	if not _spawn_local(peer_id, assignment.position):
		return _failed_assignment("Cannot instantiate the authoritative player actor")
	if NetworkManager.is_server():
		if not NetworkManager.register_authoritative_spawn_assignment(peer_id, assignment):
			_despawn_local(peer_id)
			_slots.erase(peer_id)
			return _failed_assignment("Cannot register the authoritative spawn assignment")
	if settlement_spawn_policy and NetworkManager.is_authoritative_simulation():
		GameSession.update_player_last_safe_position(peer_id, assignment.position)
	if NetworkManager.is_server():
		for ready_peer_id in _world_ready_peers:
			if ready_peer_id != 1 and NetworkManager.can_send_to_peer(ready_peer_id):
				_spawn_player.rpc_id(ready_peer_id, peer_id, assignment.position)
	return assignment

func _on_player_unregistered(peer_id: int) -> void:
	_despawn_local(peer_id)
	_slots.erase(peer_id)
	_world_ready_peers.erase(peer_id)
	if NetworkManager.is_server():
		for ready_peer_id in _world_ready_peers:
			if ready_peer_id != 1 and NetworkManager.can_send_to_peer(ready_peer_id):
				_despawn_player.rpc_id(ready_peer_id, peer_id)

func _assign_slot(peer_id: int) -> bool:
	if _slots.has(peer_id):
		return _slots[peer_id] >= 0 and _slots[peer_id] < NetworkManager.MAX_PLAYERS
	for index in NetworkManager.MAX_PLAYERS:
		if not _slots.values().has(index):
			_slots[peer_id] = index
			return true
	return false

func _spawn_points() -> Array[PlayerSpawnPoint]:
	var points: Array[PlayerSpawnPoint] = []
	for child in get_parent().get_children():
		if child is PlayerSpawnPoint:
			points.append(child)
	points.sort_custom(func(a: PlayerSpawnPoint, b: PlayerSpawnPoint) -> bool: return a.spawn_index < b.spawn_index)
	return points

func _spawn_position(index: int) -> Vector2:
	var points := _spawn_points()
	return points[index % points.size()].position if not points.is_empty() else Vector2.INF

func _remember_slot(peer_id: int, position: Vector2, points: Array[PlayerSpawnPoint]) -> void:
	for point in points:
		if point.position.is_equal_approx(position):
			_slots[peer_id] = point.spawn_index
			return

func _position_issue(position: Vector2) -> String:
	if not position.is_finite():
		return "NON_FINITE"
	if settlement_spawn_policy and not settlement_safe_bounds.has_point(position):
		return "OUT_OF_BOUNDS"
	var world_root := get_parent() as Node2D
	if not is_inside_tree() or world_root == null or world_root.get_world_2d() == null:
		return "WORLD_UNAVAILABLE"
	var space: PhysicsDirectSpaceState2D = world_root.get_world_2d().direct_space_state
	var clearance := CircleShape2D.new()
	clearance.radius = clearance_radius
	var shape_query := PhysicsShapeQueryParameters2D.new()
	shape_query.shape = clearance
	shape_query.transform = Transform2D(0.0, world_root.to_global(position))
	shape_query.collision_mask = 1
	shape_query.collide_with_areas = false
	shape_query.collide_with_bodies = true
	if not space.intersect_shape(shape_query, 1).is_empty():
		return "BLOCKED"
	var origin := world_root.to_global(position)
	var ray := PhysicsRayQueryParameters2D.create(origin, origin + Vector2.DOWN * support_distance, 1)
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	if space.intersect_ray(ray).is_empty():
		return "NO_WALKABLE_SUPPORT"
	return ""

func _spawn_local(peer_id: int, spawn_position: Vector2) -> bool:
	if _actors.has(peer_id) or not GameSession.has_player(peer_id) or not spawn_position.is_finite():
		return false
	var actor := PLAYER_SCENE.instantiate() as PlayerActor
	actor.name = "Player_%d" % peer_id if NetworkManager.is_multiplayer_active() else "Player"
	actor.setup_player(peer_id)
	actor.position = spawn_position
	get_parent().add_child(actor, true)
	_actors[peer_id] = actor
	return true

func _despawn_local(peer_id: int) -> void:
	var actor: PlayerActor = _actors.get(peer_id)
	_actors.erase(peer_id)
	if is_instance_valid(actor):
		if actor.is_inside_tree() and actor.get_parent() != null:
			actor.get_parent().remove_child(actor)
		actor.queue_free()

func respawn_player(peer_id: int) -> bool:
	if not NetworkManager.is_server() or not GameSession.has_player(peer_id) or not _assign_slot(peer_id):
		return false
	var spawn_position := _spawn_position(_slots[peer_id])
	if not _position_issue(spawn_position).is_empty():
		return false
	_replace_actor_local(peer_id, spawn_position)
	for ready_peer_id in _world_ready_peers:
		if ready_peer_id != 1 and NetworkManager.can_send_to_peer(ready_peer_id):
			_respawn_player.rpc_id(ready_peer_id, peer_id, spawn_position)
	return true

func _replace_actor_local(peer_id: int, spawn_position: Vector2) -> void:
	var actor: PlayerActor = _actors.get(peer_id)
	_actors.erase(peer_id)
	if is_instance_valid(actor):
		actor.get_parent().remove_child(actor)
		actor.queue_free()
	_spawn_local(peer_id, spawn_position)

@rpc("any_peer", "call_remote", "reliable")
func _request_world_roster() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not GameSession.has_player(sender) or not NetworkManager.has_peer(sender):
		return
	for peer_id in _actors:
		var actor: PlayerActor = _actors[peer_id]
		if is_instance_valid(actor):
			_spawn_player.rpc_id(sender, peer_id, actor.position)
	_world_roster_complete.rpc_id(sender)

@rpc("authority", "call_remote", "reliable")
func _world_roster_complete() -> void:
	_confirm_world_ready.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_world_ready() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not GameSession.has_player(sender) or not NetworkManager.has_peer(sender):
		return
	_world_ready_peers[sender] = true
	NetworkManager.mark_peer_world_ready(sender)

@rpc("authority", "call_remote", "reliable")
func _spawn_player(peer_id: int, spawn_position: Vector2) -> void:
	if not spawn_position.is_finite() or not GameSession.has_player(peer_id):
		return
	_spawn_local(peer_id, spawn_position)

@rpc("authority", "call_remote", "reliable")
func _despawn_player(peer_id: int) -> void:
	_despawn_local(peer_id)

@rpc("authority", "call_remote", "reliable")
func _respawn_player(peer_id: int, spawn_position: Vector2) -> void:
	if not spawn_position.is_finite() or not GameSession.has_player(peer_id):
		return
	_replace_actor_local(peer_id, spawn_position)

func _failed_assignment(message: String) -> PlayerSpawnAssignment:
	var result := PlayerSpawnAssignment.new()
	result.error_message = message
	return result

func _player_fingerprint(player_id: StringName) -> String:
	var text := String(player_id)
	return text.right(8) if text.length() >= 8 else text
