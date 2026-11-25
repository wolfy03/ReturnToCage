extends RefCounted
## Gather points are drawn as the item they give, using the same temporary
## category sprite as dropped loot, and only where something is drawn at all.

const SEWER_SCENE := "res://world/adventure/sewer_region.tscn"
const SEWER_WORLD: StringName = &"adventure:sewer_region"
const EXPECTED_FILES := {
	ItemDisplayCategory.Kind.EQUIPMENT: "temp_equipment_item_img.png",
	ItemDisplayCategory.Kind.CONSUMABLE: "temp_usable_item_img.png",
	ItemDisplayCategory.Kind.OTHER: "temp_etc_item_img.png",
	ItemDisplayCategory.Kind.QUEST: "temp_quest_item_img.png",
}

func run(t: Node) -> void:
	_test_every_item_has_a_world_texture(t)
	await _test_visible_region_draws_gather_points_as_items(t)
	await _test_server_runtime_creates_no_item_sprite(t)

func _test_every_item_has_a_world_texture(t: Node) -> void:
	var seen: Dictionary[ItemDisplayCategory.Kind, bool] = {}
	for definition in ContentRegistry.all_definitions():
		var item := definition as ItemDefinition
		if item == null:
			continue
		var texture := LootActor.display_texture_for(item)
		var category := ItemDisplayCategory.for_item(item)
		seen[category] = true
		t.assert_true(texture != null, "%s has a world texture" % item.id)
		if texture != null and item.icon == null:
			t.assert_equal(texture.resource_path.get_file(), EXPECTED_FILES[category],
				"%s uses the temporary sprite of its category" % item.id)
	t.assert_true(seen.has(ItemDisplayCategory.Kind.EQUIPMENT) and seen.has(ItemDisplayCategory.Kind.CONSUMABLE)
		and seen.has(ItemDisplayCategory.Kind.OTHER), "shipped items cover equipment, consumable and other")

func _test_visible_region_draws_gather_points_as_items(t: Node) -> void:
	GameSession.start_new_game()
	var region: Variant = (load(SEWER_SCENE) as PackedScene).instantiate()
	region.configure(AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", GameSession.difficulty.id, GameSession.session_id))
	t.add_child(region)
	await t.get_tree().process_frame
	var markers: Dictionary[StringName, FieldGatherPoint] = {}
	for node in region.find_children("*", "Marker2D", true, false):
		var marker := node as FieldGatherPoint
		if marker != null and marker.enabled:
			markers[marker.interaction_id] = marker
	var targets: Array[InteractionTarget] = []
	for node in t.get_tree().get_nodes_in_group(&"world_gather"):
		if region.is_ancestor_of(node):
			targets.append(node as InteractionTarget)
	t.assert_true(markers.size() >= 2 and targets.size() == markers.size(), "every enabled gather marker becomes a target")
	var categories: Dictionary[ItemDisplayCategory.Kind, bool] = {}
	for target in targets:
		var marker: FieldGatherPoint = markers.get(target.interaction_id)
		var item := ContentRegistry.get_item(marker.item_id) if marker != null else null
		var sprite := target.get_node_or_null("ItemVisual") as Sprite2D
		t.assert_true(item != null and sprite != null and sprite.visible and sprite.texture != null,
			"gather point %s is drawn with an item sprite" % target.interaction_id)
		if item == null or sprite == null or sprite.texture == null:
			continue
		var category := ItemDisplayCategory.for_item(item)
		categories[category] = true
		t.assert_equal(sprite.texture, LootActor.display_texture_for(item),
			"gather point %s uses the texture dropped %s uses" % [target.interaction_id, item.id])
		t.assert_equal(sprite.texture.resource_path.get_file(), EXPECTED_FILES[category],
			"gather point %s shows the sprite of its item's category" % target.interaction_id)
		var drawn := sprite.texture.get_size() * sprite.scale
		t.assert_true(maxf(drawn.x, drawn.y) <= FieldGatherPoint.TARGET_SIZE.x + 0.01 and minf(drawn.x, drawn.y) > 8.0,
			"gather sprite fits inside the interaction target")
		for child in target.get_children():
			if child is Polygon2D:
				t.assert_true(not (child as Polygon2D).visible, "placeholder polygon is hidden once the sprite exists")
		var shapes := target.find_children("*", "CollisionShape2D", false, false)
		var shape := (shapes[0] as CollisionShape2D).shape as RectangleShape2D if shapes.size() == 1 else null
		t.assert_true(shape != null and shape.size == FieldGatherPoint.TARGET_SIZE,
			"the sprite does not change the interaction area")
	t.assert_true(categories.size() >= 2, "the sewer shows gather points of at least two item categories")
	region.queue_free()
	await t.get_tree().process_frame

func _test_server_runtime_creates_no_item_sprite(t: Node) -> void:
	GameSession.start_new_game()
	var server: Variant = (load(SEWER_SCENE) as PackedScene).instantiate()
	server.configure_server_runtime(SEWER_WORLD, &"sewer_region")
	t.add_child(server)
	await t.get_tree().process_frame
	var count := 0
	for node in t.get_tree().get_nodes_in_group(&"world_gather"):
		if server.is_ancestor_of(node):
			count += 1
			t.assert_true(node.get_node_or_null("ItemVisual") == null, "server runtime gather point has no item sprite")
	t.assert_true(count >= 2, "server runtime still creates the gather targets")
	t.assert_true(server.find_children("*", "Sprite2D", true, false).filter(
		func(node: Node) -> bool: return node.name == "ItemVisual").is_empty(), "server runtime region holds no gather sprite")
	server.queue_free()
	await t.get_tree().process_frame
