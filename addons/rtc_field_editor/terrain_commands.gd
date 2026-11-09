@tool
extends RefCounted

const Placement := preload("placement.gd")

static func add(undo: EditorUndoRedoManager, root: Node2D, parent: Node2D, group: Node2D,
		rectangles: Array[Rect2], obstacle: bool, select_nodes: Callable) -> void:
	var transform := (root if group != null else parent).global_transform
	var children: Array[Node] = []
	var previous := EditorInterface.get_selection().get_selected_nodes()
	undo.create_action("Draw field terrain", UndoRedo.MERGE_DISABLE, root)
	if group != null:
		undo.add_do_method(root, "add_child", group, true)
		undo.add_do_method(group, "set_owner", root)
		undo.add_do_reference(group)
		parent = group
	for rectangle in rectangles:
		var platform := Placement.PLATFORM.instantiate() as FieldPlatform
		platform.name = "Obstacle" if obstacle else "Platform"
		platform.size = rectangle.size
		platform.transform = transform.affine_inverse() * Transform2D(0.0, rectangle.get_center())
		undo.add_do_method(parent, "add_child", platform, true)
		undo.add_do_method(platform, "set_owner", root)
		undo.add_do_reference(platform)
		undo.add_undo_method(parent, "remove_child", platform)
		children.append(platform)
	if group != null:
		undo.add_undo_method(root, "remove_child", group)
	if children.size() == 1:
		undo.add_do_method(select_nodes.get_object(), select_nodes.get_method(), children)
		undo.add_undo_method(select_nodes.get_object(), select_nodes.get_method(), previous)
	undo.commit_action()

static func erase(undo: EditorUndoRedoManager, root: Node2D, platforms: Array[FieldPlatform]) -> void:
	platforms.sort_custom(func(a: FieldPlatform, b: FieldPlatform) -> bool: return a.get_index() < b.get_index())
	undo.create_action("Erase field terrain", UndoRedo.MERGE_DISABLE, root)
	for platform in platforms:
		var parent := platform.get_parent()
		var index := platform.get_index()
		undo.add_do_method(parent, "remove_child", platform)
		undo.add_undo_method(parent, "add_child", platform)
		undo.add_undo_method(parent, "move_child", platform, index)
		undo.add_undo_method(platform, "set_owner", root)
		for child in platform.find_children("*", "", true, false):
			if child.owner == root:
				undo.add_undo_method(child, "set_owner", root)
		undo.add_undo_reference(platform)
	undo.commit_action()
