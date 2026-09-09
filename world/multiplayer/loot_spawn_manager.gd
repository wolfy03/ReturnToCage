class_name LootSpawnManager
extends Node

signal pickup_result(success: bool, item_id: StringName, quantity: int, message: String)

const LOOT_SCENE := preload("res://gameplay/actors/loot/loot_actor.tscn")
const PICKUP_RANGE := 82.0

var _registry: NetworkEntityRegistry
var _loot: Dictionary[int, LootActor] = {}

func get_loot(entity_id: int) -> LootActor:
	var actor: LootActor = _loot.get(entity_id)
	return actor if is_instance_valid(actor) else null

func entity_ids() -> Array[int]:
	var result: Array[int] = []
	result.assign(_loot.keys())
	return result

func _ready() -> void:
	_registry = get_parent().get_node_or_null("NetworkEntityRegistry") as NetworkEntityRegistry
	if _registry == null:
		push_error("LootSpawnManager requires NetworkEntityRegistry")
	if NetworkManager.is_server():
		NetworkManager.peer_world_ready.connect(_on_peer_world_ready)

func _exit_tree() -> void:
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)

func spawn_loot(stack: ItemStack, position: Vector2) -> int:
	if not NetworkManager.is_authoritative_simulation() or _registry == null or not position.is_finite():
		return 0
	var definition := ContentRegistry.get_item(stack.item_id) if stack != null else null
	if not StackValidation.runtime_error(stack, definition).is_empty():
		return 0
	var actor := LOOT_SCENE.instantiate() as LootActor
	var entity_id := _registry.register_entity(actor)
	if entity_id <= 0:
		actor.free()
		return 0
	actor.name = "Loot_%d" % entity_id
	actor.configure(entity_id, stack, self)
	actor.global_position = position
	get_parent().add_child(actor, true)
	_loot[entity_id] = actor
	print("[LOOT] Spawn %d (%s x%d)" % [entity_id, stack.item_id, stack.quantity])
	if NetworkManager.is_server():
		var snapshot := _snapshot(actor)
		for peer_id in NetworkManager.ready_remote_peer_ids():
			if NetworkManager.can_send_to_peer(peer_id):
				_spawn_loot.rpc_id(peer_id, snapshot.to_payload())
	return entity_id

func request_pickup(entity_id: int) -> void:
	if entity_id <= 0:
		return
	if NetworkManager.is_authoritative_simulation():
		server_try_pickup(NetworkManager.local_peer_id(), entity_id)
	elif NetworkManager.is_session_connected():
		_request_pickup.rpc_id(1, entity_id)

func server_try_pickup(peer_id: int, entity_id: int) -> CommandResult:
	if not NetworkManager.is_authoritative_simulation() or entity_id <= 0:
		return CommandResult.make(false, "Invalid pickup authority or entity")
	var loot: LootActor = _loot.get(entity_id)
	var player_manager := get_parent().get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	var player := player_manager.get_actor(peer_id) if player_manager != null else null
	var runtime := GameSession.get_player_runtime(peer_id)
	if loot == null or not is_instance_valid(loot) or _registry.get_entity(entity_id) != loot:
		return CommandResult.make(false, "Loot is unavailable")
	if player == null or runtime == null or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE:
		return CommandResult.make(false, "Player cannot pick up loot")
	if player.global_position.distance_to(loot.global_position) > PICKUP_RANGE:
		return CommandResult.make(false, "Loot is out of range")
	if loot.claim_state != LootActor.ClaimState.AVAILABLE or GameSession.adventure.active_session == null:
		return CommandResult.make(false, "Loot is already claimed")
	var personal := GameSession.adventure.active_session.get_player_adventure(peer_id)
	if personal == null:
		return CommandResult.make(false, "Adventure player is unavailable")
	loot.claim_state = LootActor.ClaimState.CLAIMING
	var outputs: Array[ItemStack] = [loot.stack.duplicate_stack()]
	var result := personal.unsecured_loot.exchange([], outputs)
	if not result.success:
		loot.claim_state = LootActor.ClaimState.AVAILABLE
		return result
	var item_id := loot.stack.item_id
	var quantity := loot.stack.quantity
	GameSession.report_gameplay_event(GameplayEvent.collect_item(GameSession.get_player_id(peer_id), item_id, quantity))
	print("[LOOT] Claimed entity %d by peer %d" % [entity_id, peer_id])
	_despawn_authoritative(entity_id)
	if NetworkManager.is_server() and peer_id != 1 and NetworkManager.can_send_to_peer(peer_id):
		_receive_pickup_result.rpc_id(peer_id, true, item_id, quantity, "Picked up")
	else:
		pickup_result.emit(true, item_id, quantity, "Picked up")
	return CommandResult.make(true, "Picked up")

@rpc("any_peer", "call_remote", "reliable")
func _request_pickup(entity_id: int) -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 1 or not NetworkManager.has_peer(sender) or not GameSession.has_player(sender):
		return
	var result := server_try_pickup(sender, entity_id)
	if not result.success and NetworkManager.can_send_to_peer(sender):
		_receive_pickup_result.rpc_id(sender, false, &"", 0, result.message)

@rpc("authority", "call_remote", "reliable")
func _receive_pickup_result(success: bool, item_id: StringName, quantity: int, message: String) -> void:
	pickup_result.emit(success, item_id, quantity, message)

func _despawn_authoritative(entity_id: int) -> void:
	var actor: LootActor = _loot.get(entity_id)
	_loot.erase(entity_id)
	_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.claim_state = LootActor.ClaimState.DESPAWNED
		actor.queue_free()
	if NetworkManager.is_server():
		for peer_id in NetworkManager.ready_remote_peer_ids():
			if NetworkManager.can_send_to_peer(peer_id):
				_despawn_loot.rpc_id(peer_id, entity_id)

func _snapshot(actor: LootActor) -> LootEntitySnapshot:
	var snapshot := LootEntitySnapshot.new()
	snapshot.entity_id = actor.network_entity_id
	snapshot.position = actor.global_position
	snapshot.stack = actor.stack.duplicate_stack()
	return snapshot

func _on_peer_world_ready(peer_id: int) -> void:
	if not NetworkManager.can_send_to_peer(peer_id):
		return
	for actor in _loot.values():
		if is_instance_valid(actor):
			_spawn_loot.rpc_id(peer_id, _snapshot(actor).to_payload())

@rpc("authority", "call_remote", "reliable")
func _spawn_loot(payload: Dictionary) -> void:
	if NetworkManager.is_server() or _registry == null:
		return
	var snapshot := LootEntitySnapshot.from_payload(payload)
	if not snapshot.error_message.is_empty() or _loot.has(snapshot.entity_id):
		return
	var actor := LOOT_SCENE.instantiate() as LootActor
	if not _registry.register_remote_entity(snapshot.entity_id, actor):
		actor.free()
		return
	actor.name = "Loot_%d" % snapshot.entity_id
	actor.configure(snapshot.entity_id, snapshot.stack, self)
	actor.global_position = snapshot.position
	get_parent().add_child(actor, true)
	_loot[snapshot.entity_id] = actor

@rpc("authority", "call_remote", "reliable")
func _despawn_loot(entity_id: int) -> void:
	if entity_id <= 0:
		return
	var actor: LootActor = _loot.get(entity_id)
	_loot.erase(entity_id)
	if _registry != null:
		_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.claim_state = LootActor.ClaimState.DESPAWNED
		actor.queue_free()
