class_name RegionPoint
extends Marker2D

enum Kind { ENTRY, ESCAPE }
@export var point_id: StringName
@export var requires_landing: bool = false
@export var kind: Kind = Kind.ENTRY

static func collect(root: Node, points: Array[RegionPoint]) -> void:
	if root is RegionPoint:
		points.append(root)
	for child in root.get_children():
		collect(child, points)
