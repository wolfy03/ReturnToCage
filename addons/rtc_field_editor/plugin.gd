@tool
extends EditorPlugin

const Catalog := preload("catalog.gd")
const Placement := preload("placement.gd")
const PaletteTree := preload("palette_tree.gd")
const ExportFilter := preload("export_filter.gd")
const Layers := preload("field_layers.gd")
const Stroke := preload("terrain_stroke.gd")
const TerrainCommands := preload("terrain_commands.gd")

var _catalog := Catalog.new()
var _export_filter := ExportFilter.new()
var _dock: VBoxContainer
var _tree: Tree
var _search: LineEdit
var _scene_label: Label
var _status: RichTextLabel
var _enabled: CheckButton
var _snap: CheckButton
var _interval: SpinBox
var _nested: CheckButton
var _drop_surface: Control
var _drag: Dictionary = {}
var _drag_root: Node2D
var _filesystem: EditorFileSystem
var _layers := Layers.new()
var _mode: OptionButton
var _layer_menu: OptionButton
var _layer_visible: CheckBox
var _layer_locked: CheckBox
var _preview_pending := false
var _stroke: Stroke
var _stroke_root: Node2D
var _stroke_parent: Node2D
var _stroke_transform: Transform2D
var _stroke_history: UndoRedo
var _stroke_version: int
var _stroke_obstacle: bool
var _canvas_overlay: Control
var _tool_surface: Control

func _enter_tree() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "Field Editor"
	_dock.custom_minimum_size.x = 220
	_enabled = _toggle("Placement enabled", true)
	_enabled.toggled.connect(func(_value: bool) -> void:
		_cancel_drag()
		_cancel_stroke()
		_sync_tool_surface())
	_scene_label = Label.new()
	_scene_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_dock.add_child(_scene_label)
	_search = LineEdit.new()
	_search.placeholder_text = "Search name, ID, path or category"
	_dock.add_child(_search)
	_tree = PaletteTree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size.y = 120
	_tree.drag_started.connect(_start_drag)
	_dock.add_child(_tree)
	_snap = _toggle("Grid snap (Alt bypass)", true)
	_interval = SpinBox.new()
	_interval.min_value = 1
	_interval.max_value = 1024
	_interval.value = 32
	_interval.suffix = "px"
	_dock.add_child(_interval)
	_nested = _toggle("Use selected Node2D group", false)
	_add_terrain_controls()
	var validate := Button.new()
	validate.text = "Validate field"
	validate.pressed.connect(_validate)
	_dock.add_child(validate)
	_status = RichTextLabel.new()
	_status.custom_minimum_size.y = 68
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Drag an asset into the 2D viewport."
	_dock.add_child(_status)
	add_control_to_dock(DOCK_SLOT_LEFT_BR, _dock)
	add_export_plugin(_export_filter)
	_search.text_changed.connect(func(_value: String) -> void: _populate())
	_filesystem = EditorInterface.get_resource_filesystem()
	_filesystem.filesystem_changed.connect(_rebuild)
	scene_changed.connect(_scene_changed)
	get_tree().node_added.connect(_layer_tree_changed)
	get_tree().node_removed.connect(_layer_tree_changed)
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()
	_scene_changed(EditorInterface.get_edited_scene_root())
	_rebuild.call_deferred()

func _exit_tree() -> void:
	_cancel_drag()
	_cancel_stroke()
	_layers.restore()
	if is_instance_valid(_tool_surface):
		_tool_surface.queue_free()
	get_tree().node_added.disconnect(_layer_tree_changed)
	get_tree().node_removed.disconnect(_layer_tree_changed)
	_filesystem.filesystem_changed.disconnect(_rebuild)
	scene_changed.disconnect(_scene_changed)
	remove_export_plugin(_export_filter)
	remove_control_from_docks(_dock)
	_dock.queue_free()
	_dock = null

func _toggle(label: String, initial: bool) -> CheckButton:
	var button := CheckButton.new()
	button.text = label
	button.button_pressed = initial
	_dock.add_child(button)
	return button

func _rebuild() -> void:
	if not is_instance_valid(_dock):
		return
	_catalog.rebuild(_filesystem.get_filesystem())
	_populate()

func _populate() -> void:
	_tree.clear()
	var root := _tree.create_item()
	var groups: Dictionary[String, TreeItem] = {}
	var icons := {"Terrain": "StaticBody2D", "Enemy": "Marker2D", "Gather": "Marker2D",
		"Region Points": "Marker2D", "Spawns": "Marker2D", "Climbables": "Area2D", "Decorations": "Sprite2D"}
	for entry in _catalog.search(_search.text):
		var category: String = entry.category
		if not groups.has(category):
			groups[category] = _tree.create_item(root)
			groups[category].set_text(0, category)
			groups[category].set_selectable(0, false)
		var item := _tree.create_item(groups[category])
		item.set_text(0, entry.label if entry.id.is_empty() else "%s [%s]" % [entry.label, entry.id])
		item.set_icon(0, _tree.get_theme_icon(icons[category], "EditorIcons"))
		item.set_tooltip_text(0, "%s\n%s" % [entry.kind, entry.path])
		item.set_metadata(0, entry)

func _scene_changed(root: Node) -> void:
	_cancel_drag()
	_cancel_stroke()
	_layers.restore()
	_layers.hidden.clear()
	_layers.locked.clear()
	_layer_menu.select(0)
	_layer_selected(0)
	_sync_tool_surface()
	_scene_label.text = root.scene_file_path.get_file() if root != null else "No scene"
	_scene_label.tooltip_text = root.scene_file_path if root != null else ""
	_status.text = "Drag an asset into the 2D viewport." if _field_root() != null else "Open an AdventureRegion scene."

func _field_root() -> Node2D:
	var root := EditorInterface.get_edited_scene_root() as Node2D
	if root != null and root.get_script() != null and root.get_script().resource_path == "res://world/adventure/adventure_region.gd":
		return root
	return null

func _start_drag(entry: Dictionary) -> void:
	_cancel_stroke()
	_cancel_drag()
	_drag_root = _field_root()
	if _drag_root == null or not _enabled.button_pressed:
		_status.text = "Open a field scene and enable placement."
		return
	_drag = entry
	_sync_tool_surface()
	set_process(true)
	update_overlays()

func _process(_delta: float) -> void:
	if _drag.is_empty() or not _tree.get_viewport().gui_is_dragging() or _field_root() != _drag_root:
		_cancel_drag()
	else:
		update_overlays()

func _cancel_drag() -> void:
	_drag = {}
	_drag_root = null
	set_process(false)
	if is_instance_valid(_drop_surface):
		_drop_surface.hide()
		_drop_surface.queue_free()
	_drop_surface = null
	_sync_tool_surface()
	update_overlays()

func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if not _drag.is_empty() and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_drag()
		return true
	return false

func _terrain_input(event: InputEvent) -> bool:
	if _mode.selected == Stroke.Mode.SELECT or not _enabled.button_pressed:
		return false
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.ctrl_pressed and not event.meta_pressed:
		if event.pressed:
			if _field_root() == null:
				return false
			_begin_stroke(_stroke_world(event.position, event.alt_pressed))
			return true
		if _stroke != null:
			if is_instance_valid(_canvas_overlay) and not Rect2(Vector2.ZERO, _canvas_overlay.size).has_point(event.position):
				_cancel_stroke()
			else:
				_end_stroke(_stroke_world(event.position, event.alt_pressed))
			return true
	if event is InputEventMouseMotion and _stroke != null:
		if event.button_mask & MOUSE_BUTTON_MASK_LEFT == 0:
			_cancel_stroke()
		else:
			_extend_stroke(_stroke_world(event.position, event.alt_pressed))
		return true
	return false

func _input(event: InputEvent) -> void:
	if _stroke == null:
		return
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE:
			_cancel_stroke()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_Z and (event.ctrl_pressed or event.meta_pressed):
			_cancel_stroke()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		# Canvas forwarding commits in the same input dispatch. A release
		# anywhere else only reaches this deferred cancellation.
		_cancel_if_current.call_deferred(_stroke)

func _cancel_if_current(stroke: Stroke) -> void:
	if _stroke == stroke:
		_cancel_stroke()

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _stroke != null:
		_cancel_stroke()

func _forward_canvas_force_draw_over_viewport(overlay: Control) -> void:
	_canvas_overlay = overlay
	if not is_instance_valid(_tool_surface):
		_install_tool_surface.call_deferred(overlay)
	if _drag.is_empty():
		_draw_stroke(overlay)
		return
	if not is_instance_valid(_drop_surface) or _drop_surface.get_parent() != overlay:
		_install_drop_surface.call_deferred(overlay)
	var mouse := overlay.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, overlay.size).has_point(mouse):
		return
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	var world := _world_position(mouse)
	if not world.is_finite():
		return
	var snapped := canvas * world
	var color := Color("8ee8ce")
	overlay.draw_circle(snapped, 7, color, false, 2)
	overlay.draw_line(snapped - Vector2(12, 0), snapped + Vector2(12, 0), color)
	overlay.draw_line(snapped - Vector2(0, 12), snapped + Vector2(0, 12), color)
	overlay.draw_string(_tree.get_theme_default_font(), snapped + Vector2(14, -8), _drag.label)

func _install_drop_surface(overlay: Control) -> void:
	if _drag.is_empty() or not is_instance_valid(overlay) or is_instance_valid(_drop_surface):
		return
	_drop_surface = Control.new()
	overlay.add_child(_drop_surface)
	_drop_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_drop_surface.set_drag_forwarding(Callable(), _can_drop, _drop)

func _can_drop(_position: Vector2, data: Variant) -> bool:
	return not _drag.is_empty() and data == _drag and _enabled.button_pressed and _field_root() == _drag_root

func _world_position(cursor: Vector2) -> Vector2:
	var interval := _interval.value if _snap.button_pressed and not Input.is_key_pressed(KEY_ALT) else 0.0
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	return Placement.world_position(canvas, cursor, interval) if _invertible(canvas) else Vector2.INF

func _drop(position: Vector2, data: Variant) -> void:
	if not _can_drop(position, data):
		return
	_place(data, _world_position(position))
	_cancel_drag()

func _place(entry: Dictionary, world: Vector2) -> bool:
	var root := _field_root()
	if root == null or not _enabled.button_pressed or not world.is_finite():
		return false
	var group_name := Placement.group_for(entry.kind)
	var issue := _layers.issue("SpawnPoints" if entry.kind == "player" else group_name)
	if not issue.is_empty():
		_status.text = issue
		return false
	var parent := root
	var new_group: Node2D
	if _nested.button_pressed and entry.kind != "player":
		var selected := EditorInterface.get_selection().get_selected_nodes()
		if selected.size() == 1 and selected[0].get_class() == "Node2D" and selected[0].get_script() == null and selected[0].owner == root and selected[0].scene_file_path.is_empty():
			parent = selected[0]
	if parent == root and not group_name.is_empty():
		var existing := root.get_node_or_null(group_name)
		if existing == null:
			new_group = Node2D.new()
			new_group.name = group_name
		elif existing.get_class() != "Node2D" or existing.get_script() != null or existing.owner != root or not existing.scene_file_path.is_empty():
			_status.text = "%s must be an editable Node2D group." % group_name
			return false
		else:
			parent = existing
	if not _invertible(parent.global_transform):
		_status.text = "Placement parent has a singular transform."
		if new_group != null:
			new_group.free()
		return false
	var child := Placement.make_node(entry, root, _catalog)
	if child == null:
		if new_group != null:
			new_group.free()
		_status.text = "Invalid asset, duplicate content ID, or all player slots are occupied."
		return false
	child.position = parent.to_local(world)
	var undo := get_undo_redo()
	var selection := EditorInterface.get_selection()
	var previous := selection.get_selected_nodes()
	undo.create_action("Place %s" % entry.label, UndoRedo.MERGE_DISABLE, root)
	if new_group != null:
		undo.add_do_method(root, "add_child", new_group, true)
		undo.add_do_method(new_group, "set_owner", root)
		undo.add_do_reference(new_group)
		parent = new_group
	undo.add_do_method(parent, "add_child", child, true)
	undo.add_do_method(child, "set_owner", root)
	if child is ClimbableArea2D:
		for part in child.get_children():
			undo.add_do_method(part, "set_owner", root)
	undo.add_do_reference(child)
	undo.add_do_method(self, "_select_nodes", [child])
	undo.add_undo_method(parent, "remove_child", child)
	if new_group != null:
		undo.add_undo_method(root, "remove_child", new_group)
	undo.add_undo_method(self, "_select_nodes", previous)
	undo.commit_action()
	_status.text = "Placed %s at %s. Edit exact Position in Inspector." % [entry.label, child.position]
	if child is RegionPoint:
		_status.text += " Check RegionDefinition ID declarations."
	return true

func _select_nodes(nodes: Array) -> void:
	var selection := EditorInterface.get_selection()
	selection.clear()
	for node in nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			selection.add_node(node)
	if nodes.size() == 1 and is_instance_valid(nodes[0]) and nodes[0].is_inside_tree():
		EditorInterface.inspect_object(nodes[0])

func _validate() -> void:
	var root := _field_root()
	if root == null:
		_status.text = "Open an AdventureRegion scene."
		return
	var region: RegionDefinition
	for definition in _catalog.definitions.values():
		if definition is RegionDefinition and definition.scene_path == root.scene_file_path:
			region = definition
			break
	var issues := RegionDefinition.validate_field_nodes(region, root, _catalog)
	if region == null:
		issues.insert(0, "No RegionDefinition points to this scene. Save it and set scene_path and point IDs explicitly.")
	if issues.is_empty():
		issues.append("Field validation passed.")
	issues.append_array(RegionDefinition.FieldSceneChecks.spawn_warnings(root))
	_status.text = "\n".join(issues)

# Canvas input forwarding depends on the editor's current object selection.
# An overlay control routes tool gestures even when the selection is empty.
func _install_tool_surface(overlay: Control) -> void:
	if not is_inside_tree() or not is_instance_valid(overlay) or is_instance_valid(_tool_surface):
		return
	_tool_surface = Control.new()
	_tool_surface.mouse_force_pass_scroll_events = true
	overlay.add_child(_tool_surface)
	_tool_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_tool_surface.gui_input.connect(func(event: InputEvent) -> void:
		if _terrain_input(event):
			_tool_surface.accept_event())
	_sync_tool_surface()

func _sync_tool_surface() -> void:
	if is_instance_valid(_tool_surface):
		var active := _enabled.button_pressed and _mode.selected != Stroke.Mode.SELECT and _drag.is_empty() and _field_root() != null
		_tool_surface.mouse_filter = Control.MOUSE_FILTER_PASS if active else Control.MOUSE_FILTER_IGNORE

func _add_terrain_controls() -> void:
	var tools := HBoxContainer.new()
	_dock.add_child(tools)
	var tools_label := Label.new()
	tools_label.text = "Tool"
	tools.add_child(tools_label)
	_mode = OptionButton.new()
	for label in ["Select", "Rectangle", "Paint", "Erase"]:
		_mode.add_item(label)
	_mode.item_selected.connect(func(_index: int) -> void:
		_cancel_stroke()
		_sync_tool_surface()
		update_overlays())
	tools.add_child(_mode)

	_layer_menu = OptionButton.new()
	_layer_menu.add_item("Layer: Auto")
	for layer in Layers.NAMES:
		_layer_menu.add_item(layer)
	_layer_menu.item_selected.connect(_layer_selected)
	_dock.add_child(_layer_menu)
	var flags := HBoxContainer.new()
	_dock.add_child(flags)
	_layer_visible = CheckBox.new()
	_layer_visible.text = "Visible"
	_layer_visible.tooltip_text = "Viewport preview only. Saved visibility and collision stay intact."
	_layer_visible.toggled.connect(_set_layer_visible)
	flags.add_child(_layer_visible)
	_layer_locked = CheckBox.new()
	_layer_locked.text = "Tool lock"
	_layer_locked.tooltip_text = "Blocks Field Editor tools. Godot's Select and Inspector remain available."
	_layer_locked.toggled.connect(_set_layer_locked)
	flags.add_child(_layer_locked)

func _layer_selected(index: int) -> void:
	_cancel_stroke()
	_layers.active = "" if index == 0 else Layers.NAMES[index - 1]
	_layer_visible.disabled = index == 0
	_layer_locked.disabled = index == 0
	_layer_visible.set_pressed_no_signal(not _layers.hidden.get(_layers.active, false))
	_layer_locked.set_pressed_no_signal(_layers.locked.get(_layers.active, false))

func _set_layer_visible(visible: bool) -> void:
	if _layers.active.is_empty():
		return
	_cancel_stroke()
	_layers.hidden[_layers.active] = not visible
	_layers.set_preview(_field_root())
	update_overlays()

func _set_layer_locked(locked: bool) -> void:
	if _layers.active.is_empty():
		return
	_cancel_stroke()
	_layers.locked[_layers.active] = locked

func _layer_tree_changed(_node: Node) -> void:
	if not _preview_pending and _layers.hidden.values().has(true):
		_preview_pending = true
		_refresh_layers.call_deferred()

func _refresh_layers() -> void:
	_preview_pending = false
	if is_inside_tree() and is_instance_valid(_dock):
		_layers.set_preview(_field_root())

static func _invertible(transform: Transform2D) -> bool:
	return transform.is_finite() and not is_zero_approx(transform.determinant())

func _stroke_world(position: Vector2, bypass_snap: bool) -> Vector2:
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	if not _invertible(canvas):
		return Vector2.INF
	var interval := _interval.value if _mode.selected == Stroke.Mode.RECTANGLE and _snap.button_pressed and not bypass_snap else 0.0
	return Placement.world_position(canvas, position, interval)

func _terrain_parent(root: Node2D) -> Node2D:
	if _nested.button_pressed:
		var selected := EditorInterface.get_selection().get_selected_nodes()
		if selected.size() == 1 and _editable_group(selected[0], root):
			return selected[0] as Node2D
	var group := root.get_node_or_null("Terrain")
	if group == null:
		return root
	return group as Node2D if _editable_group(group, root) else null

static func _editable_group(node: Node, root: Node2D) -> bool:
	return node.get_class() == "Node2D" and node.get_script() == null and node.owner == root and node.scene_file_path.is_empty()

func _begin_stroke(world: Vector2) -> void:
	_cancel_stroke()
	var root := _field_root()
	var issue := _layers.issue("Terrain")
	if not issue.is_empty():
		_status.text = issue
		return
	if root == null or not world.is_finite():
		_status.text = "Terrain stroke requires a finite canvas position."
		return
	var parent := root if _mode.selected == Stroke.Mode.ERASE else _terrain_parent(root)
	if parent == null or not _invertible(parent.global_transform):
		_status.text = "Terrain parent must be editable and have an invertible transform."
		return
	var platforms: Array[FieldPlatform] = []
	if _mode.selected != Stroke.Mode.RECTANGLE:
		for node in root.find_children("*", "StaticBody2D", true, false):
			if node is FieldPlatform and node.owner == root:
				platforms.append(node)
	_stroke_root = root
	_stroke_parent = parent
	_stroke_transform = parent.global_transform
	var undo := get_undo_redo()
	_stroke_history = undo.get_history_undo_redo(undo.get_object_history_id(root))
	_stroke_version = _stroke_history.get_version() if _stroke_history != null else -1
	var selected := _tree.get_selected()
	var entry: Variant = selected.get_metadata(0) if selected != null else null
	_stroke_obstacle = entry is Dictionary and entry.kind == "obstacle"
	_stroke = Stroke.new()
	_stroke.begin(_mode.selected, world, _interval.value, platforms)
	update_overlays()

func _extend_stroke(world: Vector2) -> void:
	if not world.is_finite() or _field_root() != _stroke_root or not is_instance_valid(_stroke_parent) or not _stroke_parent.is_inside_tree() or _stroke_parent.global_transform != _stroke_transform:
		_cancel_stroke()
		_status.text = "Terrain stroke cancelled because the field or transform changed."
		return
	if _stroke_history != null and _stroke_history.get_version() != _stroke_version:
		_cancel_stroke()
		return
	_stroke.extend(world)
	update_overlays()

func _end_stroke(world: Vector2) -> void:
	_extend_stroke(world)
	if _stroke == null:
		return
	if _stroke.mode == Stroke.Mode.ERASE:
		var targets: Array[FieldPlatform] = []
		for platform in _stroke.erased:
			if is_instance_valid(platform) and platform.is_inside_tree() and platform.owner == _stroke_root:
				targets.append(platform)
		if not targets.is_empty():
			TerrainCommands.erase(get_undo_redo(), _stroke_root, targets)
			_status.text = "Erased %d terrain objects." % targets.size()
	else:
		var rectangles: Array[Rect2] = []
		if _stroke.mode == Stroke.Mode.RECTANGLE:
			var rectangle := _stroke.rectangle()
			if rectangle.size.is_finite() and rectangle.size.x >= Stroke.MIN_SIZE and rectangle.size.y >= Stroke.MIN_SIZE:
				rectangles.append(rectangle)
			else:
				_status.text = "Rectangle must be at least %d × %d world units." % [Stroke.MIN_SIZE, Stroke.MIN_SIZE]
		else:
			for cell in _stroke.cells:
				rectangles.append(_stroke.cell_rect(cell))
		if not rectangles.is_empty():
			var group: Node2D
			if _stroke_parent == _stroke_root:
				group = Node2D.new()
				group.name = "Terrain"
			TerrainCommands.add(get_undo_redo(), _stroke_root, _stroke_parent, group, rectangles, _stroke_obstacle, _select_nodes)
			_status.text = "Created %d terrain objects." % rectangles.size()
	_cancel_stroke()

func _cancel_stroke() -> void:
	if _stroke != null:
		_stroke = null
		update_overlays()
	_stroke_root = null
	_stroke_parent = null
	_stroke_history = null

func _draw_stroke(overlay: Control) -> void:
	if _stroke == null:
		return
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	if not _invertible(canvas):
		return
	var tint := Color(0.30, 0.85, 0.70, 0.36)
	match _stroke.mode:
		Stroke.Mode.RECTANGLE:
			overlay.draw_rect(canvas * _stroke.rectangle(), tint)
		Stroke.Mode.PAINT:
			for cell in _stroke.cells:
				overlay.draw_rect(canvas * _stroke.cell_rect(cell), tint)
		Stroke.Mode.ERASE:
			var red := Color(0.95, 0.35, 0.35, 0.75)
			overlay.draw_circle(canvas * _stroke.cursor, Stroke.ERASE_RADIUS * canvas.x.length(), red, false, 2)
			for platform in _stroke.erased:
				if is_instance_valid(platform):
					var half: Vector2 = platform.size * 0.5
					var transform: Transform2D = canvas * platform.global_transform
					overlay.draw_polyline(PackedVector2Array([transform * -half, transform * Vector2(half.x, -half.y),
						transform * half, transform * Vector2(-half.x, half.y), transform * -half]), red, 2)
