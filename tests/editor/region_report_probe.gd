extends "res://tests/editor/field_runtime_probe.gd"

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var mode := args[0]
	var region := (ContentRegistry.get_definition(&"step5_flat") as RegionDefinition).duplicate() as RegionDefinition
	var packed := load(region.scene_path) as PackedScene
	var scene := packed.instantiate()
	match mode:
		"normal":
			for node in scene.get_children():
				if node is PlayerSpawnPoint:
					node.position.y -= 10
			scene.get_node("RegionPoints/Entry").position.y -= 10
		"warn":
			scene.get_node("PlayerSpawnPoint3").free()
		"blocked":
			scene.get_node("RegionPoints/Entry").position = Vector2(150, 565)
		"slot":
			scene.get_node("PlayerSpawnPoint1").spawn_index = 0
		_:
			get_tree().quit(1)
			return
	packed = PackedScene.new()
	if packed.pack(scene) != OK:
		get_tree().quit(1)
		return
	scene.free()
	region.scene_path = "user://report_fixture.tscn"
	if ResourceSaver.save(packed, region.scene_path) != OK:
		get_tree().quit(1)
		return
	ContentRegistry._definitions[region.id] = region
	var valid := await _playtest_region(region.id)
	var expected := valid if mode in ["normal", "warn"] else not valid
	if mode == "blocked":
		expected = expected and _playtest_results.any(func(item: Dictionary) -> bool:
			return item.stage == "ENTRY Physical Anchor" and item.status == "FAIL" and item.detail.contains("Terrain/") and item.detail.contains("/CollisionShape2D"))
	print("REGION REPORT FIXTURE ", mode, " ", "PASS" if expected else "FAIL")
	get_tree().quit(0 if expected else 1)
