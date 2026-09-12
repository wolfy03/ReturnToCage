class_name QuestReplicationService
extends Node

signal reward_result(success: bool, message: String)

func _ready() -> void:
	GameSession.quest_state_changed.connect(_on_quest_state_changed)
	NetworkManager.peer_world_ready.connect(_on_peer_world_ready)

func _exit_tree() -> void:
	if GameSession.quest_state_changed.is_connected(_on_quest_state_changed):
		GameSession.quest_state_changed.disconnect(_on_quest_state_changed)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)

func request_reward(quest_id: StringName) -> void:
	if NetworkManager.is_authoritative_simulation():
		var result := GameSession.claim_quest_reward_result(quest_id, GameSession.get_local_player_id())
		reward_result.emit(result.success, result.message)
	elif NetworkManager.is_session_connected():
		_request_reward.rpc_id(1, quest_id)

func _on_peer_world_ready(peer_id: int) -> void:
	if not NetworkManager.is_server() or not NetworkManager.can_send_to_peer(peer_id):
		return
	var player_id := NetworkManager.player_id_for_peer(peer_id)
	for snapshot in GameSession.quest_snapshots_for_player(player_id):
		_receive_snapshot.rpc_id(peer_id, snapshot.to_payload())

func _on_quest_state_changed(quest_id: StringName, scope: int, owner_player_id: StringName, _revision: int) -> void:
	if not NetworkManager.is_server():
		return
	var snapshot := GameSession.make_quest_snapshot(quest_id, owner_player_id)
	if snapshot == null:
		return
	if scope == QuestDefinition.Scope.PERSONAL:
		var peer_id := NetworkManager.peer_id_for_player(owner_player_id)
		if peer_id > 1 and NetworkManager.can_send_to_peer(peer_id) and NetworkManager.is_peer_world_ready(peer_id):
			_receive_snapshot.rpc_id(peer_id, snapshot.to_payload())
		return
	for peer_id in NetworkManager.all_ready_remote_peer_ids():
		if NetworkManager.can_send_to_peer(peer_id):
			_receive_snapshot.rpc_id(peer_id, snapshot.to_payload())

@rpc("any_peer", "call_remote", "reliable")
func _request_reward(quest_id: StringName) -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var player_id := NetworkManager.player_id_for_peer(sender)
	if sender <= 1 or player_id.is_empty() or not GameSession.has_player(sender):
		return
	var result := GameSession.claim_quest_reward_result(quest_id, player_id)
	if NetworkManager.can_send_to_peer(sender):
		_receive_reward_result.rpc_id(sender, result.success, result.message)

@rpc("authority", "call_remote", "reliable")
func _receive_snapshot(payload: Dictionary) -> void:
	if NetworkManager.is_server():
		return
	var snapshot := QuestStateSnapshot.from_payload(payload, ContentRegistry, GameSession.get_local_player_id())
	if snapshot.error_message.is_empty():
		GameSession.apply_quest_network_snapshot(snapshot)

@rpc("authority", "call_remote", "reliable")
func _receive_reward_result(success: bool, message: String) -> void:
	reward_result.emit(success, message)
