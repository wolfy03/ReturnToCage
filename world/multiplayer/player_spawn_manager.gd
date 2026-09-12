class_name PlayerSpawnManager
extends Node

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")

@export var settlement_spawn_policy: bool = false
@export var world_id: StringName = &""
@export var authoritative_runtime: bool = false
@export var settlement_safe_bounds := Rect2(0, 0, 1400, 570)
@export_range(1.0, 24.0, 1.0) var clearance_radius: float = 8.0
@export_range(1.0, 160.0, 1.0) var support_distance: float = 100.0
@export_flags_2d_physics var spawn_validation_collision_mask: int = 1

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
	add_to_group(&"player_spawn_manager")
	GameSession.player_registered.connect(_on_player_registered)
	GameSession.player_unregistered.connect(_on_player_unregistered)
	GameSession.player_world_changed.connect(_on_player_world_changed)
	NetworkManager.world_roster_player_received.connect(_on_world_roster_player_received)
	NetworkManager.world_roster_player_removed.connect(_on_world_roster_player_removed)
	NetworkManager.local_world_roster_complete.connect(_on_world_roster_complete)
	NetworkManager.peer_world_ready.connect(_on_peer_world_ready)
	NetworkManager.player_respawn_received.connect(_on_player_respawn_received)
	call_deferred("initialize_spawns")

func configure_world(p_world_id: StringName) -> void:
	if not _initialized and not p_world_id.is_empty():
		world_id = p_world_id

func initialize_spawns() -> void:
	if _initialized or not is_inside_tree():
		return
	# A restoring host owns an ENet server but cannot initialize gameplay actors.
	# Keep this retryable: readiness is a precondition, not an initialized state.
	if NetworkManager.is_server() and not NetworkManager.is_authoritative_simulation():
		return
	if world_id.is_empty():
		world_id = PlayerWorldState.SETTLEMENT_WORLD_ID if settlement_spawn_policy \
				else GameSession.get_peer_world_id(GameSession.get_local_peer_id())
	if world_id.is_empty() or not authoritative_runtime \
			and GameSession.get_peer_world_id(GameSession.get_local_peer_id()) != world_id:
		return
	var initialized := true
	if not NetworkManager.is_multiplayer_active():
		initialized = _prepare_authoritative_spawn(
			GameSession.get_local_peer_id(), false
		).error_message.is_empty()
	elif NetworkManager.is_server() and authoritative_runtime:
		var peer_ids: Array[int] = []
		peer_ids = GameSession.peer_ids_in_world(world_id)
		for peer_id in peer_ids:
			var assignment := NetworkManager.spawn_assignment_for_peer(peer_id)
			if assignment == null:
				assignment = _prepare_authoritative_spawn(peer_id, NetworkManager.is_returning_peer(peer_id))
			elif not _spawn_local(peer_id, assignment.position):
				assignment = _failed_assignment("Cannot instantiate the authoritative player actor")
			if not assignment.error_message.is_empty():
				initialized = false
	else:
		# Do not consume the one-shot assignment until actor placement succeeds.
		# A scene/configuration failure can then be corrected and retried.
		var assignment := NetworkManager.spawn_assignment_for_peer(GameSession.get_local_peer_id()) \
				if NetworkManager.is_server() else NetworkManager.peek_local_spawn_assignment()
		if assignment == null and NetworkManager.is_server():
			assignment = NetworkManager.ensure_authoritative_spawn_assignment(GameSession.get_local_peer_id())
		_local_spawn_assignment = assignment
		if assignment == null or not assignment.error_message.is_empty() \
				or GameSession.get_peer_world_id(GameSession.get_local_peer_id()) != world_id \
				or not _spawn_local(GameSession.get_local_peer_id(), assignment.position):
			push_error("Cannot apply the authoritative local spawn assignment")
			initialized = false
		else:
			if not NetworkManager.is_server():
				NetworkManager.consume_local_spawn_assignment()
			if NetworkManager.is_server():
				NetworkManager.call_deferred("request_local_world_roster")
			else:
				NetworkManager.request_local_world_roster()
	_initialized = initialized

func _exit_tree() -> void:
	if GameSession.player_registered.is_connected(_on_player_registered):
		GameSession.player_registered.disconnect(_on_player_registered)
	if GameSession.player_unregistered.is_connected(_on_player_unregistered):
		GameSession.player_unregistered.disconnect(_on_player_unregistered)
	if GameSession.player_world_changed.is_connected(_on_player_world_changed):
		GameSession.player_world_changed.disconnect(_on_player_world_changed)
	if NetworkManager.world_roster_player_received.is_connected(_on_world_roster_player_received):
		NetworkManager.world_roster_player_received.disconnect(_on_world_roster_player_received)
	if NetworkManager.world_roster_player_removed.is_connected(_on_world_roster_player_removed):
		NetworkManager.world_roster_player_removed.disconnect(_on_world_roster_player_removed)
	if NetworkManager.local_world_roster_complete.is_connected(_on_world_roster_complete):
		NetworkManager.local_world_roster_complete.disconnect(_on_world_roster_complete)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)
	if NetworkManager.player_respawn_received.is_connected(_on_player_respawn_received):
		NetworkManager.player_respawn_received.disconnect(_on_player_respawn_received)

func _on_player_registered(peer_id: int, _state: PlayerState) -> void:
	if not _initialized or not NetworkManager.is_server() or not NetworkManager.is_authoritative_simulation():
		return
	if GameSession.get_peer_world_id(peer_id) != world_id:
		return
	if authoritative_runtime:
		_prepare_authoritative_spawn(peer_id, NetworkManager.is_returning_peer(peer_id))
	else:
		_spawn_registered_presentation(peer_id)

func _spawn_registered_presentation(peer_id: int) -> void:
	if authoritative_runtime or get_actor(peer_id) != null or GameSession.get_peer_world_id(peer_id) != world_id:
		return
	var assignment := NetworkManager.spawn_assignment_for_peer(peer_id)
	if assignment == null and NetworkManager.is_server():
		assignment = NetworkManager.ensure_authoritative_spawn_assignment(peer_id)
	if assignment != null and assignment.position.is_finite():
		_spawn_local(peer_id, assignment.position)

func _on_player_world_changed(player_id: StringName, state: PlayerWorldState) -> void:
	if not _initialized:
		return
	var peer_id := NetworkManager.peer_id_for_player(player_id)
	if peer_id <= 0:
		return
	if state.world_id != world_id:
		if authoritative_runtime:
			_despawn_local(peer_id)
			_slots.erase(peer_id)
		else:
			var actor := get_actor(peer_id)
			if actor != null:
				actor.visible = false
				actor.process_mode = Node.PROCESS_MODE_DISABLED
	elif authoritative_runtime and get_actor(peer_id) == null:
		var assignment := NetworkManager.spawn_assignment_for_peer(peer_id)
		if assignment != null:
			apply_authoritative_world_arrival(peer_id, assignment)

func _on_peer_world_ready(peer_id: int) -> void:
	if not authoritative_runtime:
		reconcile_peer_world(peer_id)

func reconcile_peer_world(peer_id: int) -> void:
	if GameSession.get_peer_world_id(peer_id) != world_id:
		_despawn_local(peer_id)
		_slots.erase(peer_id)

func apply_authoritative_world_arrival(peer_id: int, assignment: PlayerSpawnAssignment) -> bool:
	if not _initialized or not authoritative_runtime or not NetworkManager.is_server() or assignment == null \
			or GameSession.get_peer_world_id(peer_id) != world_id:
		return false
	var existing := get_actor(peer_id)
	if existing != null:
		existing.position = assignment.position
		existing.visible = true
		existing.process_mode = Node.PROCESS_MODE_INHERIT
		return true
	var points := _spawn_points()
	_remember_slot(peer_id, assignment.position, points)
	if not _spawn_local(peer_id, assignment.position):
		return false
	if settlement_spawn_policy:
		GameSession.update_player_last_safe_position(peer_id, assignment.position)
	return true

func _prepare_authoritative_spawn(peer_id: int, returning: bool) -> PlayerSpawnAssignment:
	if NetworkManager.is_multiplayer_active() and not authoritative_runtime:
		return _failed_assignment("Presentation spawners cannot create authoritative actors")
	var state := GameSession.get_player(peer_id)
	if state == null:
		return _failed_assignment("Cannot spawn an unknown player")
	# A prior pass may have initialized some peers before another peer failed.
	# Treat an already coherent actor/assignment pair as complete on retry.
	var existing_actor := get_actor(peer_id)
	var existing_assignment := NetworkManager.spawn_assignment_for_peer(peer_id) \
			if NetworkManager.is_server() else null
	if existing_actor != null and existing_assignment != null \
			and existing_assignment.player_id == GameSession.get_player_id(peer_id) \
			and existing_assignment.session_id == GameSession.session_id:
		return existing_assignment
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
	return assignment

func _on_player_unregistered(peer_id: int) -> void:
	_despawn_local(peer_id)
	_slots.erase(peer_id)
	_world_ready_peers.erase(peer_id)

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
	if spawn_validation_collision_mask == 0:
		return "INVALID_COLLISION_MASK"
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
	shape_query.collision_mask = spawn_validation_collision_mask
	shape_query.collide_with_areas = false
	shape_query.collide_with_bodies = true
	if not space.intersect_shape(shape_query, 1).is_empty():
		return "BLOCKED"
	var origin := world_root.to_global(position)
	var ray := PhysicsRayQueryParameters2D.create(
		origin, origin + Vector2.DOWN * support_distance, spawn_validation_collision_mask
	)
	ray.collide_with_areas = false
	ray.collide_with_bodies = true
	if space.intersect_ray(ray).is_empty():
		return "NO_WALKABLE_SUPPORT"
	return ""

func _spawn_local(peer_id: int, spawn_position: Vector2) -> bool:
	if _actors.has(peer_id) or not GameSession.has_player(peer_id) or not spawn_position.is_finite() \
			or GameSession.get_peer_world_id(peer_id) != world_id:
		return false
	var actor := PLAYER_SCENE.instantiate() as PlayerActor
	actor.name = "Player_%d" % peer_id if NetworkManager.is_multiplayer_active() else "Player"
	var simulation := not NetworkManager.is_multiplayer_active() or authoritative_runtime
	actor.setup_player(peer_id, simulation, not authoritative_runtime, world_id)
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
	if not NetworkManager.is_server() or not GameSession.has_player(peer_id) or not _assign_slot(peer_id) \
			or NetworkManager.is_multiplayer_active() and not authoritative_runtime:
		return false
	var spawn_position := _spawn_position(_slots[peer_id])
	if not _position_issue(spawn_position).is_empty():
		return false
	_replace_actor_local(peer_id, spawn_position)
	NetworkManager.broadcast_player_respawn(world_id, peer_id, spawn_position)
	return true

func _replace_actor_local(peer_id: int, spawn_position: Vector2) -> void:
	var actor: PlayerActor = _actors.get(peer_id)
	_actors.erase(peer_id)
	if is_instance_valid(actor):
		actor.get_parent().remove_child(actor)
		actor.queue_free()
	_spawn_local(peer_id, spawn_position)

func _on_world_roster_player_received(
	peer_id: int,
	assignment: PlayerWorldAssignment,
	spawn_position: Vector2
) -> void:
	if not _initialized or assignment == null or assignment.world_id != world_id:
		return
	if get_actor(peer_id) == null:
		_spawn_local(peer_id, spawn_position)

func _on_world_roster_player_removed(peer_id: int) -> void:
	_despawn_local(peer_id)
	_slots.erase(peer_id)

func _on_world_roster_complete(p_world_id: StringName, _revision: int) -> void:
	if _initialized and p_world_id == world_id:
		NetworkManager.confirm_local_world_ready()

func _on_player_respawn_received(p_world_id: StringName, peer_id: int, spawn_position: Vector2) -> void:
	if authoritative_runtime or p_world_id != world_id or not spawn_position.is_finite() \
			or not GameSession.has_player(peer_id):
		return
	_replace_actor_local(peer_id, spawn_position)

func _failed_assignment(message: String) -> PlayerSpawnAssignment:
	var result := PlayerSpawnAssignment.new()
	result.error_message = message
	return result

func _player_fingerprint(player_id: StringName) -> String:
	var text := String(player_id)
	return text.right(8) if text.length() >= 8 else text
