@tool
extends EditorPlugin

const Catalog := preload("catalog.gd")
const Placement := preload("placement.gd")
const PaletteTree := preload("palette_tree.gd")
const ExportFilter := preload("export_filter.gd")

var _catalog := Catalog.new()
var _export_filter := ExportFilter.new()
var _dock: VBoxContainer
var _tree: Tree
var _search: LineEdit
var _scene_label: Label
var _status: Label
var _enabled: CheckButton
var _snap: CheckButton
var _interval: SpinBox
var _nested: CheckButton
var _drop_surface: Control
var _drag: Dictionary = {}
var _drag_root: Node2D
var _filesystem: EditorFileSystem

func _enter_tree() -> void:
	_dock = VBoxContainer.new()
	_dock.name = "Field Editor"
	_dock.custom_minimum_size.x = 220
	_enabled = _toggle("Placement enabled", true)
	_enabled.toggled.connect(func(_value: bool) -> void: _cancel_drag())
	_scene_label = Label.new()
	_scene_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_dock.add_child(_scene_label)
	_search = LineEdit.new()
	_search.placeholder_text = "Search name, ID, path or category"
	_dock.add_child(_search)
	_tree = PaletteTree.new()
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.custom_minimum_size.y = 180
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
	var validate := Button.new()
	validate.text = "Validate field"
	validate.pressed.connect(_validate)
	_dock.add_child(validate)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.text = "Drag an asset into the 2D viewport."
	_dock.add_child(_status)
	add_control_to_dock(DOCK_SLOT_LEFT_BR, _dock)
	add_export_plugin(_export_filter)
	_search.text_changed.connect(func(_value: String) -> void: _populate())
	_filesystem = EditorInterface.get_resource_filesystem()
	_filesystem.filesystem_changed.connect(_rebuild)
	scene_changed.connect(_scene_changed)
	set_input_event_forwarding_always_enabled()
	set_force_draw_over_forwarding_enabled()
	_scene_changed(EditorInterface.get_edited_scene_root())
	_rebuild.call_deferred()

func _exit_tree() -> void:
	_cancel_drag()
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
	_scene_label.text = root.scene_file_path.get_file() if root != null else "No scene"
	_scene_label.tooltip_text = root.scene_file_path if root != null else ""
	_status.text = "Drag an asset into the 2D viewport." if _field_root() != null else "Open an AdventureRegion scene."

func _field_root() -> Node2D:
	var root := EditorInterface.get_edited_scene_root() as Node2D
	if root != null and root.get_script() != null and root.get_script().resource_path == "res://world/adventure/adventure_region.gd":
		return root
	return null

func _start_drag(entry: Dictionary) -> void:
	_cancel_drag()
	_drag_root = _field_root()
	if _drag_root == null or not _enabled.button_pressed:
		_status.text = "Open a field scene and enable placement."
		return
	_drag = entry
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
	update_overlays()

func _forward_canvas_gui_input(event: InputEvent) -> bool:
	if not _drag.is_empty() and event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		_cancel_drag()
		return true
	return false

func _forward_canvas_force_draw_over_viewport(overlay: Control) -> void:
	if _drag.is_empty():
		return
	if not is_instance_valid(_drop_surface) or _drop_surface.get_parent() != overlay:
		_install_drop_surface.call_deferred(overlay)
	var mouse := overlay.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, overlay.size).has_point(mouse):
		return
	var canvas := EditorInterface.get_editor_viewport_2d().global_canvas_transform
	var snapped := canvas * _world_position(mouse)
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
	return Placement.world_position(EditorInterface.get_editor_viewport_2d().global_canvas_transform, cursor, interval)

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
	if is_zero_approx(parent.global_transform.determinant()):
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
	for definition in _catalog.definitions.values():
		if definition is RegionDefinition and definition.scene_path == root.scene_file_path:
			var errors := RegionDefinition.validate_field_nodes(definition, root, _catalog)
			_status.text = "Field validation passed." if errors.is_empty() else "\n".join(errors)
			return
	_status.text = "No RegionDefinition points to this scene. Save it and set scene_path and point IDs explicitly."
