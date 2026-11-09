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
	if not is_finite(distance) or distance <= 0.0 or transforms.size() >= LIMIT:
		return
	var epsilon := _spacing * 0.000001
	# The cap counts placed nodes. A long segment may encounter more than
	# LIMIT occupied positions before the first available one.
	var budget := LIMIT - transforms.size() + (_seen.size() if _avoid else 0)
	var sample := _remaining
	for _step in budget:
		if sample > distance + epsilon or transforms.size() >= LIMIT:
			break
		var fraction := minf(sample / distance, 1.0)
		# Scalar floats retain precision until the final Vector2 conversion.
		_add(Vector2(lerpf(_last.x, world.x, fraction), lerpf(_last.y, world.y, fraction)))
		sample += _spacing
	if distance + epsilon < _remaining:
		_remaining -= distance
	else:
		var remainder := fposmod(distance - _remaining, _spacing)
		_remaining = _spacing if remainder < epsilon or _spacing - remainder < epsilon else _spacing - remainder
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
