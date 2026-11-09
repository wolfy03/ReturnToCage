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
	valid = valid and presentation.get_node("Decorations").get_child(0).get_child_count(true) == 1
	presentation.queue_free()
	await get_tree().process_frame

	var authority := packed.instantiate()
	authority.configure_server_runtime(&"adventure:sewer_region", &"sewer_region")
	add_child(authority)
	valid = valid and authority.get_node("EnemySpawnManager")._enemies.size() == 2
	valid = valid and authority._gather_targets.has(&"rusty_scrap_gather_1")
	for marker in authority.get_node("Decorations").get_children():
		valid = valid and marker.get_child_count(true) == 0
	authority.queue_free()
	await get_tree().process_frame
	_finish(valid)

func _finish(valid: bool) -> void:
	print("AUTHORED FIELD RUNTIME ", "PASS" if valid else "FAIL")
	get_tree().quit(0 if valid else 1)
