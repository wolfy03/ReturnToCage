class_name SessionSnapshot
extends RefCounted
## Detached staging area; no live signals or models are changed during validation.
var player: PlayerState
var players_by_id: Dictionary[StringName, PlayerState] = {}
var local_player_id: StringName
var settlement: SettlementState
var progression: ProgressionState
var difficulty: DifficultyState
var adventure: AdventureState
var session_id: String
var play_time_seconds: float
var warnings: PackedStringArray = PackedStringArray()
var fatal_error: String = ""

static func build(data: Dictionary, start: GameStartDefinition, registry: Node) -> SessionSnapshot:
	# Legacy v1-v3 flat-state builder. Production file loads migrate first and
	# enter through build_persistent(); this remains for migration regression tests.
	var snapshot := SessionSnapshot.new()
	for key in ["player_stats", "equipment"]:
		if data.has(key) and not data[key] is Dictionary:
			snapshot.fatal_error = "Invalid core save object: %s" % key
			return snapshot
	for key in ["player_inventory", "settlement_storage", "protected_inventory"]:
		if data.has(key) and not data[key] is Array:
			snapshot.fatal_error = "Invalid core save array: %s" % key
			return snapshot
	var instances: Dictionary[String, String] = {}
	var resolver := Callable(registry, "get_item")
	snapshot.player = PlayerState.new(resolver)
	snapshot.settlement = SettlementState.new(resolver)
	snapshot.progression = ProgressionState.new()
	snapshot.difficulty = DifficultyState.new()
	snapshot.adventure = AdventureState.new()
	snapshot.session_id = SaveData.text_value(data, "session_id", "restored", snapshot.warnings)
	snapshot.play_time_seconds = maxf(0.0, SaveData.number(data, "play_time_seconds", 0.0, snapshot.warnings))
	snapshot.warnings.append_array(snapshot.player.restore(data, start, instances))
	snapshot.warnings.append_array(snapshot.settlement.restore(data, start, registry, instances))
	snapshot.warnings.append_array(snapshot.progression.restore(data, registry))
	snapshot.warnings.append_array(snapshot.difficulty.restore(data, start, registry))
	snapshot.warnings.append_array(snapshot.adventure.restore(data, instances))
	snapshot.settlement.append_restore_overflow(snapshot.player.inventory.take_restore_overflow())
	snapshot.settlement.append_restore_overflow(snapshot.player.protected_inventory.take_restore_overflow())
	var p: PlayerState = snapshot.player
	# SaveManager resumes a settlement, which must spawn a living actor. Direct
	# PlayerState.restore still preserves the domain's valid zero-health state.
	if p.health <= 0.0:
		p.set_health(1.0)
		snapshot.warnings.append("settlement resume health recovered from 0 to 1")
	return snapshot

static func build_persistent(
	data: Dictionary,
	start: GameStartDefinition,
	registry: Node,
	p_local_player_id: StringName
) -> SessionSnapshot:
	var snapshot := SessionSnapshot.new()
	if not LocalPlayerProfile.is_valid_player_id(p_local_player_id):
		snapshot.fatal_error = "A valid local player profile is required to load Save v4"
		return snapshot
	if not data.get("shared", null) is Dictionary or not data.get("players", null) is Dictionary:
		snapshot.fatal_error = "Invalid Save v4 shared or players object"
		return snapshot
	var shared: Dictionary = data["shared"]
	for key in ["session", "settlement", "progression", "difficulty", "adventure"]:
		if not shared.get(key, null) is Dictionary:
			snapshot.fatal_error = "Invalid Save v4 shared object: %s" % key
			return snapshot
	var raw_players: Dictionary = data["players"]
	if not raw_players.has(String(p_local_player_id)):
		snapshot.fatal_error = "Save v4 does not contain the local profile player"
		return snapshot

	var instances: Dictionary[String, String] = {}
	var resolver := Callable(registry, "get_item")
	snapshot.local_player_id = p_local_player_id
	snapshot.settlement = SettlementState.new(resolver)
	snapshot.progression = ProgressionState.new()
	snapshot.difficulty = DifficultyState.new()
	snapshot.adventure = AdventureState.new()
	var session: Dictionary = shared["session"]
	snapshot.session_id = SaveData.text_value(session, "session_id", "restored", snapshot.warnings)
	snapshot.play_time_seconds = maxf(0.0, SaveData.number(session, "play_time_seconds", 0.0, snapshot.warnings))
	snapshot.warnings.append_array(snapshot.settlement.restore(shared["settlement"], start, registry, instances))
	snapshot.warnings.append_array(snapshot.progression.restore(shared["progression"], registry))
	snapshot.warnings.append_array(snapshot.difficulty.restore(shared["difficulty"], start, registry))

	var player_ids: Array = raw_players.keys()
	player_ids.sort()
	for raw_player_id in player_ids:
		if not raw_player_id is String and not raw_player_id is StringName:
			snapshot.fatal_error = "Save v4 contains a non-text player ID"
			return snapshot
		var player_id := StringName(raw_player_id)
		if not LocalPlayerProfile.is_valid_player_id(player_id):
			snapshot.fatal_error = "Save v4 contains an invalid player ID: %s" % raw_player_id
			return snapshot
		var record: Variant = raw_players[raw_player_id]
		if not record is Dictionary \
				or not record.get("player_state", null) is Dictionary \
				or not record.get("personal_progression", null) is Dictionary:
			snapshot.fatal_error = "Invalid Save v4 player record: %s" % player_id
			return snapshot
		var player_data: Dictionary = record["player_state"]
		for key in ["player_stats", "equipment"]:
			if player_data.has(key) and not player_data[key] is Dictionary:
				snapshot.fatal_error = "Invalid player save object for %s: %s" % [player_id, key]
				return snapshot
		for key in ["player_inventory", "protected_inventory", "active_effects"]:
			if player_data.has(key) and not player_data[key] is Array:
				snapshot.fatal_error = "Invalid player save array for %s: %s" % [player_id, key]
				return snapshot
		var state := PlayerState.new(resolver)
		snapshot.warnings.append_array(state.restore(player_data, start, instances))
		# Persistent loads resume in settlement. Every detached player must be safe
		# to attach later without restoring a dead scene runtime.
		if state.health <= 0.0:
			state.set_health(1.0)
			snapshot.warnings.append("settlement resume health recovered from 0 to 1: %s" % player_id)
		snapshot.players_by_id[player_id] = state
		snapshot.settlement.append_restore_overflow(state.inventory.take_restore_overflow())
		snapshot.settlement.append_restore_overflow(state.protected_inventory.take_restore_overflow())
		snapshot.warnings.append_array(snapshot.progression.restore_personal(
			player_id, record["personal_progression"], registry
		))

	snapshot.warnings.append_array(snapshot.adventure.restore(shared["adventure"], instances))
	# Restore overflow may have used the ordinary settlement mutation API while
	# staging. Replication revisions are runtime-only and always restart at zero.
	snapshot.settlement.revision = 0
	for warning in snapshot.warnings:
		if warning.begins_with("duplicate instance ignored"):
			snapshot.fatal_error = "Save v4 contains a duplicate item instance: %s" % warning
			return snapshot
	snapshot.player = snapshot.players_by_id.get(p_local_player_id)
	if snapshot.player == null:
		snapshot.fatal_error = "Save v4 local player could not be restored"
	return snapshot
