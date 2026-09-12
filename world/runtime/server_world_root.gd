class_name ServerWorldRoot
extends Node

var _runtimes: Dictionary[StringName, ServerWorldRuntime] = {}

func _ready() -> void:
	add_to_group(&"server_world_root")
	GameSession.session_reset.connect(_on_session_reset)
	GameSession.player_registered.connect(_on_player_registered)
	GameSession.player_unregistered.connect(_on_player_unregistered)
	GameSession.player_world_changed.connect(_on_player_world_changed)
	NetworkManager.hosting_started.connect(_on_hosting_started)
	NetworkManager.multiplayer_session_ended.connect(_on_session_ended)
	call_deferred("reconcile")

func _exit_tree() -> void:
	if GameSession.session_reset.is_connected(_on_session_reset):
		GameSession.session_reset.disconnect(_on_session_reset)
	if GameSession.player_registered.is_connected(_on_player_registered):
		GameSession.player_registered.disconnect(_on_player_registered)
	if GameSession.player_unregistered.is_connected(_on_player_unregistered):
		GameSession.player_unregistered.disconnect(_on_player_unregistered)
	if GameSession.player_world_changed.is_connected(_on_player_world_changed):
		GameSession.player_world_changed.disconnect(_on_player_world_changed)
	if NetworkManager.hosting_started.is_connected(_on_hosting_started):
		NetworkManager.hosting_started.disconnect(_on_hosting_started)
	if NetworkManager.multiplayer_session_ended.is_connected(_on_session_ended):
		NetworkManager.multiplayer_session_ended.disconnect(_on_session_ended)
	clear_runtimes()

func runtime(world_id: StringName) -> ServerWorldRuntime:
	var result: ServerWorldRuntime = _runtimes.get(world_id)
	return result if result != null and is_instance_valid(result) else null

func runtime_count() -> int:
	return _runtimes.size()

func world_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	result.assign(_runtimes.keys())
	result.sort()
	return result

func reconcile() -> void:
	if not NetworkManager.is_host_session_ready() or GameSession.session_id.is_empty():
		clear_runtimes()
		return
	var required: Dictionary[StringName, PlayerWorldState] = {}
	for peer_id in GameSession.players:
		var state := GameSession.get_peer_world(peer_id)
		if state != null:
			required[state.world_id] = state
	for world_id in required:
		if not _runtimes.has(world_id):
			_create_runtime(required[world_id])
	for world_id in _runtimes.keys():
		if not required.has(world_id):
			_remove_runtime(world_id)

func clear_runtimes() -> void:
	for world_id in _runtimes.keys():
		_remove_runtime(world_id)

func _create_runtime(state: PlayerWorldState) -> ServerWorldRuntime:
	if state == null or not state.is_valid():
		return null
	var scene_path := SceneRouter.SETTLEMENT_SCENE
	if state.world_kind == PlayerWorldState.WorldKind.ADVENTURE:
		var definition := ContentRegistry.get_definition(state.region_id) as RegionDefinition
		if definition == null:
			return null
		scene_path = definition.scene_path
	var runtime_model := WorldRuntime.new(state.world_id, state.world_kind, state.region_id)
	var instance := ServerWorldRuntime.new()
	if not instance.configure(runtime_model, scene_path):
		instance.free()
		return null
	_runtimes[state.world_id] = instance
	add_child(instance)
	return instance

func _remove_runtime(world_id: StringName) -> void:
	var instance: ServerWorldRuntime = _runtimes.get(world_id)
	_runtimes.erase(world_id)
	if instance != null and is_instance_valid(instance):
		instance.queue_free()

func _schedule_reconcile(_unused_a = null, _unused_b = null) -> void:
	call_deferred("reconcile")

func _on_session_reset() -> void:
	clear_runtimes()
	reconcile()

func _on_hosting_started() -> void:
	reconcile()

func _on_player_registered(_peer_id: int, _state: PlayerState) -> void:
	_schedule_reconcile()

func _on_player_unregistered(_peer_id: int) -> void:
	_schedule_reconcile()

func _on_player_world_changed(_player_id: StringName, _state: PlayerWorldState) -> void:
	# Create the destination runtime synchronously so transition finalization can
	# bind its authoritative actor before any destination-ready acknowledgement.
	reconcile()

func _on_session_ended(_reason: String) -> void:
	clear_runtimes()
