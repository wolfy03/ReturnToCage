class_name QuestStateSnapshot
extends RefCounted

var quest_id: StringName = &""
var scope: QuestDefinition.Scope = QuestDefinition.Scope.PARTY
var owner_player_id: StringName = &""
var progress: PackedInt32Array = []
var completed: bool = false
var reward_claimed: bool = false
var revision: int = 0
var error_message: String = ""

func to_payload() -> Dictionary:
	return {
		"quest_id": String(quest_id),
		"scope": int(scope),
		"owner_player_id": String(owner_player_id),
		"progress": Array(progress),
		"completed": completed,
		"reward_claimed": reward_claimed,
		"revision": revision,
	}

static func from_state(
	definition: QuestDefinition,
	state: QuestState,
	owner: StringName,
	p_revision: int
) -> QuestStateSnapshot:
	var result := QuestStateSnapshot.new()
	result.quest_id = definition.id
	result.scope = definition.scope
	result.owner_player_id = owner if definition.scope == QuestDefinition.Scope.PERSONAL else &""
	result.progress = state.progress.duplicate()
	result.completed = state.completed
	result.reward_claimed = state.reward_claimed
	result.revision = p_revision
	return result

static func from_payload(payload: Dictionary, registry: Node, expected_personal_owner: StringName = &"") -> QuestStateSnapshot:
	var result := QuestStateSnapshot.new()
	for key in ["quest_id", "owner_player_id"]:
		if not payload.get(key, null) is String and not payload.get(key, null) is StringName:
			result.error_message = "Invalid quest snapshot identity"
			return result
	if not payload.get("scope", null) is int or not payload.get("progress", null) is Array \
			or not payload.get("completed", null) is bool or not payload.get("reward_claimed", null) is bool \
			or not payload.get("revision", null) is int:
		result.error_message = "Invalid quest snapshot fields"
		return result
	result.quest_id = StringName(payload["quest_id"])
	result.owner_player_id = StringName(payload["owner_player_id"])
	result.revision = payload["revision"]
	var raw_scope: int = payload["scope"]
	var definition := registry.get_definition(result.quest_id) as QuestDefinition
	if definition == null or raw_scope < QuestDefinition.Scope.PERSONAL or raw_scope > QuestDefinition.Scope.WORLD \
			or raw_scope != int(definition.scope) or result.revision < 0:
		result.error_message = "Invalid quest snapshot definition"
		return result
	result.scope = raw_scope as QuestDefinition.Scope
	if result.scope == QuestDefinition.Scope.PERSONAL:
		if result.owner_player_id.is_empty() or (not expected_personal_owner.is_empty() and result.owner_player_id != expected_personal_owner):
			result.error_message = "Invalid personal quest snapshot owner"
			return result
	elif not result.owner_player_id.is_empty():
		result.error_message = "Shared quest snapshot cannot have an owner"
		return result
	var raw_progress: Array = payload["progress"]
	if raw_progress.size() != definition.objectives.size():
		result.error_message = "Invalid quest snapshot progress length"
		return result
	for index in raw_progress.size():
		if not raw_progress[index] is int:
			result.error_message = "Invalid quest snapshot progress"
			return result
		var value: int = raw_progress[index]
		if value < 0 or value > definition.objectives[index].required_amount:
			result.error_message = "Quest snapshot progress out of range"
			return result
		result.progress.append(value)
	result.completed = payload["completed"]
	result.reward_claimed = payload["reward_claimed"]
	var calculated_complete := true
	for index in definition.objectives.size():
		if result.progress[index] < definition.objectives[index].required_amount:
			calculated_complete = false
	if result.completed != calculated_complete or (result.reward_claimed and not result.completed):
		result.error_message = "Inconsistent quest snapshot completion"
	return result
