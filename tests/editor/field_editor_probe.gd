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
	_check_step3_contracts(root)
	_exercise_terrain_transactions(root)
	await _exercise_step4_transactions(root)
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
		await _exercise_step4_gui(root)
		_check(EditorInterface.save_scene() == OK, "save after native drag and strokes")

func _exercise_step4_transactions(root: Node2D) -> void:
	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	var existing := root.get_node("SpawnPoints/SewerBeetle") as FieldEnemySpawnPoint
	var duplicate := existing.duplicate() as FieldEnemySpawnPoint
	existing.get_parent().add_child(duplicate, true)
	duplicate.owner = root
	var gather := root.get_node("GatherPoints/ScrapCacheA") as FieldGatherPoint
	var gather_copy := gather.duplicate() as FieldGatherPoint
	gather.get_parent().add_child(gather_copy, true)
	gather_copy.owner = root
	var old_enemy := existing.spawn_id
	var old_gather := gather.interaction_id
	_check(Maintenance.duplicates(root).size() == 2, "detect enemy and gather duplicates")
	_check(Maintenance.repair(root, get_undo_redo()) == 2 and Maintenance.duplicates(root).is_empty(), "repair duplicate IDs")
	var replacement := duplicate.spawn_id
	_check(existing.spawn_id == old_enemy and gather.interaction_id == old_gather, "repair preserves first IDs")
	_check(history.undo() and duplicate.spawn_id == old_enemy and gather_copy.interaction_id == old_gather, "ID undo")
	_check(history.redo() and duplicate.spawn_id == replacement, "ID redo deterministic")
	var pack := PackedScene.new()
	_check(pack.pack(root) == OK, "pack repaired ID scene")
	var clone := pack.instantiate()
	_check(clone.get_node(root.get_path_to(duplicate)).spawn_id == replacement, "repaired ID serialized")
	clone.free()
	duplicate.free()
	gather_copy.free()

	var template := _catalog.get_definition(&"sewer_region") as RegionDefinition
	var region := template.duplicate() as RegionDefinition
	region.scene_path = root.scene_file_path
	var path := "res://tests/editor/probe_region.tres"
	_check(ResourceSaver.save(region, path) == OK, "create disposable region")
	region = ResourceLoader.load(path, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as RegionDefinition
	_check(Maintenance.sync_plan(root, [region], _catalog).changes.size() == 2, "sync previews added ENTRY and ESCAPE")
	_check(Maintenance.sync_plan(root, [], _catalog).has("error") and Maintenance.sync_plan(root, [region, region], _catalog).has("error"), "missing and ambiguous region rejected")
	var entry := root.get_node("Entry") as RegionPoint
	var old_id := entry.point_id
	entry.point_id = &"temporary_unlinked_entry"
	var blocked := Maintenance.sync_plan(root, [region], _catalog)
	_check(blocked.has("error") and blocked.error.contains("settlement exit"), "referenced entry removal blocked")
	entry.point_id = old_id
	var point := entry.duplicate() as RegionPoint
	root.add_child(point, true)
	_check(Maintenance.sync_plan(root, [region], _catalog).has("error"), "duplicate region point blocks sync")
	point.free()
	var plan := Maintenance.sync_plan(root, [region], _catalog)
	var save_scene := _save_probe_scene.bind(root) if DisplayServer.get_name() == "headless" else EditorInterface.save_scene
	_check(_apply_region_plan(root, plan, save_scene), "save Scene and RegionDefinition sync")
	var reloaded := ResourceLoader.load(path, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as RegionDefinition
	_check(reloaded.entry_point_ids == plan.entries and reloaded.escape_point_ids == plan.escapes, "synced resource reload")
	_check(Maintenance.sync_plan(root, [region], _catalog).changes.is_empty(), "matching declarations unchanged")
	_check(history.undo(), "sync undo")
	reloaded = ResourceLoader.load(path, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as RegionDefinition
	_check(reloaded.entry_point_ids == template.entry_point_ids and reloaded.escape_point_ids == template.escape_point_ids, "undo persists old declarations")
	_check(history.redo(), "sync redo")
	reloaded = ResourceLoader.load(path, "Resource", ResourceLoader.CACHE_MODE_IGNORE) as RegionDefinition
	_check(reloaded.entry_point_ids == plan.entries and reloaded.escape_point_ids == plan.escapes, "redo persists new declarations")
	await _exercise_sync_failures(root, plan, history, path)

	var first := DecorationStroke.new()
	var second := DecorationStroke.new()
	var no_existing: Array[Vector2] = []
	var strokes: Array[DecorationStroke] = [first, second]
	for stroke in strokes:
		stroke.begin(Vector2.ZERO, 32, 20, Vector2(0.5, 1.5), 42, true, true, no_existing)
		stroke.extend(Vector2(96, 0))
		stroke.extend(Vector2.ZERO)
	_check(first.transforms == second.transforms and first.transforms.size() == 4, "seeded brush transform and duplicate avoidance")
	_check(first.transforms[2].origin == Vector2(64, 0), "brush maintains world spacing")
	var dense: Array[Vector2] = []
	for x in 3000:
		dense.append(Vector2(x, 0))
	var long_stroke := DecorationStroke.new()
	long_stroke.begin(Vector2.ZERO, 1, 0, Vector2.ONE, 1, false, true, dense)
	long_stroke.extend(Vector2(6000, 0))
	_check(long_stroke.transforms.size() == DecorationStroke.LIMIT and long_stroke.transforms[0].origin == Vector2(3000, 0), "long brush crosses dense duplicates before reaching placement cap")
	var split := DecorationStroke.new()
	var single := DecorationStroke.new()
	split.begin(Vector2.ZERO, 1, 20, Vector2(0.5, 1.5), 51, true, false, no_existing)
	single.begin(Vector2.ZERO, 1, 20, Vector2(0.5, 1.5), 51, true, false, no_existing)
	for x in range(1, 401):
		split.extend(Vector2(x * 0.25, 0))
	single.extend(Vector2(100, 0))
	_check(single.transforms.size() == 101 and split.transforms == single.transforms, "small spacing and fractional event boundaries preserve identical stamps")
	var decor := root.get_node("Decorations") as Node2D
	var before := decor.get_child_count()
	var transforms: Array[Transform2D] = first.transforms.duplicate()
	for i in transforms.size():
		transforms[i].origin += Vector2(800, 110)
	TerrainCommands.decorate(get_undo_redo(), root, decor, null, "res://world/decorations/sewer_wall_mark.tscn", transforms)
	var stamp := decor.get_child(-1) as FieldDecoration
	_check(decor.get_child_count() == before + 4 and stamp.global_transform.is_equal_approx(transforms[-1]), "brush commits deterministic transforms")
	_check(history.undo() and decor.get_child_count() == before, "headless brush undo")
	_check(history.redo() and stamp.owner == root and stamp.global_transform.is_equal_approx(transforms[-1]), "headless brush redo")
	var platform: FieldPlatform
	for node in root.get_node("Terrain").get_children():
		if node is FieldPlatform:
			platform = node
	_check(platform != null, "resize fixture exists")
	if platform == null:
		return
	var original_transform := platform.transform
	platform.transform = Transform2D(0.35, Vector2(-1.3, 0.6), 0.12, platform.position)
	for direction in Resize.HANDLES:
		var gesture := Resize.new()
		gesture.begin(platform, direction)
		var opposite: Vector2 = gesture.basis * (-direction * gesture.original_size * 0.5)
		gesture.preview(gesture.basis * (direction * (gesture.original_size * 0.5 + Vector2(18, 12))))
		var new_basis := gesture.basis
		new_basis.origin = gesture.parent.to_global(gesture.position)
		_check((new_basis * (-direction * gesture.size * 0.5)).is_equal_approx(opposite), "resize fixes opposite edge " + str(direction))
		gesture.preview(opposite)
		_check(gesture.size.x >= 4 and gesture.size.y >= 4, "resize clamps minimum")
	platform.transform = original_transform

func _save_probe_scene(root: Node2D) -> Error:
	var scene := PackedScene.new()
	var error := scene.pack(root)
	return ResourceSaver.save(scene, root.scene_file_path) if error == OK else error

func _set_probe_read_only(path: String, read_only: bool) -> void:
	if OS.get_name() == "Windows":
		_check(FileAccess.set_read_only_attribute(path, read_only) == OK, "set fixture read-only attribute")
	else:
		_check(FileAccess.set_unix_permissions(path, 0x124 if read_only else 0x1A4) == OK, "set fixture permissions")

func _exercise_sync_failures(root: Node2D, plan: Dictionary, history: UndoRedo, resource_path: String) -> void:
	var scene_path := root.scene_file_path
	var scene_hash := FileAccess.get_sha256(scene_path)
	var region_hash := FileAccess.get_sha256(resource_path)
	var action := history.get_current_action()
	var region: RegionDefinition = plan.region
	var entries := region.entry_point_ids.duplicate()
	var escapes := region.escape_point_ids.duplicate()
	_check(not _apply_region_plan(root, plan, func() -> Error:
		FileAccess.open(scene_path, FileAccess.WRITE).store_string("simulated partial scene save")
		return ERR_CANT_CREATE
	), "scene save failure rejected")
	_check(FileAccess.get_sha256(scene_path) == scene_hash and FileAccess.get_sha256(resource_path) == region_hash and history.get_current_action() == action, "scene save failure restores bytes and preserves history")

	var parked := ProjectSettings.globalize_path(resource_path + ".parked")
	var actual := ProjectSettings.globalize_path(resource_path)
	_check(DirAccess.rename_absolute(actual, parked) == OK, "park resource for missing-file failure")
	_check(not _apply_region_plan(root, plan, _save_probe_scene.bind(root)), "missing resource fails before writing scene")
	_check(DirAccess.rename_absolute(parked, actual) == OK and FileAccess.get_sha256(scene_path) == scene_hash, "missing resource failure preserves scene")
	_set_probe_read_only(resource_path, true)
	var called: Array[bool] = []
	_check(not _apply_region_plan(root, plan, func() -> Error:
		called.append(true)
		return OK
	) and called.is_empty(), "read-only resource rejected before scene save")
	_check(history.undo(), "engine dispatched failing sync undo")
	await get_tree().process_frame
	_check(history.get_current_action() == action and region.entry_point_ids == entries and region.escape_point_ids == escapes and FileAccess.get_sha256(resource_path) == region_hash, "failed undo restores history and leaves data intact")
	_set_probe_read_only(resource_path, false)
	_check(history.undo(), "retry sync undo")
	var previous_hash := FileAccess.get_sha256(resource_path)
	_set_probe_read_only(resource_path, true)
	_check(history.redo(), "engine dispatched failing sync redo")
	await get_tree().process_frame
	_check(history.get_current_action() == action - 1 and FileAccess.get_sha256(resource_path) == previous_hash and region.entry_point_ids != entries, "failed redo restores history and leaves data intact")
	_set_probe_read_only(resource_path, false)
	_check(history.redo(), "retry sync redo")
	region_hash = FileAccess.get_sha256(resource_path)
	_check(not _apply_region_plan(root, plan, func() -> Error:
		FileAccess.open(scene_path, FileAccess.WRITE).store_string("simulated new scene bytes")
		_set_probe_read_only(resource_path, true)
		return OK
	), "late resource publish failure rejected")
	_set_probe_read_only(resource_path, false)
	_check(FileAccess.get_sha256(scene_path) == scene_hash and FileAccess.get_sha256(resource_path) == region_hash and history.get_current_action() == action, "late resource failure rolls back scene without history action")
	EditorInterface.open_scene_from_path("res://core/boot.tscn")
	await get_tree().process_frame
	EditorInterface.open_scene_from_path(scene_path)
	await get_tree().process_frame
	_check(_field_root() == root and history.get_current_action() == action, "scene switch preserves sync history")
	_check(history.undo() and region.entry_point_ids != entries and history.redo() and region.entry_point_ids == entries, "sync history still writes after scene switch")

func _exercise_step4_gui(root: Node2D) -> void:
	_set_test_tool(Stroke.Mode.SELECT)
	var terrain := root.get_node("Terrain")
	var platform := terrain.get_child(-1) as FieldPlatform
	if platform == null:
		_check(false, "GUI resize fixture exists")
		return
	_select_nodes([platform])
	await get_tree().process_frame
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	var edge := canvas * (platform.global_transform * Vector2(platform.size.x * 0.5, 0))
	var inside := Rect2(Vector2.ZERO, _overlay.size)
	_check(inside.has_point(edge) and inside.has_point(edge + Vector2(35, 0)), "resize handle visible in viewport")
	var old_size := platform.size
	var old_position := platform.position
	await _canvas_stroke(edge, edge + Vector2(35, 0), true)
	_check(platform.size == old_size and platform.position == old_position, "Escape cancels GUI resize")
	await _canvas_stroke(edge, edge + Vector2(35, 0))
	_check(platform.size.x > old_size.x and platform.get_node("CollisionShape2D").shape.size == platform.size, "GUI resize updates collision")
	var resized := platform.size
	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	_check(history.undo() and platform.size == old_size, "GUI resize undo")
	_check(history.redo() and platform.size == resized, "GUI resize redo")
	_search.text = "sewer_wall_mark"
	_populate()
	var item := _tree.get_root().get_first_child().get_first_child()
	item.select(0)
	_set_test_tool(Stroke.Mode.DECORATION)
	await get_tree().process_frame
	var decorations := root.get_node("Decorations")
	var before := decorations.get_child_count()
	await _canvas_stroke(_overlay.size * Vector2(0.30, 0.65), _overlay.size * Vector2(0.65, 0.65))
	var count := decorations.get_child_count()
	_check(count > before + 1, "GUI decoration brush paints repeated nodes")
	if count > before:
		var stamp := decorations.get_child(-1) as FieldDecoration
		var transform := stamp.transform
		_check(history.undo() and decorations.get_child_count() == before, "one brush undo")
		_check(history.redo() and stamp.owner == root and stamp.transform == transform, "brush redo restores exact transform")
	_set_test_tool(Stroke.Mode.SELECT)
	_check(EditorInterface.save_scene() == OK, "save after GUI resize and decoration brush")
	var packed := ResourceLoader.load(root.scene_file_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := packed.instantiate()
	_check(instance.get_node(root.get_path_to(platform)).size == resized, "resized platform Size survives reload")
	_check(instance.get_node("Decorations").get_child_count() == count, "decoration brush survives reload")
	instance.free()

func _check_step3_contracts(root: Node2D) -> void:
	var terrain := root.get_node("Terrain") as Node2D
	var large := Placement.PLATFORM.instantiate() as FieldPlatform
	var small := Placement.PLATFORM.instantiate() as FieldPlatform
	terrain.add_child(large)
	terrain.add_child(small)
	large.owner = root
	small.owner = root
	large.size = Vector2(160, 32)
	large.global_position = Vector2(832, 160)
	var order := terrain.get_children()
	TerrainCommands.erase(get_undo_redo(), root, [small, large])
	var history := get_undo_redo().get_history_undo_redo(get_undo_redo().get_object_history_id(root))
	_check(history.undo() and terrain.get_children() == order and large.owner == root and small.owner == root, "erase restores sibling order and owners")
	var stroke := Stroke.new()
	stroke.begin(Stroke.Mode.PAINT, Vector2(896, 160), 32, [large])
	_check(stroke.cells.is_empty(), "paint skips occupied area away from platform center")
	_nested.button_pressed = true
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(root.get_node("Decorations"))
	_mode.select(Stroke.Mode.RECTANGLE)
	_begin_stroke(Vector2(0, 0))
	_check(_stroke == null, "incompatible nested decoration group rejects terrain")
	_cancel_stroke()
	_nested.button_pressed = false
	_mode.select(Stroke.Mode.SELECT)
	large.free()
	small.free()

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
