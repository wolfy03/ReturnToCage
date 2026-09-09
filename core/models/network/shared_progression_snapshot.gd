class_name SharedProgressionSnapshot
extends RefCounted

var revision: int = 0
var unlocked_regions: Array[StringName] = []
var unlocked_exits: Array[StringName] = []
var unlocked_flags: Array[StringName] = []
var discovered_escape_points: Array[StringName] = []
var error_message: String = ""

func to_payload() -> Dictionary:
	return {
		"revision": revision,
		"unlocked_regions": SaveData.strings(unlocked_regions),
		"unlocked_exits": SaveData.strings(unlocked_exits),
		"unlocked_flags": SaveData.strings(unlocked_flags),
		"discovered_escape_points": SaveData.strings(discovered_escape_points),
	}

static func from_state(state: ProgressionState) -> SharedProgressionSnapshot:
	var result := SharedProgressionSnapshot.new()
	result.revision = state.shared_revision
	result.unlocked_regions = state.unlocked_regions.duplicate()
	result.unlocked_exits = state.unlocked_exits.duplicate()
	result.unlocked_flags = state.unlocked_flags.duplicate()
	result.discovered_escape_points = state.discovered_escape_points.duplicate()
	return result

static func from_payload(payload: Dictionary, registry: Node) -> SharedProgressionSnapshot:
	var result := SharedProgressionSnapshot.new()
	if not payload.get("revision", null) is int or payload["revision"] < 0:
		result.error_message = "Invalid shared progression revision"
		return result
	result.revision = payload["revision"]
	for field in ["unlocked_regions", "unlocked_exits", "unlocked_flags", "discovered_escape_points"]:
		if not payload.get(field, null) is Array:
			result.error_message = "Invalid shared progression field: %s" % field
			return result
		var target: Array[StringName] = result.get(field)
		for raw in payload[field]:
			if not SaveData.is_text(raw):
				result.error_message = "Invalid shared progression identity"
				return result
			var id := StringName(raw)
			if id.is_empty() or target.has(id) or not _valid_id(field, id, registry):
				result.error_message = "Unknown or duplicate shared progression identity"
				return result
			target.append(id)
	return result

static func _valid_id(field: String, id: StringName, registry: Node) -> bool:
	match field:
		"unlocked_regions":
			return registry.get_definition(id) is RegionDefinition
		"unlocked_exits":
			return registry.get_definition(id) is SettlementExitDefinition
		"unlocked_flags":
			return _known_flags(registry).has(id)
		"discovered_escape_points":
			for content in registry.all_definitions():
				if content is RegionDefinition and content.escape_point_ids.has(id):
					return true
	return false

static func _known_flags(registry: Node) -> Array[StringName]:
	var result: Array[StringName] = []
	for content in registry.all_definitions():
		var candidates: Array[StringName] = []
		if content is GameStartDefinition:
			candidates = content.unlocked_flags
		elif content is RegionDefinition:
			candidates = content.unlock_flags
		elif content is RecipeDefinition:
			candidates = content.unlock_flags
		elif content is SettlementExitDefinition:
			candidates = content.required_flags
		elif content is FacilityDefinition:
			for level in content.levels:
				if level != null:
					for flag in level.unlock_flags:
						if not result.has(flag):
							result.append(flag)
		for flag in candidates:
			if not result.has(flag):
				result.append(flag)
	return result
