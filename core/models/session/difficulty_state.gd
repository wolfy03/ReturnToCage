class_name DifficultyState
extends RefCounted

const OVERRIDABLE_PROPERTIES: Array[StringName] = [
	&"enemy_health_multiplier", &"enemy_damage_multiplier", &"survival_drain_multiplier", &"loot_multiplier",
	&"inventory_loss", &"equipment_loss", &"recovery_policy", &"escape_display"
]

var id: StringName
var overrides: Dictionary[StringName, Variant] = {}

func reset(start: GameStartDefinition) -> void:
	id = start.difficulty_id
	overrides.clear()

func effective(registry: Node) -> DifficultyDefinition:
	var original := registry.get_definition(id) as DifficultyDefinition
	if original == null:
		return null
	var result := original.duplicate() as DifficultyDefinition
	for property_name in overrides:
		if is_valid_override(property_name, overrides[property_name]):
			result.set(property_name, overrides[property_name])
	return result

func set_id(value: StringName, registry: Node) -> bool:
	if not registry.get_definition(value) is DifficultyDefinition:
		return false
	id = value
	return true

func set_override(property_name: StringName, value: Variant) -> bool:
	if not is_valid_override(property_name, value):
		return false
	overrides[property_name] = value
	return true

static func is_valid_override(property_name: StringName, value: Variant) -> bool:
	if not OVERRIDABLE_PROPERTIES.has(property_name) or not SaveData.is_number(value):
		return false
	match property_name:
		&"inventory_loss":
			return float(value) == int(value) and int(value) in DifficultyDefinition.InventoryLoss.values()
		&"equipment_loss":
			return float(value) == int(value) and int(value) in DifficultyDefinition.EquipmentLoss.values()
		&"recovery_policy":
			return float(value) == int(value) and int(value) in DifficultyDefinition.RecoveryPolicy.values()
		&"escape_display":
			return float(value) == int(value) and int(value) in DifficultyDefinition.EscapeDisplay.values()
	return float(value) >= 0.0

func to_save_dict() -> Dictionary:
	var saved_overrides: Dictionary = {}
	for key in overrides:
		saved_overrides[String(key)] = overrides[key]
	return {"difficulty_id": String(id), "difficulty_overrides": saved_overrides}

func restore(data: Dictionary, start: GameStartDefinition, registry: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	reset(start)
	var restored_id := StringName(SaveData.text_value(data, "difficulty_id", String(id), errors))
	if not set_id(restored_id, registry):
		errors.append("unknown difficulty in save: %s" % restored_id)
	var raw: Dictionary = SaveData.dictionary(data, "difficulty_overrides", errors)
	for key in raw:
		if not SaveData.is_text(key) or not set_override(StringName(str(key)), raw[key]):
			errors.append("invalid difficulty override in save: %s" % key)
	return errors
