extends Node

signal transition_started(destination: StringName)
signal transition_failed(message: String)
signal transition_finished(destination: StringName)

const SETTLEMENT_SCENE := "res://world/settlement/settlement.tscn"
var _world_layer: Node
var _current_world_id: StringName = &""
var _assignment_session_id: String = ""
var _assignment_revision: int = 0

func register_world_layer(layer: Node) -> void:
	_world_layer = layer

func current_world_id() -> StringName:
	return _current_world_id

# Network authority is resolved before this presentation call. SceneRouter only
# validates that the assignment belongs to the current local identity/session,
# rejects stale revisions, and resolves a content-owned destination scene.
func apply_world_assignment(assignment: PlayerWorldAssignment) -> bool:
	if assignment == null or not assignment.error_message.is_empty() \
			or assignment.session_id != GameSession.session_id \
			or assignment.player_id != GameSession.get_local_player_id():
		_report_failure("World assignment does not belong to the local session")
		return false
	if _assignment_session_id == assignment.session_id and assignment.revision < _assignment_revision:
		return false
	if _assignment_session_id == assignment.session_id and assignment.revision == _assignment_revision \
			and _current_world_id == assignment.world_id and _has_presented_world():
		return true
	var local_world := GameSession.get_local_player_world()
	if local_world == null or local_world.world_id != assignment.world_id \
			or local_world.revision != assignment.revision:
		_report_failure("World assignment differs from the authoritative player state")
		return false
	var changed := false
	if assignment.world_kind == PlayerWorldState.WorldKind.SETTLEMENT:
		changed = _replace_world(SETTLEMENT_SCENE, assignment.world_id, null)
	elif assignment.world_kind == PlayerWorldState.WorldKind.ADVENTURE:
		var definition := ContentRegistry.get_definition(assignment.region_id) as RegionDefinition
		var context := assignment.to_adventure_context(GameSession.difficulty.id)
		if definition == null or context == null:
			_report_failure("Unknown assigned adventure region")
			return false
		changed = _replace_world(definition.scene_path, assignment.world_id, context)
	if changed:
		_assignment_session_id = assignment.session_id
		_assignment_revision = assignment.revision
	return changed

func _has_presented_world() -> bool:
	return is_instance_valid(_world_layer) and _world_layer.get_child_count() > 0

func go_to_settlement() -> bool:
	if GameSession.adventure.active_session != null:
		_report_failure("Use an escape point or return item to leave the expedition")
		return false
	return _replace_world(SETTLEMENT_SCENE, &"settlement", null)

func go_to_adventure(context: AdventureContext) -> bool:
	if context == null or GameSession.adventure.active_session == null or GameSession.adventure.active_session.context != context:
		_report_failure("No authorized expedition context")
		return false
	var definition := ContentRegistry.get_definition(context.region_id) as RegionDefinition
	if definition == null:
		_report_failure("Unknown region: %s" % context.region_id)
		return false
	return _replace_world(
		definition.scene_path, PlayerWorldState.adventure_world_id(context.region_id), context
	)

func _replace_world(scene_path: String, destination: StringName, context: AdventureContext) -> bool:
	if not is_instance_valid(_world_layer):
		_report_failure("World layer is not registered")
		return false
	transition_started.emit(destination)
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		_report_failure("Cannot load scene: %s" % scene_path)
		return false
	for child in _world_layer.get_children():
		child.process_mode = Node.PROCESS_MODE_DISABLED
		_world_layer.remove_child(child)
		child.queue_free()
	var instance := packed.instantiate()
	if context != null and instance.has_method("configure"):
		instance.configure(context)
	if destination == &"settlement":
		GameSession.complete_respawn(GameSession.get_local_peer_id())
	_world_layer.add_child(instance)
	_current_world_id = destination
	transition_finished.emit(destination)
	return true

func _report_failure(message: String) -> void:
	# Respawn remains retryable. GameSession gates ticks while waiting for a valid
	# world, but no stale model pause survives a later successful retry.
	if GameSession.phase == GameSession.Phase.RESPAWNING:
		var local_state := GameSession.get_player(GameSession.get_local_peer_id())
		if local_state != null:
			local_state.effects.paused = false
	transition_failed.emit(message)
