extends RefCounted
## What the map bridge stores for a FieldPlatform whose children live in the
## scene itself. None of these platforms ever enters the tree, so _ready() never
## runs: the assertions read stored data, not geometry repaired at load time.

const Contract := preload("res://tools/map_bridge/scene_contract.gd")
const PlatformScript := preload("res://world/adventure/field_platform.gd")
const TEXTURE := preload("res://assets/terrain/sewer_concrete.png")

func run(t: Node) -> void:
	_test_independent_reconciliation(t)
	_test_shared_shape_and_instances(t)
	_test_saved_scene(t)

func _platform(root: Node2D, name: String, size: Vector2, shape: RectangleShape2D, polygon: PackedVector2Array) -> FieldPlatform:
	var platform := StaticBody2D.new()
	platform.set_script(PlatformScript)
	platform.name = name
	root.add_child(platform)
	platform.owner = root
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	collision.shape = shape
	platform.add_child(collision)
	collision.owner = root
	var visual := Polygon2D.new()
	visual.name = "Visual"
	visual.polygon = polygon
	platform.add_child(visual)
	visual.owner = root
	(platform as FieldPlatform).size = size
	return platform as FieldPlatform

func _shape(size: Vector2) -> RectangleShape2D:
	var shape := RectangleShape2D.new()
	shape.size = size
	return shape

func _stored(platform: FieldPlatform) -> Array:
	var collision := platform.get_node("CollisionShape2D") as CollisionShape2D
	return [(collision.shape as RectangleShape2D).size, (platform.get_node("Visual") as Polygon2D).polygon, collision.one_way_collision]

func _test_independent_reconciliation(t: Node) -> void:
	var root := Node2D.new()
	var size := Vector2(256, 22)
	var good := FieldPlatform.rectangle_polygon(size)
	var stale := FieldPlatform.rectangle_polygon(Vector2(240, 22))
	var cases := {
		"both correct": [_shape(size), good],
		"collision wrong": [_shape(Vector2(240, 22)), good],
		"visual wrong": [_shape(size), stale],
		"both wrong": [_shape(Vector2(240, 22)), stale],
	}
	for label: String in cases:
		var platform := _platform(root, label.replace(" ", "_"), size, cases[label][0], cases[label][1])
		Contract.sync_platform_children(platform)
		t.assert_equal(_stored(platform), [size, good, false], "stored platform geometry agrees with its size: " + label)
	var untouched := _platform(root, "untouched", size, _shape(size), good)
	var shape_before := (untouched.get_node("CollisionShape2D") as CollisionShape2D).shape
	Contract.sync_platform_children(untouched)
	t.assert_true((untouched.get_node("CollisionShape2D") as CollisionShape2D).shape == shape_before,
		"a platform that already agrees keeps its own shape resource")
	var half := size / 2.0
	var rotated := PackedVector2Array([half, Vector2(-half.x, half.y), -half, Vector2(half.x, -half.y)])
	var authored := _platform(root, "authored_order", size, _shape(size), rotated)
	Contract.sync_platform_children(authored)
	t.assert_equal((authored.get_node("Visual") as Polygon2D).polygon, rotated,
		"a correct rectangle that starts at another corner is not rewritten")
	var one_way := _platform(root, "one_way", size, _shape(size), good)
	one_way.one_way = true
	Contract.sync_platform_children(one_way)
	t.assert_equal(_stored(one_way), [size, good, true], "one-way is stored without touching correct geometry")
	one_way.one_way = false
	Contract.sync_platform_children(one_way)
	t.assert_true(not (one_way.get_node("CollisionShape2D") as CollisionShape2D).one_way_collision, "one-way is cleared again")
	root.free()

func _test_shared_shape_and_instances(t: Node) -> void:
	var root := Node2D.new()
	var shared := _shape(Vector2(240, 22))
	var outline := FieldPlatform.rectangle_polygon(Vector2(240, 22))
	var first := _platform(root, "first", Vector2(240, 22), shared, outline)
	var second := _platform(root, "second", Vector2(240, 22), shared, outline)
	first.size = Vector2(300, 22)
	Contract.sync_platform_children(first)
	t.assert_equal(_stored(first)[0], Vector2(300, 22), "the resized platform stores its new collision size")
	t.assert_true(shared.size == Vector2(240, 22) and (second.get_node("CollisionShape2D") as CollisionShape2D).shape == shared,
		"resizing one platform leaves a shape it shared with another untouched")
	# Children that belong to an instanced platform scene are not stored with the
	# edited scene, so the bridge must leave them alone.
	var instance := preload("res://world/adventure/field_platform.tscn").instantiate() as FieldPlatform
	root.add_child(instance)
	instance.owner = root
	var before := _stored(instance)
	instance.size = Vector2(300, 40)
	Contract.sync_platform_children(instance)
	t.assert_equal(_stored(instance), before, "children of an instanced platform scene are not rewritten")
	root.free()

func _test_saved_scene(t: Node) -> void:
	var root := Node2D.new()
	root.name = "Fixture"
	var size := Vector2(256, 22)
	var platform := _platform(root, "Textured", Vector2(240, 22), _shape(Vector2(240, 22)), FieldPlatform.rectangle_polygon(Vector2(240, 22)))
	platform.terrain_theme = "sewer_concrete"
	platform.terrain_texture = TEXTURE
	platform.terrain_margins = Vector4i(7, 6, 9, 5)
	platform.collision_layer = 1
	platform.collision_mask = 1
	platform.size = size
	Contract.sync_platform_children(platform)
	var packed := PackedScene.new()
	t.assert_equal(packed.pack(root), OK, "the edited fixture packs")
	root.free()
	var path := "user://map_bridge_platform_sync_test.tscn"
	t.assert_equal(ResourceSaver.save(packed, path), OK, "the edited fixture saves through ResourceSaver")
	var reloaded := (ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var stored := reloaded.get_node("Textured") as FieldPlatform
	t.assert_true(not stored.is_node_ready(), "the reloaded platform has not run _ready")
	t.assert_equal(_stored(stored), [size, FieldPlatform.rectangle_polygon(size), false],
		"a saved and reloaded scene already holds the resized collision and visual")
	t.assert_equal([stored.size, stored.terrain_theme, stored.terrain_texture, stored.terrain_margins, stored.collision_layer, stored.collision_mask],
		[size, "sewer_concrete", TEXTURE, Vector4i(7, 6, 9, 5), 1, 1], "terrain theme, texture, margins and collision bits survive the resize")
	reloaded.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
