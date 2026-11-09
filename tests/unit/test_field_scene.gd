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
	t.assert_true(errors.contains("SpawnPoints/SewerBeetle and SpawnPoints/"), "enemy duplicate identifies both nodes")
	t.assert_true(errors.contains("GatherPoints/ScrapCacheA and GatherPoints/ScrapCacheB"), "gather duplicate identifies both nodes")
	scene.free()
	_test_structure(t, definition, packed)

func _test_structure(t: Node, definition: RegionDefinition, packed: PackedScene) -> void:
	var scene := packed.instantiate() as Node2D
	var manager := scene.get_node("PlayerSpawnManager") as PlayerSpawnManager
	manager.spawn_validation_collision_mask = 0
	t.assert_true("\n".join(definition.validate_scene(scene, ContentRegistry)).contains("nonzero spawn collision mask"), "invalid adventure spawn configuration reported")
	manager.spawn_validation_collision_mask = 1
	var slot := scene.get_node("PlayerSpawnPoint1") as PlayerSpawnPoint
	slot.spawn_index = 0
	var errors := "\n".join(definition.validate_scene(scene, ContentRegistry))
	t.assert_true(errors.contains("duplicate player spawn index 0 at PlayerSpawnPoint0 and PlayerSpawnPoint1"), "duplicate player slots identify both nodes")
	slot.spawn_index = 4
	t.assert_true("\n".join(definition.validate_scene(scene, ContentRegistry)).contains("index 4 outside"), "out of range player slot rejected")
	slot.spawn_index = 1
	var terrain := scene.get_node("Terrain") as Node2D
	slot.owner = null
	slot.reparent(terrain, false)
	t.assert_true("\n".join(definition.validate_scene(scene, ContentRegistry)).contains("Terrain/PlayerSpawnPoint1: nested player spawn"), "ignored nested slot reported")
	slot.reparent(scene, false)
	var entry := scene.get_node("Entry") as RegionPoint
	entry.owner = null
	entry.reparent(terrain, false)
	terrain.position = Vector2(12, 24)
	t.assert_true(definition.validate_scene(scene, ContentRegistry).is_empty(), "valid slots and transformed nested ENTRY accepted")
	entry.position = Vector2(INF, 3)
	var ladder := scene.get_node("EmergencyLadder") as ClimbableArea2D
	var top := ladder.top_marker
	ladder.top_marker = null
	ladder.get_node("CollisionShape2D").disabled = true
	var platform := preload("res://world/adventure/field_platform.tscn").instantiate() as FieldPlatform
	platform.name = "BrokenPlatform"
	platform.get_node("CollisionShape2D").free()
	terrain.add_child(platform)
	var decoration := FieldDecoration.new()
	decoration.name = "BrokenDecoration"
	decoration.asset_path = "res://missing_field_texture.png"
	scene.add_child(decoration)
	errors = "\n".join(definition.validate_scene(scene, ContentRegistry))
	for message in ["Terrain/Entry: non-finite", "EmergencyLadder: climbable requires Top and Bottom", "EmergencyLadder: climbable requires an enabled CollisionShape2D", "Terrain/BrokenPlatform: FieldPlatform requires an enabled", "BrokenDecoration: missing or invalid decoration asset path"]:
		t.assert_true(errors.contains(message), "structural field validation detects " + message)
	ladder.top_marker = top
	top.position.y = ladder.bottom_marker.position.y + 1
	t.assert_true("\n".join(definition.validate_scene(scene, ContentRegistry)).contains("Top must be above Bottom"), "inverted climb endpoints rejected")
	decoration.asset_path = "res://world/adventure/field_platform.tscn"
	errors = "\n".join(RegionDefinition.validate_field_nodes(definition, scene, ContentRegistry))
	t.assert_true(errors.contains("scripted decoration scene node"), "scripted decoration scene rejected without instantiation")
	var resource_path := (ContentRegistry.get_item(&"berry") as Resource).resource_path
	t.assert_true(FieldDecoration.asset_issue(resource_path).contains("unsupported decoration resource"), "nonvisual resource rejected")
	var visual_root := Node2D.new()
	var child := preload("res://world/decorations/sewer_wall_mark.tscn").instantiate()
	visual_root.add_child(child)
	child.owner = visual_root
	var visual := PackedScene.new()
	visual.pack(visual_root)
	t.assert_true(FieldDecoration.visual_scene_issue(visual).contains("nested or inherited"), "nested decoration instance rejected")
	visual_root.free()
	scene.free()
