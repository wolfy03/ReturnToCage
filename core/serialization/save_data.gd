class_name SaveData
extends RefCounted
## Type checks shared only by save/restore boundaries. Invalid fields keep defaults.

static func is_number(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(float(value))

static func is_text(value: Variant) -> bool:
	return value is String or value is StringName

static func dictionary(data: Dictionary, key: String, errors: PackedStringArray) -> Dictionary:
	var value: Variant = data.get(key, {})
	if value is Dictionary:
		return value
	errors.append("invalid dictionary in save: %s" % key)
	return {}

static func array(data: Dictionary, key: String, errors: PackedStringArray) -> Array:
	var value: Variant = data.get(key, [])
	if value is Array:
		return value
	errors.append("invalid array in save: %s" % key)
	return []

static func number(data: Dictionary, key: String, fallback: float, errors: PackedStringArray) -> float:
	var value: Variant = data.get(key, fallback)
	if is_number(value):
		return float(value)
	errors.append("invalid number in save: %s" % key)
	return fallback

static func text_value(data: Dictionary, key: String, fallback: String, errors: PackedStringArray) -> String:
	var value: Variant = data.get(key, fallback)
	if is_text(value):
		return String(value)
	errors.append("invalid string in save: %s" % key)
	return fallback

static func boolean(data: Dictionary, key: String, fallback: bool, errors: PackedStringArray) -> bool:
	var value: Variant = data.get(key, fallback)
	if value is bool:
		return value
	errors.append("invalid boolean in save: %s" % key)
	return fallback

static func names(data: Dictionary, key: String, errors: PackedStringArray) -> Array[StringName]:
	var result: Array[StringName] = []
	for value in array(data, key, errors):
		if is_text(value):
			result.append(StringName(value))
		else:
			errors.append("invalid content id in save: %s" % key)
	return result

static func strings(values: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result

static func valid_stack(data: Dictionary, errors: PackedStringArray, context: String = "item stack") -> bool:
	var reason: String = ""
	if not is_text(data.get("item_id", null)) or String(data.get("item_id", "")).is_empty():
		reason = "missing or invalid item_id"
	elif not is_integer(data.get("quantity", null)) or int(data["quantity"]) <= 0:
		reason = "quantity must be a positive integer"
	elif not is_integer(data.get("durability", -1)):
		reason = "durability must be an integer"
	elif not is_text(data.get("instance_id", "")):
		reason = "instance_id must be text"
	elif not String(data.get("instance_id", "")).is_empty() and int(data["quantity"]) != 1:
		reason = "instance quantity must be 1"
	if not reason.is_empty():
		errors.append("%s: %s" % [context, reason])
		return false
	return true

static func is_integer(value: Variant) -> bool:
	# Bounded before conversion; JSON numbers arrive as floats.
	return is_number(value) and float(value) >= -2147483648.0 and float(value) <= 2147483647.0 and float(value) == floorf(float(value))

static func clamped_number(data: Dictionary, key: String, fallback: float, minimum: float, maximum: float, errors: PackedStringArray) -> float:
	var raw: float = number(data, key, fallback, errors)
	var result: float = clampf(raw, minimum, maximum)
	if raw != result:
		errors.append("%s clamped from %s to %s" % [key, raw, result])
	return result

static func position(data: Dictionary, key: String, fallback: Vector2, errors: PackedStringArray) -> Vector2:
	if not data.has(key):
		return fallback
	var raw: Variant = data[key]
	if raw is Array and raw.size() == 2 and is_number(raw[0]) and is_number(raw[1]):
		var candidate := Vector2(float(raw[0]), float(raw[1]))
		if candidate.is_finite():
			return candidate
	errors.append("invalid position in save: %s" % key)
	return fallback
