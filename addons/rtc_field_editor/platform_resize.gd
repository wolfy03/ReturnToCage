@tool
extends RefCounted

const HANDLES := [Vector2(-1,-1), Vector2(0,-1), Vector2(1,-1), Vector2(1,0),
	Vector2(1,1), Vector2(0,1), Vector2(-1,1), Vector2(-1,0)]
const RADIUS := 6.0

var node: FieldPlatform
var basis: Transform2D
var original_size: Vector2
var original_position: Vector2
var direction: Vector2
var size: Vector2
var position: Vector2
var parent: Node2D
var pointer_start: Vector2

func begin(platform: FieldPlatform, handle: Vector2) -> void:
	node = platform
	parent = node.get_parent() as Node2D
	basis = node.global_transform
	original_size = node.size
	original_position = node.position
	direction = handle
	size = original_size
	position = original_position

func valid() -> bool:
	return is_instance_valid(node) and is_instance_valid(parent) and node.is_inside_tree() and node.get_parent() == parent and node.global_transform == basis and node.size == original_size

func preview(world: Vector2) -> void:
	var local := basis.affine_inverse() * world
	var center := Vector2.ZERO
	for axis in 2:
		if direction[axis] == 0:
			continue
		var fixed := -direction[axis] * original_size[axis] * 0.5
		size[axis] = maxf(4.0, direction[axis] * (local[axis] - fixed))
		center[axis] = fixed + direction[axis] * size[axis] * 0.5
	position = parent.to_local(basis * center)

func commit(undo: EditorUndoRedoManager, root: Node2D) -> void:
	if not size.is_finite() or not position.is_finite():
		return
	if size.is_equal_approx(original_size) and position.is_equal_approx(original_position):
		return
	undo.create_action("Resize field platform", UndoRedo.MERGE_DISABLE, root)
	undo.add_do_property(node, "position", position)
	undo.add_do_property(node, "size", size)
	undo.add_undo_property(node, "position", original_position)
	undo.add_undo_property(node, "size", original_size)
	undo.commit_action()
