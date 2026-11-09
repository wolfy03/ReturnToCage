@tool
extends "res://addons/rtc_field_editor/plugin.gd"

var _overlay: Control
var _failures: int = 0

func _enter_tree() -> void:
	super()
	_run.call_deferred()

func _forward_canvas_force_draw_over_viewport(overlay: Control) -> void:
	_overlay = overlay
	super(overlay)

func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	_check(not _place({"kind": "platform"}, Vector2.ZERO), "no field rejects placement")
	for frame in 600:
		await get_tree().process_frame
		if _field_root() != null and not _catalog.entries.is_empty():
			break
	EditorInterface.set_main_screen_editor("2D")
	var root := _field_root()
	if root == null:
		_check(false, "probe field opened")
		get_tree().quit(1)
		return
	var definition := _catalog.get_definition(&"sewer_region") as RegionDefinition
	_check(RegionDefinition.validate_field_nodes(definition, root, _catalog).is_empty(), "editor validates the unmodified field")
	var slot := root.get_node("PlayerSpawnPoint1") as PlayerSpawnPoint
	var undo := get_undo_redo()
	undo.create_action("Probe duplicate player slot", UndoRedo.MERGE_DISABLE, root)
	undo.add_do_property(slot, "spawn_index", 0)
	undo.add_undo_property(slot, "spawn_index", 1)
	undo.commit_action()
	var slot_history := undo.get_history_undo_redo(undo.get_object_history_id(root))
	var duplicate_errors := RegionDefinition.validate_field_nodes(definition, root, _catalog)
	_check("\n".join(duplicate_errors).contains("PlayerSpawnPoint0 and PlayerSpawnPoint1"), "editor validation identifies duplicate slot")
	_check(slot_history.undo() and RegionDefinition.validate_field_nodes(definition, root, _catalog).is_empty(), "undo clears duplicate validation")
	_check(slot_history.redo() and RegionDefinition.validate_field_nodes(definition, root, _catalog) == duplicate_errors, "redo restores identical diagnostics")
	_check(slot_history.undo(), "restore valid slot before saving")
	_check(_catalog.search("SEWER_BEETLE").size() == 1, "content ID search")
	_check(_catalog.search("world/decorations").size() == 1, "asset path search")
	_check(not _place({"kind": "enemy", "id": &"berry"}, Vector2.ZERO), "wrong content type rejected")
	_enabled.button_pressed = false
	_check(not _place({"kind": "platform"}, Vector2.ZERO), "disabled placement rejected")
	_enabled.button_pressed = true

	var group := root.get_node("SpawnPoints") as Node2D
	group.position = Vector2(40, -20)
	root.position = Vector2(70, 32)
	var position := Vector2(800, 495)
	var cases := [["enemy", "SEWER_BEETLE"], ["gather", "rusty_scrap"], ["entry", "Region Points"],
		["escape", "Region Points"], ["climb", "ladder"], ["climb", "rope"], ["platform", "platform"],
		["obstacle", "obstacle"], ["texture", "icon.svg"], ["scene", "sewer_wall_mark"]]
	for spec in cases:
		var kind: String = spec[0]
		var found := false
		var entries := _catalog.search(spec[1])
		for entry in entries:
			if entry.kind != kind:
				continue
			found = true
			_check(_place(entry, position), "place " + kind)
			var selected := EditorInterface.get_selection().get_selected_nodes()
			if selected.size() == 1:
				var child := selected[0] as Node2D
				_check(child.owner == root and child.global_position.is_equal_approx(position), "owner and transformed position " + kind)
			else:
				_check(false, "select " + kind)
			break
		_check(found, "catalog includes %s %s" % [kind, spec[1]])

	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	var decoration := EditorInterface.get_selection().get_selected_nodes()[0] as FieldDecoration
	_check(history.undo() and not decoration.is_inside_tree(), "undo removes node and new group")
	_check(history.redo() and decoration.owner == root, "redo restores node and owner")
	_validate()
	_check(_status.text.begins_with("No RegionDefinition"), "unregistered scene reports explicit registration")
	_exercise_terrain_transactions(root)
	var path := root.scene_file_path
	if DisplayServer.get_name() == "headless":
		var packed := PackedScene.new()
		_check(packed.pack(root) == OK and ResourceSaver.save(packed, path) == OK, "headless scene save")
	else:
		_check(EditorInterface.save_scene() == OK, "editor save")
	var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := saved.instantiate() as Node2D
	_check(instance.get_node("PlayerSpawnPoint1").spawn_index == 1, "reloaded slot retains corrected index")
	_check(instance.get_node("SpawnPoints").get_child_count() == 2, "saved enemy marker is present")
	var area := instance.get_node("Climbables").get_child(0) as ClimbableArea2D
	_check(area.top_marker != null and area.bottom_marker != null and area.top_marker.owner == instance, "climb paths and owners survive reload")
	_check(instance.get_node("Decorations").get_child(-1).asset_path.ends_with("sewer_wall_mark.tscn"), "decoration path survives reload")
	instance.free()

	if DisplayServer.get_name() != "headless":
		await _exercise_gui(root)
		_check(EditorInterface.close_scene() == OK, "close saved field tab")
		await get_tree().process_frame
		EditorInterface.open_scene_from_path(path)
		for frame in 60:
			await get_tree().process_frame
			if _field_root() != null and _field_root().scene_file_path == path:
				break
		var reopened := _field_root()
		_check(reopened != null and reopened != root and reopened.get_node("SpawnPoints").get_child_count() == 2, "reopen saved field tab")
	print("FIELD EDITOR PROBE ", "PASS" if _failures == 0 else "FAIL", " failures=", _failures)
	get_tree().quit(0 if _failures == 0 else 1)

func _exercise_gui(root: Node2D) -> void:
	var dock_control: Control = _dock
	while dock_control.get_parent() is Control:
		var container := dock_control.get_parent() as TabContainer
		if container != null:
			container.current_tab = container.get_tab_idx_from_control(dock_control)
		dock_control = dock_control.get_parent() as Control
	_dock.show()
	EditorInterface.set_main_screen_editor("2D")
	EditorInterface.edit_node(root)
	_search.text = "platform"
	_populate()
	update_overlays()
	for frame in 10:
		await get_tree().process_frame
	if not is_instance_valid(_overlay) or not _tree.is_visible_in_tree():
		_check(false, "rendered dock and canvas overlay are visible (overlay=%s, tree=%s, parent=%s)" % [is_instance_valid(_overlay), _tree.is_visible_in_tree(), _dock.get_parent()])
		return
	_set_test_tool(Stroke.Mode.RECTANGLE)
	var item := _tree.get_root().get_first_child().get_first_child()
	var start := _tree.get_global_transform_with_canvas() * _tree.get_item_area_rect(item, 0).get_center()
	var local := _overlay.size * Vector2(0.62, 0.45)
	var destination := _overlay.get_global_transform_with_canvas() * local
	var terrain := root.get_node("Terrain")
	var before := terrain.get_child_count()
	get_tree().root.warp_mouse(start)
	await get_tree().process_frame
	_mouse_motion(start, Vector2.ZERO, false)
	_mouse_button(start, true)
	_mouse_motion(start + Vector2(18, 0), Vector2(18, 0), true)
	for frame in 4:
		await get_tree().process_frame
	get_tree().root.warp_mouse(destination)
	_mouse_motion(destination, destination - start - Vector2(18, 0), true)
	for frame in 4:
		await get_tree().process_frame
	var expected := _world_position(local)
	_mouse_button(destination, false)
	await get_tree().process_frame
	_check(terrain.get_child_count() == before + 1, "native Tree drag drops into 2D viewport")
	if terrain.get_child_count() > before:
		var placed := terrain.get_child(-1) as Node2D
		_check(placed.global_position.is_equal_approx(expected), "native drop uses overlay canvas transform: expected %s, got %s" % [expected, placed.global_position])
		await _exercise_terrain_gui(root)
		_check(EditorInterface.save_scene() == OK, "save after native drag and strokes")

func _exercise_terrain_transactions(root: Node2D) -> void:
	var terrain := root.get_node("Terrain") as Node2D
	var original_transform := terrain.transform
	var nested := Node2D.new()
	nested.name = "NestedTerrain"
	terrain.add_child(nested)
	nested.owner = root
	nested.transform = Transform2D(0.2, Vector2(-2, 0.5), 0.0, Vector2(45, 80))
	_nested.button_pressed = true
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(nested)
	var before := terrain.get_child_count()
	_mode.select(Stroke.Mode.RECTANGLE)
	_begin_stroke(Vector2(900, 290))
	_end_stroke(Vector2(804, 242))
	var platform := nested.get_child(0) as FieldPlatform if nested.get_child_count() > 0 else null
	_check(nested.get_child_count() == 1 and platform != null, "reverse rectangle creates one nested platform")
	if platform == null:
		return
	_check(platform.size == Vector2(96, 48) and platform.global_position.is_equal_approx(Vector2(852, 266)), "reverse rectangle size and world center")
	_check(platform.global_transform.is_equal_approx(Transform2D(0.0, Vector2(852, 266))), "negative nonuniform parent basis compensated")
	_check(platform.get_node("CollisionShape2D").shape.size == platform.size, "collision follows rectangle size")
	var visual := platform.get_node("Visual") as Polygon2D
	var polygon := visual.polygon
	visual.polygon = PackedVector2Array([Vector2.ZERO, Vector2.ONE, Vector2.UP])
	var diagnostics := RegionDefinition.validate_field_nodes(null, root, _catalog)
	_check("\n".join(diagnostics).contains("collision and visual bounds differ"), "validator catches a platform visual size mismatch")
	visual.polygon = polygon
	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	_check(history.undo() and nested.get_child_count() == 0, "rectangle undo")
	_check(history.redo() and platform.owner == root, "rectangle redo restores owner")
	_check(history.undo(), "undo transformed probe")
	_nested.button_pressed = false
	terrain.transform = original_transform
	_mode.select(Stroke.Mode.RECTANGLE)
	_begin_stroke(Vector2(672, 160))
	_end_stroke(Vector2(673, 161))
	_check(terrain.get_child_count() == before, "tiny rectangle skipped")
	terrain.scale.x = 0.0
	_begin_stroke(Vector2(672, 160))
	_check(_stroke == null, "singular parent rejected")
	terrain.transform = original_transform
	_layer_menu.select(1)
	_layer_selected(1)
	_set_layer_locked(true)
	_begin_stroke(Vector2(672, 160))
	_check(_stroke == null, "locked terrain rejects tool")
	_check(not _place({"kind": "platform", "label": "Platform", "id": &""}, Vector2(10, 10)), "locked terrain rejects palette placement")
	_set_layer_locked(false)
	_check(Layers.for_node(root.get_node("PlayerSpawnPoint0"), root) == "SpawnPoints", "root player spawn is logically classified")
	_check(Layers.for_node(root.get_node("SpawnPoints/SewerBeetle"), root) == "SpawnPoints", "nested enemy spawn is classified")
	_set_layer_visible(false)
	_check(terrain.visible and terrain.get_node("Floor").visible and not terrain.get_node("Floor/CollisionShape2D").disabled, "preview hiding never changes authored visibility or collision")
	_set_layer_visible(true)
	_layer_menu.select(0)
	_layer_selected(0)
	_begin_stroke(Vector2(672, 160))
	_end_stroke(Vector2(736, 192))
	_check(terrain.get_child_count() == before + 1, "authored rectangle remains for save and runtime check")
	var canvas := EditorInterface.get_editor_viewport_2d()
	var original_canvas := canvas.global_canvas_transform
	canvas.global_canvas_transform = Transform2D(Vector2(2, 0), Vector2(0, 2), Vector2(60, -20))
	var sample := canvas.global_canvas_transform * Vector2(49, 19)
	_check(_stroke_world(sample, false) == Vector2(64, 32), "snap after inverse zoom and pan")
	_check(_stroke_world(sample, true).is_equal_approx(Vector2(49, 19)), "Alt bypass under zoom and pan")
	canvas.global_canvas_transform = original_canvas
	_mode.select(Stroke.Mode.SELECT)

func _exercise_terrain_gui(root: Node2D) -> void:
	var terrain := root.get_node("Terrain")
	var before := terrain.get_child_count()
	EditorInterface.get_selection().clear()
	await get_tree().process_frame
	_set_test_tool(Stroke.Mode.RECTANGLE)
	var from := _overlay.size * Vector2(0.72, 0.30)
	var to := _overlay.size * Vector2(0.55, 0.18)
	await _canvas_stroke(from, to)
	_check(terrain.get_child_count() == before + 1, "GUI rectangle creates a platform without a selection")
	if terrain.get_child_count() == before + 1:
		var platform := terrain.get_child(-1) as FieldPlatform
		await _check_layer_visibility(root, platform)
	var before_outside := terrain.get_child_count()
	await _canvas_stroke(from, Vector2(-40, from.y))
	_check(terrain.get_child_count() == before_outside, "release outside viewport discards rectangle")
	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	_set_test_tool(Stroke.Mode.PAINT)
	from = _overlay.size * Vector2(0.28, 0.25)
	to = _overlay.size * Vector2(0.48, 0.25)
	before = terrain.get_child_count()
	await _canvas_stroke(from, to)
	var painted := terrain.get_child_count() - before
	_check(painted > 2, "GUI paint fills fast motion between endpoints")
	_check(history.undo() and terrain.get_child_count() == before, "one undo removes whole paint stroke")
	_check(history.redo() and terrain.get_child_count() == before + painted, "one redo restores whole paint stroke")
	await _canvas_stroke(from, to)
	_check(terrain.get_child_count() == before + painted, "repainting same grid cells does not duplicate platforms")
	await _canvas_stroke(from + Vector2(0, 55), to + Vector2(0, 55), true)
	_check(terrain.get_child_count() == before + painted, "Escape discards pending GUI stroke")
	_set_test_tool(Stroke.Mode.ERASE)
	await _canvas_stroke(from, to)
	_check(terrain.get_child_count() < before + painted and terrain.has_node("Floor") and root.has_node("EnemySpawnManager"), "GUI erase removes painted terrain and protects existing nodes")
	var erased_count := terrain.get_child_count()
	_check(history.undo() and terrain.get_child_count() == before + painted, "one undo restores whole erase stroke")
	for child in terrain.get_children():
		if child is FieldPlatform:
			_check(child.owner == root, "erase undo restores owner")
	_check(history.redo() and terrain.get_child_count() == erased_count, "erase redo removes same terrain")
	_set_test_tool(Stroke.Mode.SELECT)

func _check_layer_visibility(root: Node2D, platform: FieldPlatform) -> void:
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	var screen := _overlay.get_global_transform_with_canvas() * (canvas * platform.global_position)
	var pixel := Vector2i(screen + Vector2(4, 4))
	await RenderingServer.frame_post_draw
	var visible_color := get_tree().root.get_texture().get_image().get_pixelv(pixel)
	_layer_menu.select(1)
	_layer_selected(1)
	_set_layer_visible(false)
	await RenderingServer.frame_post_draw
	var hidden_color := get_tree().root.get_texture().get_image().get_pixelv(pixel)
	_check(not visible_color.is_equal_approx(hidden_color), "terrain hide changes rendered editor pixels")
	_check(EditorInterface.save_scene() == OK, "save field while terrain preview is hidden")
	var packed := ResourceLoader.load(root.scene_file_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := packed.instantiate()
	var saved := instance.get_node(root.get_path_to(platform)) as FieldPlatform
	_check(saved.visible and not saved.get_node("CollisionShape2D").disabled and saved.size == platform.size, "hidden preview does not serialize visibility, collision or size changes")
	instance.free()
	_set_layer_visible(true)
	_layer_menu.select(0)
	_layer_selected(0)

func _set_test_tool(mode: int) -> void:
	_mode.select(mode)
	_mode.item_selected.emit(mode)

func _canvas_stroke(from: Vector2, to: Vector2, cancel := false) -> void:
	var transform := _overlay.get_global_transform_with_canvas()
	var first := transform * from
	var last := transform * to
	get_tree().root.warp_mouse(first)
	await get_tree().process_frame
	_mouse_button(first, true)
	_mouse_motion(last, last - first, true)
	if cancel:
		var escape := InputEventKey.new()
		escape.keycode = KEY_ESCAPE
		escape.pressed = true
		get_tree().root.push_input(escape, true)
	_mouse_button(last, false)
	await get_tree().process_frame

func _mouse_motion(position: Vector2, relative: Vector2, pressed: bool) -> void:
	var event := InputEventMouseMotion.new()
	event.position = position
	event.global_position = position
	event.relative = relative
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	get_tree().root.push_input(event, true)

func _mouse_button(position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	get_tree().root.push_input(event, true)

func _check(condition: bool, label: String) -> void:
	if not condition:
		_failures += 1
		push_error("Field editor probe: " + label)
