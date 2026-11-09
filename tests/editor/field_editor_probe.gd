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
	var path := root.scene_file_path
	if DisplayServer.get_name() == "headless":
		var packed := PackedScene.new()
		_check(packed.pack(root) == OK and ResourceSaver.save(packed, path) == OK, "headless scene save")
	else:
		_check(EditorInterface.save_scene() == OK, "editor save")
	var saved := ResourceLoader.load(path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var instance := saved.instantiate() as Node2D
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
		_check(EditorInterface.save_scene() == OK, "save after native drag")

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
