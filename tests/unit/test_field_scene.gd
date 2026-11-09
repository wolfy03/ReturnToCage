extends RefCounted

func run(t: Node) -> void:
	var definition := ContentRegistry.get_definition(&"sewer_region") as RegionDefinition
	var packed := load(definition.scene_path) as PackedScene
	var scene := packed.instantiate() as Node2D
	t.assert_true(definition.validate_scene(scene, ContentRegistry).is_empty(), "authored sewer scene validates before entering tree")
	var expected := {
		"Floor": [Vector2(750, 570), Vector2(1600, 70)],
		"WestPlatform": [Vector2(420, 440), Vector2(240, 22)],
		"MidPlatform": [Vector2(760, 350), Vector2(210, 22)],
		"EastPlatform": [Vector2(1080, 450), Vector2(230, 22)]
	}
	t.assert_equal(scene.get_node("Terrain").get_child_count(), 4, "four platforms are authored exactly once")
	for platform in expected:
		var body := scene.get_node("Terrain/" + platform) as StaticBody2D
		var collision := body.get_node("CollisionShape2D") as CollisionShape2D
		t.assert_equal(body.position, expected[platform][0], "authored platform position " + platform)
		t.assert_equal((collision.shape as RectangleShape2D).size, expected[platform][1], "authored platform size " + platform)
		t.assert_equal(Vector2i(body.collision_layer, body.collision_mask), Vector2i(1, 1), "authored platform collision bits")
		t.assert_true(not collision.one_way_collision, "original platforms remain solid")
	t.assert_true(scene.get_node("Landing/CollisionShape2D").one_way_collision, "ladder landing remains one-way")
	var enemy := scene.get_node("SpawnPoints/SewerBeetle") as FieldEnemySpawnPoint
	t.assert_equal([enemy.enemy_id, enemy.position], [&"sewer_beetle", Vector2(970, 525)], "original enemy placement preserved")
	var gathers := {
		"ScrapCacheA": [&"scrap_cache_a", &"rusty_scrap", 2, Vector2(430, 395)],
		"ScrapCacheB": [&"scrap_cache_b", &"rusty_scrap", 2, Vector2(760, 305)],
		"BerryDrop": [&"berry_drop", &"berry", 1, Vector2(1070, 405)]
	}
	for marker_name in gathers:
		var gather := scene.get_node("GatherPoints/" + marker_name) as FieldGatherPoint
		t.assert_equal([gather.interaction_id, gather.item_id, gather.amount, gather.position], gathers[marker_name], "original gather placement preserved")
	var first := scene.get_node("GatherPoints/ScrapCacheA") as FieldGatherPoint
	first.position += Vector2(10, 5)
	first.amount = 7
	first.enabled = false
	var copy := PackedScene.new()
	t.assert_equal(copy.pack(scene), OK, "edited field packs")
	var path := "user://field_scene_roundtrip.tscn"
	t.assert_equal(ResourceSaver.save(copy, path), OK, "edited field saves as tscn")
	var reloaded := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var copy_scene := reloaded.instantiate()
	var copy_gather := copy_scene.get_node("GatherPoints/ScrapCacheA") as FieldGatherPoint
	t.assert_equal([copy_gather.position, copy_gather.amount, copy_gather.enabled], [first.position, 7, false], "saved field reload preserves edits")
	var original := packed.instantiate()
	t.assert_equal(original.get_node("GatherPoints/ScrapCacheA").amount, 2, "editing a field copy preserves original")
	original.free()
	copy_scene.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	var duplicate := enemy.duplicate() as FieldEnemySpawnPoint
	duplicate.enemy_id = &"berry"
	enemy.get_parent().add_child(duplicate)
	var second := scene.get_node("GatherPoints/ScrapCacheB") as FieldGatherPoint
	second.interaction_id = first.interaction_id
	second.item_id = &"sewer_beetle"
	second.amount = 0
	var entry := scene.get_node("Entry") as RegionPoint
	entry.point_id = &"unexpected"
	var errors := "\n".join(definition.validate_scene(scene, ContentRegistry))
	for message in ["duplicate or empty enemy spawn ID", "invalid spawn enemy ID", "duplicate or empty gather ID", "invalid gather item ID", "nonpositive gather amount", "missing scene entry marker", "undeclared scene entry marker"]:
		t.assert_true(errors.contains(message), "field validation detects " + message)
	scene.free()
