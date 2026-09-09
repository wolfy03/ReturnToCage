class_name ProgressionState
extends RefCounted

signal shared_changed(revision: int)

var shared_quest_states: Dictionary[StringName, QuestState] = {}
# Save v3 and existing PARTY quest compatibility facade. Personal quest state is
# intentionally excluded from the v3 save schema.
var quest_states: Dictionary[StringName, QuestState]:
	get:
		return shared_quest_states
var personal_progression: Dictionary[StringName, PersonalProgressionState] = {}
var _quest_revisions: Dictionary[String, int] = {}
var _unlocked_regions: Array[StringName] = []
var unlocked_regions: Array[StringName]:
	get: return _unlocked_regions if _can_mutate_shared() else _unlocked_regions.duplicate()
	set(value):
		if _can_mutate_shared(): _unlocked_regions = value
var _unlocked_exits: Array[StringName] = []
var unlocked_exits: Array[StringName]:
	get: return _unlocked_exits if _can_mutate_shared() else _unlocked_exits.duplicate()
	set(value):
		if _can_mutate_shared(): _unlocked_exits = value
var _unlocked_flags: Array[StringName] = []
var unlocked_flags: Array[StringName]:
	get: return _unlocked_flags if _can_mutate_shared() else _unlocked_flags.duplicate()
	set(value):
		if _can_mutate_shared(): _unlocked_flags = value
var _discovered_escape_points: Array[StringName] = []
var discovered_escape_points: Array[StringName]:
	get: return _discovered_escape_points if _can_mutate_shared() else _discovered_escape_points.duplicate()
	set(value):
		if _can_mutate_shared(): _discovered_escape_points = value
var shared_revision: int = 0
var _applying_shared_snapshot: bool = false
var _mutation_guard: Callable

func set_mutation_guard(guard: Callable) -> void:
	_mutation_guard = guard

func reset(start: GameStartDefinition) -> void:
	_applying_shared_snapshot = true
	shared_quest_states.clear()
	personal_progression.clear()
	_quest_revisions.clear()
	unlocked_regions = start.unlocked_regions.duplicate()
	unlocked_exits = start.unlocked_exits.duplicate()
	unlocked_flags = start.unlocked_flags.duplicate()
	discovered_escape_points = start.discovered_escape_points.duplicate()
	shared_revision = 0
	_applying_shared_snapshot = false

func to_save_dict() -> Dictionary:
	var quests: Array[Dictionary] = []
	for state in shared_quest_states.values():
		quests.append(state.to_dict())
	return {
		"quests": quests, "unlocked_regions": SaveData.strings(unlocked_regions),
		"unlocked_exits": SaveData.strings(unlocked_exits), "unlocked_flags": SaveData.strings(unlocked_flags),
		"discovered_escape_points": SaveData.strings(discovered_escape_points)
	}

func restore(data: Dictionary, registry: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	_applying_shared_snapshot = true
	shared_quest_states.clear()
	personal_progression.clear()
	_quest_revisions.clear()
	for raw in SaveData.array(data, "quests", errors):
		if not raw is Dictionary:
			errors.append("invalid quest record in save")
			continue
		var quest_id := StringName(SaveData.text_value(raw, "quest_id", "", errors))
		var definition := registry.get_definition(quest_id) as QuestDefinition
		if definition == null:
			errors.append("unknown quest in save: %s" % quest_id)
			continue
		var state := QuestState.new(quest_id)
		state.initialize(definition)
		var progress: Array = SaveData.array(raw, "progress", errors)
		if progress.size() != state.progress.size():
			errors.append("quest progress length differs in save: %s" % quest_id)
		for index in mini(progress.size(), state.progress.size()):
			if not SaveData.is_integer(progress[index]):
				errors.append("invalid quest progress in save: %s[%d], expected bounded integer" % [quest_id, index])
				continue
			var raw_progress: int = int(progress[index])
			state.progress[index] = clampi(raw_progress, 0, definition.objectives[index].required_amount)
			if state.progress[index] != raw_progress:
				errors.append("quest progress clamped in save: %s[%d] from %d to %d" % [quest_id, index, raw_progress, state.progress[index]])
		state.completed = SaveData.boolean(raw, "completed", false, errors)
		state.reward_claimed = SaveData.boolean(raw, "reward_claimed", false, errors)
		if not state.reward_claimed:
			var complete: bool = true
			for index in definition.objectives.size():
				if state.progress[index] < definition.objectives[index].required_amount:
					complete = false
			if complete != state.completed:
				errors.append("quest completion reconciled with objectives: %s" % quest_id)
			state.completed = complete
		# Save v3 stores only the legacy shared/PARTY quest collection.
		if definition.scope != QuestDefinition.Scope.PERSONAL:
			shared_quest_states[quest_id] = state
		else:
			errors.append("personal quest ignored by Save v3: %s" % quest_id)
	unlocked_regions = SaveData.names(data, "unlocked_regions", errors)
	unlocked_exits = SaveData.names(data, "unlocked_exits", errors)
	unlocked_flags = SaveData.names(data, "unlocked_flags", errors)
	discovered_escape_points = SaveData.names(data, "discovered_escape_points", errors)
	shared_revision = 0
	_applying_shared_snapshot = false
	return errors

func mark_shared_changed() -> int:
	if not _can_mutate_shared():
		return shared_revision
	shared_revision += 1
	shared_changed.emit(shared_revision)
	return shared_revision

func apply_shared_network_mirror(snapshot: SharedProgressionSnapshot) -> bool:
	if snapshot == null or not snapshot.error_message.is_empty() or snapshot.revision <= shared_revision:
		return false
	_applying_shared_snapshot = true
	unlocked_regions = snapshot.unlocked_regions.duplicate()
	unlocked_exits = snapshot.unlocked_exits.duplicate()
	unlocked_flags = snapshot.unlocked_flags.duplicate()
	discovered_escape_points = snapshot.discovered_escape_points.duplicate()
	shared_revision = snapshot.revision
	_applying_shared_snapshot = false
	shared_changed.emit(shared_revision)
	return true

func _can_mutate_shared() -> bool:
	return _applying_shared_snapshot or not _mutation_guard.is_valid() or bool(_mutation_guard.call())

func ensure_personal_progression(player_id: StringName) -> PersonalProgressionState:
	if player_id.is_empty():
		return null
	var result: PersonalProgressionState = personal_progression.get(player_id)
	if result == null:
		result = PersonalProgressionState.new(player_id)
		personal_progression[player_id] = result
	return result

func get_personal_progression(player_id: StringName) -> PersonalProgressionState:
	return personal_progression.get(player_id)

func get_quest_state(quest_id: StringName, player_id: StringName, registry: Node) -> QuestState:
	var definition := registry.get_definition(quest_id) as QuestDefinition
	if definition == null:
		return null
	if definition.scope == QuestDefinition.Scope.PERSONAL:
		var personal := get_personal_progression(player_id)
		return personal.quest_states.get(quest_id) if personal != null else null
	return shared_quest_states.get(quest_id)

func set_quest_state(quest_id: StringName, player_id: StringName, state: QuestState, registry: Node) -> bool:
	var definition := registry.get_definition(quest_id) as QuestDefinition
	if definition == null or state == null:
		return false
	if definition.scope == QuestDefinition.Scope.PERSONAL:
		var personal := ensure_personal_progression(player_id)
		if personal == null:
			return false
		personal.quest_states[quest_id] = state
	else:
		shared_quest_states[quest_id] = state
	return true

func quest_states_for(definition: QuestDefinition, player_id: StringName = &"") -> Dictionary:
	if definition != null and definition.scope == QuestDefinition.Scope.PERSONAL:
		var personal := get_personal_progression(player_id)
		return personal.quest_states if personal != null else {}
	return shared_quest_states

func bump_quest_revision(quest_id: StringName, owner_player_id: StringName = &"") -> int:
	var key := _revision_key(quest_id, owner_player_id)
	var revision: int = _quest_revisions.get(key, 0) + 1
	_quest_revisions[key] = revision
	return revision

func quest_revision(quest_id: StringName, owner_player_id: StringName = &"") -> int:
	return _quest_revisions.get(_revision_key(quest_id, owner_player_id), 0)

func accept_quest_revision(quest_id: StringName, owner_player_id: StringName, revision: int) -> bool:
	var key := _revision_key(quest_id, owner_player_id)
	if revision <= _quest_revisions.get(key, -1):
		return false
	_quest_revisions[key] = revision
	return true

static func _revision_key(quest_id: StringName, owner_player_id: StringName) -> String:
	return "%s\u001f%s" % [owner_player_id, quest_id]
