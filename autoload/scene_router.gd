extends Node

signal transition_started(destination: StringName)
signal transition_failed(message: String)
signal transition_finished(destination: StringName)

const SETTLEMENT_SCENE := "res://world/settlement/settlement.tscn"
var _world_layer: Node

func register_world_layer(layer: Node) -> void:
	_world_layer = layer

func go_to_settlement() -> bool:
	if GameSession.adventure.active_session != null:
		transition_failed.emit("Use an escape point or return item to leave the expedition")
		return false
	return _replace_world(SETTLEMENT_SCENE, &"settlement", null)

func go_to_adventure(context: AdventureContext) -> bool:
	if context == null or GameSession.adventure.active_session == null or GameSession.adventure.active_session.context != context:
		transition_failed.emit("No authorized expedition context")
		return false
	var definition := ContentRegistry.get_definition(context.region_id) as RegionDefinition
	if definition == null:
		transition_failed.emit("Unknown region: %s" % context.region_id)
		return false
	return _replace_world(definition.scene_path, context.region_id, context)

func _replace_world(scene_path: String, destination: StringName, context: AdventureContext) -> bool:
	if not is_instance_valid(_world_layer):
		transition_failed.emit("World layer is not registered")
		return false
	transition_started.emit(destination)
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		transition_failed.emit("Cannot load scene: %s" % scene_path)
		return false
	for child in _world_layer.get_children():
		child.process_mode = Node.PROCESS_MODE_DISABLED
		_world_layer.remove_child(child)
		child.queue_free()
	var instance := packed.instantiate()
	if context != null and instance.has_method("configure"):
		instance.configure(context)
	if destination == &"settlement":
		GameSession.complete_respawn()
	_world_layer.add_child(instance)
	transition_finished.emit(destination)
	return true
