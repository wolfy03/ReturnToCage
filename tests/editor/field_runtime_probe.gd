extends Node

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	GameSession.start_new_game()
	var context := GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	var packed := load("res://tests/field_editor_probe_scene.tscn") as PackedScene
	if context == null or packed == null:
		_finish(false)
		return
	var presentation := packed.instantiate()
	presentation.configure(context)
	add_child(presentation)
	var valid: bool = presentation.get_node("EnemySpawnManager")._enemies.size() == 2
	valid = valid and presentation._gather_targets.has(&"rusty_scrap_gather_1")
	var decorations := presentation.get_node("Decorations")
	valid = valid and decorations.get_child_count() >= 6
	for decoration in decorations.get_children():
		valid = valid and decoration.get_child_count(true) == 1
	presentation.queue_free()
	await get_tree().process_frame

	var authority := packed.instantiate()
	authority.configure_server_runtime(&"adventure:sewer_region", &"sewer_region")
	add_child(authority)
	valid = valid and authority.get_node("EnemySpawnManager")._enemies.size() == 2
	valid = valid and authority._gather_targets.has(&"rusty_scrap_gather_1")
	var rectangle: FieldPlatform
	for platform in authority.get_node("Terrain").get_children():
		if platform is FieldPlatform and platform.size == Vector2(64, 32):
			var collision := platform.get_node("CollisionShape2D") as CollisionShape2D
			if collision.shape.size == platform.size and not collision.disabled and platform.visible:
				rectangle = platform
		await get_tree().physics_frame
	await get_tree().physics_frame
	var hits_rectangle := false
	if rectangle != null:
		var query := PhysicsPointQueryParameters2D.new()
		query.position = rectangle.global_position
		query.collision_mask = 1
		for hit in rectangle.get_world_2d().direct_space_state.intersect_point(query):
			if hit.get("collider") == rectangle:
				hits_rectangle = true
	valid = valid and hits_rectangle
	for marker in authority.get_node("Decorations").get_children():
		valid = valid and marker.get_child_count(true) == 0
	authority.queue_free()
	await get_tree().process_frame
	_finish(valid and await _generated_region())

func _generated_region() -> bool:
	GameSession.start_new_game()
	var region := ContentRegistry.get_definition(&"step5_flat") as RegionDefinition
	if region == null or not ContentRegistry.get_definition(&"step5_empty") is RegionDefinition or not ContentRegistry.get_definition(&"step5_platform") is RegionDefinition:
		return false
	var exit := SettlementExitDefinition.new()
	exit.id = &"step5_test_exit"
	exit.connected_region_ids = [region.id]
	exit.entry_point_id = region.entry_point_ids[0]
	ContentRegistry._definitions[exit.id] = exit
	GameSession.progression.unlocked_regions.append(region.id)
	GameSession.progression.unlocked_exits.append(exit.id)
	var context := GameSession.begin_adventure(exit.id, region.id, exit.entry_point_id)
	var packed := load(region.scene_path) as PackedScene
	if context == null or packed == null:
		return false
	var layer := Node2D.new()
	add_child(layer)
	SceneRouter.register_world_layer(layer)
	if not SceneRouter.go_to_adventure(context):
		SceneRouter.register_world_layer(null)
		layer.queue_free()
		return false
	var presentation := layer.get_child(0)
	var valid: bool = SceneRouter.current_world_id() == PlayerWorldState.adventure_world_id(region.id)
	valid = valid and presentation.get_node("Decorations").get_child_count() == 2
	for decoration in presentation.get_node("Decorations").get_children():
		valid = valid and decoration.get_child_count(true) == 1
	SceneRouter.clear_presented_world()
	SceneRouter.register_world_layer(null)
	layer.queue_free()
	await get_tree().process_frame
	var authority := packed.instantiate()
	authority.configure_server_runtime(PlayerWorldState.adventure_world_id(region.id), region.id)
	add_child(authority)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var peer := GameSession.get_local_peer_id()
	var manager := authority.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var actor := manager.get_actor(peer)
	valid = valid and actor != null and actor.global_position.x >= 150 and actor.global_position.x <= 294
	valid = valid and authority.get_node("EnemySpawnManager")._enemies.size() == 2 and authority._gather_targets.size() == 2
	if actor != null and not authority._gather_targets.is_empty():
		var id: StringName = authority._gather_targets.keys()[0]
		actor.global_position = authority._gather_targets[id].global_position
		valid = authority._try_gather(peer, id) and not authority._try_gather(peer, id) and valid
	for decoration in authority.get_node("Decorations").get_children():
		valid = valid and decoration.get_child_count(true) == 0
	var climbs := authority.get_node("Climbables").get_children()
	valid = valid and climbs.size() == 2
	for node in climbs:
		var climb := node as ClimbableArea2D
		var shape := climb.get_node_or_null("CollisionShape2D") as CollisionShape2D
		valid = valid and climb.top_marker.global_position.y < climb.bottom_marker.global_position.y and shape.shape is RectangleShape2D and not shape.disabled

	var query := PhysicsPointQueryParameters2D.new()
	query.position = Vector2(600, 565)
	query.collision_mask = 1
	valid = valid and not authority.get_world_2d().direct_space_state.intersect_point(query).is_empty()
	authority.queue_free()
	await get_tree().process_frame
	print("GENERATED REGION RUNTIME ", "PASS" if valid else "FAIL")
	return valid

func _finish(valid: bool) -> void:
	print("AUTHORED FIELD RUNTIME ", "PASS" if valid else "FAIL")
	get_tree().quit(0 if valid else 1)
