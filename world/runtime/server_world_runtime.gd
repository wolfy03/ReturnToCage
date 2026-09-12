class_name ServerWorldRuntime
extends Node

var model: WorldRuntime
var runtime_scene: Node2D
var _viewport: SubViewport

func configure(p_model: WorldRuntime, scene_path: String) -> bool:
	if model != null or p_model == null or not p_model.is_valid() \
			or scene_path.is_empty() or not ResourceLoader.exists(scene_path):
		return false
	var packed := ResourceLoader.load(scene_path) as PackedScene
	if packed == null:
		return false
	var instance := packed.instantiate() as Node2D
	if instance == null:
		return false
	model = p_model
	name = "Runtime_%s" % String(model.world_id).replace(":", "_")
	_viewport = SubViewport.new()
	_viewport.name = "PhysicsWorld"
	_viewport.disable_3d = true
	_viewport.world_2d = World2D.new()
	_viewport.size = Vector2i(1600, 720)
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	runtime_scene = instance
	if runtime_scene.has_method("configure_server_runtime"):
		runtime_scene.call("configure_server_runtime", model.world_id, model.region_id)
	_viewport.add_child(runtime_scene)
	return true

func participant_peer_ids() -> Array[int]:
	return GameSession.peer_ids_in_world(model.world_id) if model != null else []

func enemy_manager() -> EnemySpawnManager:
	return runtime_scene.get_node_or_null("EnemySpawnManager") as EnemySpawnManager if runtime_scene != null else null

func loot_manager() -> LootSpawnManager:
	return runtime_scene.get_node_or_null("LootSpawnManager") as LootSpawnManager if runtime_scene != null else null

func player_manager() -> PlayerSpawnManager:
	return runtime_scene.get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager if runtime_scene != null else null
