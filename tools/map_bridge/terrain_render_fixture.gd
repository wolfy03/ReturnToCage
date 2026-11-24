extends SceneTree
## Isolated rendered fixture with real FieldPlatform instances.

const PlatformScript := preload("res://world/adventure/field_platform.gd")
const PLATFORM := preload("res://world/adventure/field_platform.tscn")

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var destination := OS.get_cmdline_user_args()[0]
	var cases: Array = JSON.parse_string(FileAccess.get_file_as_string(destination.path_join("cases.json")))
	var viewport := SubViewport.new()
	viewport.disable_3d = true
	viewport.transparent_bg = true
	root.add_child(viewport)
	for index in range(cases.size()):
		var fixture: Dictionary = cases[index]
		var platform := PLATFORM.instantiate() as PlatformScript
		viewport.size = Vector2i(int(fixture.canvas[0]), int(fixture.canvas[1]))
		platform.size = Vector2(float(fixture.size[0]), float(fixture.size[1]))
		platform.position = Vector2(viewport.size) / 2.0
		platform.rotation_degrees = fixture.rotation
		platform.one_way = fixture.one_way
		platform.collision_layer = 5
		platform.collision_mask = 9
		viewport.add_child(platform)
		var collision := platform.get_node("CollisionShape2D") as CollisionShape2D
		var baseline: Vector2 = collision.shape.size
		var shape: Shape2D = collision.shape
		platform.terrain_theme = fixture.theme_id
		var texture := Image.new()
		if texture.load("res://" + String(fixture.texture_path)) != OK:
			push_error("terrain fixture PNG load failed")
			quit(1)
			return
		platform.terrain_texture = ImageTexture.create_from_image(texture)
		var m: Array = fixture.margins
		platform.terrain_margins = Vector4i(int(m[0]), int(m[1]), int(m[2]), int(m[3]))
		if not platform.has_terrain() or platform.get_child_count() != 2 or collision.shape != shape \
			or collision.shape.size != baseline or collision.one_way_collision != platform.one_way \
			or platform.collision_layer != 5 or platform.collision_mask != 9:
			push_error("terrain fixture modified collision")
			quit(1)
			return
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		var rendered := viewport.get_texture().get_image()
		if rendered == null or rendered.save_png(destination.path_join("godot-%d.png" % index)) != OK:
			push_error("terrain fixture capture failed")
			quit(1)
			return
		platform.size += Vector2(37, 19)
		if collision.shape.size != baseline + Vector2(37, 19) or not platform.has_terrain() \
			or collision.one_way_collision != platform.one_way:
			push_error("resized terrain lost collision alignment")
			quit(1)
			return
		platform.free()
	viewport.free()
	print("TERRAIN RENDER PASS")
	quit()
