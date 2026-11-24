extends RefCounted

const THEMES := ["forest_grass_dirt", "forest_soil", "forest_tree_root", "forest_fallen_log"]

func run(t: Node) -> void:
	var definition := ContentRegistry.get_definition(&"forest_region") as RegionDefinition
	t.assert_true(definition != null, "forest region is registered")
	if definition == null:
		return
	t.assert_true(definition.validate_definition(ContentRegistry).is_empty(), "forest region definition validates")
	var scene := (load(definition.scene_path) as PackedScene).instantiate() as Node2D
	t.assert_true(definition.validate_scene(scene, ContentRegistry).is_empty(), "authored forest scene validates before entering tree")
	for group in ["Terrain", "Decorations", "SpawnPoints", "GatherPoints", "RegionPoints", "Climbables"]:
		t.assert_true(scene.get_node_or_null(group) is Node2D, "forest keeps the scaffold group " + group)
	var used: Dictionary[String, bool] = {}
	var one_way_count := 0
	for child in scene.get_node("Terrain").get_children():
		var platform := child as FieldPlatform
		t.assert_true(platform != null and platform.has_terrain(), "forest terrain uses a nine-slice FieldPlatform: " + String(child.name))
		if platform == null:
			continue
		t.assert_equal(Vector2i(platform.collision_layer, platform.collision_mask), Vector2i(1, 1), "forest platform collision bits " + String(child.name))
		t.assert_equal(platform.terrain_texture.resource_path, "res://assets/terrain/%s.png" % platform.terrain_theme, "theme and texture agree " + String(child.name))
		used[platform.terrain_theme] = true
		one_way_count += 1 if platform.one_way else 0
	for theme in THEMES:
		t.assert_true(used.has(theme), "forest uses terrain theme " + theme)
		t.assert_true(FileAccess.file_exists("res://assets/terrain/%s.json" % theme), "terrain metadata exists for " + theme)
	t.assert_true(one_way_count >= 4, "forest has jump-through platforms for the upper route")
	var ground := scene.get_node("Terrain/GroundWest") as FieldPlatform
	var ground_top := ground.position.y - ground.size.y / 2.0
	var slots := 0
	for child in scene.get_children():
		if child is PlayerSpawnPoint:
			slots += 1
			t.assert_true(child.position.y < ground_top and ground_top - child.position.y <= 100.0, "player spawn stands above the trail ground")
	t.assert_equal(slots, NetworkManager.MAX_PLAYERS, "forest authors every player spawn slot")
	var spawn_count := 0
	for marker in scene.get_node("SpawnPoints").get_children():
		var spawn := marker as FieldEnemySpawnPoint
		spawn_count += 1
		t.assert_true(spawn != null and definition.enemy_ids.has(spawn.enemy_id), "forest spawn uses a declared enemy: " + String(marker.name))
	t.assert_true(spawn_count >= 2, "forest places enemies")
	scene.free()
	var gate := ContentRegistry.get_definition(&"forest_gate") as SettlementExitDefinition
	t.assert_true(gate != null and not gate.development_locked and gate.connected_region_ids == [&"forest_region"] \
		and definition.entry_point_ids.has(gate.entry_point_id), "settlement forest gate leads to the forest entry")
	var start := ContentRegistry.get_definition(&"default_game_start") as GameStartDefinition
	t.assert_true(start.unlocked_regions.has(&"forest_region") and start.unlocked_exits.has(&"forest_gate"), "new games can use the forest gate")
	t.assert_true((ContentRegistry.get_definition(&"field_gate") as SettlementExitDefinition).development_locked, "the development field gate stays locked")
	var environment := ResourceLoader.load(definition.environment_path) as EnvironmentDefinition
	t.assert_true(environment != null and environment.layers.size() == 3, "forest environment has far, middle and near layers")
	if environment != null and environment.layers.size() == 3:
		var names: Array[StringName] = []
		for layer in environment.layers:
			names.append(layer.layer_name)
			t.assert_true(layer.texture != null and layer.z_index <= -100, "forest layer draws behind gameplay: " + String(layer.layer_name))
		t.assert_equal(names, [&"far", &"mid", &"near"] as Array[StringName], "forest layers are ordered back to front")
		t.assert_true(environment.layers[0].scroll_scale.x < environment.layers[1].scroll_scale.x \
			and environment.layers[1].scroll_scale.x < environment.layers[2].scroll_scale.x, "nearer forest layers scroll faster")
