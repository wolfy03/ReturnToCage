class_name LootSpawnManager
extends Node

signal pickup_result(success: bool, item_id: StringName, quantity: int, message: String)

const LOOT_SCENE := preload("res://gameplay/actors/loot/loot_actor.tscn")
const PICKUP_RANGE := 82.0

var _registry: NetworkEntityRegistry
var _loot: Dictionary[int, LootActor] = {}
var world_id: StringName = &""
var authoritative_runtime: bool = false

func configure_world(p_world_id: StringName, p_authoritative_runtime: bool = true) -> void:
	world_id = p_world_id
	authoritative_runtime = p_authoritative_runtime

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
	if world_id.is_empty():
		world_id = GameSession.get_peer_world_id(GameSession.get_local_peer_id())
	if _registry != null:
		_registry.configure_world(world_id)
	NetworkManager.loot_spawn_received.connect(_on_loot_spawn_received)
	NetworkManager.loot_despawn_received.connect(_on_loot_despawn_received)
	NetworkManager.loot_pickup_result_received.connect(_on_loot_pickup_result_received)
	if authoritative_runtime and NetworkManager.is_server():
		NetworkManager.peer_world_ready.connect(_on_peer_world_ready)
		NetworkManager.loot_pickup_requested.connect(_on_loot_pickup_requested)

func _exit_tree() -> void:
	if NetworkManager.loot_spawn_received.is_connected(_on_loot_spawn_received):
		NetworkManager.loot_spawn_received.disconnect(_on_loot_spawn_received)
	if NetworkManager.loot_despawn_received.is_connected(_on_loot_despawn_received):
		NetworkManager.loot_despawn_received.disconnect(_on_loot_despawn_received)
	if NetworkManager.loot_pickup_result_received.is_connected(_on_loot_pickup_result_received):
		NetworkManager.loot_pickup_result_received.disconnect(_on_loot_pickup_result_received)
	if NetworkManager.loot_pickup_requested.is_connected(_on_loot_pickup_requested):
		NetworkManager.loot_pickup_requested.disconnect(_on_loot_pickup_requested)
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
		NetworkManager.broadcast_loot_spawn(world_id, _snapshot(actor).to_payload())
	return entity_id

func request_pickup(entity_id: int) -> void:
	if entity_id <= 0:
		return
	if NetworkManager.is_authoritative_simulation():
		NetworkManager.request_loot_pickup(entity_id)
	elif NetworkManager.is_session_connected():
		NetworkManager.request_loot_pickup(entity_id)

func server_try_pickup(peer_id: int, entity_id: int) -> CommandResult:
	if not NetworkManager.is_authoritative_simulation() or entity_id <= 0:
		return CommandResult.make(false, "Invalid pickup authority or entity")
	var effective_world := world_id if not world_id.is_empty() else GameSession.get_peer_world_id(peer_id)
	if not world_id.is_empty() and GameSession.get_peer_world_id(peer_id) != world_id:
		return CommandResult.make(false, "Loot belongs to another world")
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
	var adventure_session := GameSession.adventure_session_for_world(effective_world)
	if adventure_session == null:
		adventure_session = GameSession.adventure.active_session
	if loot.claim_state != LootActor.ClaimState.AVAILABLE or adventure_session == null:
		return CommandResult.make(false, "Loot is already claimed")
	var personal := adventure_session.get_player_adventure(peer_id)
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
	NetworkManager.send_loot_pickup_result(peer_id, true, item_id, quantity, "Picked up")
	return CommandResult.make(true, "Picked up")

func _on_loot_pickup_requested(peer_id: int, p_world_id: StringName, entity_id: int) -> void:
	if not authoritative_runtime or p_world_id != world_id:
		return
	var result := server_try_pickup(peer_id, entity_id)
	if not result.success:
		NetworkManager.send_loot_pickup_result(peer_id, false, &"", 0, result.message)

func _on_loot_pickup_result_received(success: bool, item_id: StringName, quantity: int, message: String) -> void:
	pickup_result.emit(success, item_id, quantity, message)

func _despawn_authoritative(entity_id: int) -> void:
	var actor: LootActor = _loot.get(entity_id)
	_loot.erase(entity_id)
	_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.claim_state = LootActor.ClaimState.DESPAWNED
		actor.queue_free()
	if NetworkManager.is_server():
		NetworkManager.broadcast_loot_despawn(world_id, entity_id)

func _snapshot(actor: LootActor) -> LootEntitySnapshot:
	var snapshot := LootEntitySnapshot.new()
	snapshot.entity_id = actor.network_entity_id
	snapshot.position = actor.global_position
	snapshot.stack = actor.stack.duplicate_stack()
	return snapshot

func _on_peer_world_ready(peer_id: int) -> void:
	if not NetworkManager.can_send_to_peer(peer_id) or GameSession.get_peer_world_id(peer_id) != world_id:
		return
	var payloads: Array[Dictionary] = []
	for actor in _loot.values():
		if is_instance_valid(actor):
			payloads.append(_snapshot(actor).to_payload())
	NetworkManager.send_loot_roster(peer_id, world_id, payloads)

func _on_loot_spawn_received(p_world_id: StringName, payload: Dictionary) -> void:
	if authoritative_runtime or p_world_id != world_id or _registry == null:
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

func _on_loot_despawn_received(p_world_id: StringName, entity_id: int) -> void:
	if authoritative_runtime or p_world_id != world_id or entity_id <= 0:
		return
	var actor: LootActor = _loot.get(entity_id)
	_loot.erase(entity_id)
	if _registry != null:
		_registry.unregister_entity(entity_id)
	if is_instance_valid(actor):
		actor.claim_state = LootActor.ClaimState.DESPAWNED
		actor.queue_free()
