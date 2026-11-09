@tool
extends RefCounted

enum Mode { SELECT, RECTANGLE, PAINT, ERASE }
const MIN_SIZE := 4.0
const MAX_CELLS := 2048
const ERASE_RADIUS := 10.0

var mode: Mode
var start: Vector2
var cursor: Vector2
var previous: Vector2
var grid: float
var cells: Dictionary[Vector2i, bool] = {}
var occupied: Dictionary[Vector2i, bool] = {}
var candidates: Array[FieldPlatform] = []
var erased: Dictionary[FieldPlatform, bool] = {}

func begin(tool: Mode, world: Vector2, interval: float, platforms: Array[FieldPlatform]) -> void:
	mode = tool
	start = world
	cursor = world
	previous = world
	grid = interval
	candidates = platforms
	if mode == Mode.PAINT:
		for platform in platforms:
			occupied[_cell(platform.global_position)] = true
	extend(world)

func extend(world: Vector2) -> void:
	cursor = world
	if mode == Mode.PAINT:
		var steps := clampi(ceili(previous.distance_to(world) / (grid * 0.5)), 1, MAX_CELLS * 2)
		for i in range(steps + 1):
			var cell := _cell(previous.lerp(world, float(i) / steps))
			if cells.size() >= MAX_CELLS:
				break
			if not occupied.has(cell):
				cells[cell] = true
	elif mode == Mode.ERASE:
		for platform in candidates:
			if not is_instance_valid(platform) or erased.has(platform):
				continue
			if hits_platform(platform, previous, world):
				erased[platform] = true
	previous = world

func _cell(world: Vector2) -> Vector2i:
	return Vector2i((world / grid).round())

func rectangle() -> Rect2:
	return Rect2(start, cursor - start).abs()

func cell_rect(cell: Vector2i) -> Rect2:
	var size := Vector2.ONE * grid
	return Rect2(Vector2(cell) * grid - size * 0.5, size)

static func hits_platform(platform: FieldPlatform, from: Vector2, to: Vector2) -> bool:
	var transform := platform.global_transform
	if not transform.is_finite() or is_zero_approx(transform.determinant()):
		return false
	var inverse := transform.affine_inverse()
	var a := inverse * from
	var b := inverse * to
	var radius := ERASE_RADIUS * maxf(inverse.x.length(), inverse.y.length())
	var box := Rect2(-platform.size * 0.5, platform.size).grow(radius)
	if box.has_point(a) or box.has_point(b):
		return true
	var corners := [box.position, Vector2(box.end.x, box.position.y), box.end, Vector2(box.position.x, box.end.y)]
	for i in 4:
		if Geometry2D.segment_intersects_segment(a, b, corners[i], corners[(i + 1) % 4]) != null:
			return true
	return false
