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
	_finish(valid)

func _finish(valid: bool) -> void:
	print("AUTHORED FIELD RUNTIME ", "PASS" if valid else "FAIL")
	get_tree().quit(0 if valid else 1)
