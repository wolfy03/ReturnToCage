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

static func valid_stack(data: Dictionary, errors: PackedStringArray) -> bool:
	if not is_text(data.get("item_id", "")) or not is_number(data.get("quantity", 0)) or not is_number(data.get("durability", -1)) or not is_text(data.get("instance_id", "")):
		errors.append("invalid item stack in save")
		return false
	return true

static func position(data: Dictionary, key: String, fallback: Vector2, errors: PackedStringArray) -> Vector2:
	if not data.has(key):
		return fallback
	var raw: Variant = data[key]
	if raw is Array and raw.size() == 2 and is_number(raw[0]) and is_number(raw[1]):
		return Vector2(float(raw[0]), float(raw[1]))
	errors.append("invalid position in save: %s" % key)
	return fallback
