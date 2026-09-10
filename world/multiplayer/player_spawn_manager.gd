class_name PlayerSpawnManager
extends Node

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")

var _actors: Dictionary[int, PlayerActor] = {}
var _slots: Dictionary[int, int] = {}
var _initialized: bool = false
var _world_ready_peers: Dictionary[int, bool] = {}

func get_actor(peer_id: int) -> PlayerActor:
	var actor: PlayerActor = _actors.get(peer_id)
	return actor if is_instance_valid(actor) else null

func _ready() -> void:
	GameSession.player_registered.connect(_on_player_registered)
	GameSession.player_unregistered.connect(_on_player_unregistered)
	call_deferred("initialize_spawns")

func initialize_spawns() -> void:
	if _initialized or not is_inside_tree():
		return
	_initialized = true
	if not NetworkManager.is_multiplayer_active():
		_spawn_local(GameSession.get_local_peer_id(), _spawn_position(0))
	elif NetworkManager.is_server():
		NetworkManager.begin_world_sync()
		_world_ready_peers[1] = true
		var peer_ids: Array[int] = []
		peer_ids.assign(GameSession.players.keys())
		peer_ids.sort()
		for peer_id in peer_ids:
			if _assign_slot(peer_id):
				_spawn_local(peer_id, _spawn_position(_slots[peer_id]))
	else:
		_request_world_roster.rpc_id(1)

func _exit_tree() -> void:
	if GameSession.player_registered.is_connected(_on_player_registered):
		GameSession.player_registered.disconnect(_on_player_registered)
	if GameSession.player_unregistered.is_connected(_on_player_unregistered):
		GameSession.player_unregistered.disconnect(_on_player_unregistered)

func _on_player_registered(peer_id: int, _state: PlayerState) -> void:
	if not NetworkManager.is_server():
		return
	if not _assign_slot(peer_id):
		push_warning("Cannot spawn peer %d: all %d player slots are occupied" % [peer_id, NetworkManager.MAX_PLAYERS])
		return
	var position := _spawn_position(_slots[peer_id])
	_spawn_local(peer_id, position)
	for ready_peer_id in _world_ready_peers:
		if ready_peer_id != 1 and NetworkManager.can_send_to_peer(ready_peer_id):
			_spawn_player.rpc_id(ready_peer_id, peer_id, position)

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

func _spawn_position(index: int) -> Vector2:
	var points: Array[PlayerSpawnPoint] = []
	for child in get_parent().get_children():
		if child is PlayerSpawnPoint:
			points.append(child)
	points.sort_custom(func(a: PlayerSpawnPoint, b: PlayerSpawnPoint) -> bool: return a.spawn_index < b.spawn_index)
	return points[index % points.size()].position if not points.is_empty() else Vector2(160 + index * 48, 520)

func _spawn_local(peer_id: int, spawn_position: Vector2) -> void:
	if _actors.has(peer_id) or not GameSession.has_player(peer_id):
		return
	var actor := PLAYER_SCENE.instantiate() as PlayerActor
	actor.name = "Player_%d" % peer_id if NetworkManager.is_multiplayer_active() else "Player"
	actor.setup_player(peer_id)
	actor.position = spawn_position
	get_parent().add_child(actor, true)
	_actors[peer_id] = actor

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
