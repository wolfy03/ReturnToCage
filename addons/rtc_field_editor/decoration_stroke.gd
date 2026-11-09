@tool
extends RefCounted

const LIMIT := 2048
var transforms: Array[Transform2D] = []
var _seen: Dictionary[Vector2i, bool] = {}
var _rng := RandomNumberGenerator.new()
var _last: Vector2
var _remaining: float
var _spacing: float
var _angle: float
var _scales: Vector2
var _flip: bool
var _avoid: bool

func begin(world: Vector2, spacing: float, angle: float, scales: Vector2, seed_value: int,
		flip: bool, avoid: bool, existing: Array[Vector2]) -> void:
	_spacing = spacing
	_angle = deg_to_rad(angle)
	_scales = Vector2(minf(scales.x, scales.y), maxf(scales.x, scales.y))
	_flip = flip
	_avoid = avoid
	_rng.seed = seed_value
	_last = world
	_remaining = spacing
	for point in existing:
		_seen[_key(point)] = true
	_add(world)

func extend(world: Vector2) -> void:
	var distance := _last.distance_to(world)
	if not is_finite(distance) or distance < 0.0001:
		return
	var steps := 0
	while _remaining <= distance and steps < LIMIT and transforms.size() < LIMIT:
		_add(_last.lerp(world, _remaining / distance))
		_remaining += _spacing
		steps += 1
	_remaining = _remaining - distance if _remaining > distance else _spacing
	_last = world

func _key(point: Vector2) -> Vector2i:
	return Vector2i((point * 4.0).round())

func _add(world: Vector2) -> void:
	var key := _key(world)
	if _avoid and _seen.has(key):
		return
	_seen[key] = true
	var scale_value := _rng.randf_range(_scales.x, _scales.y)
	var angle := _rng.randf_range(-_angle, _angle)
	var flip_x := -1.0 if _flip and _rng.randf() < 0.5 else 1.0
	transforms.append(Transform2D(angle, Vector2(scale_value * flip_x, scale_value), 0.0, world))
