extends Node

signal save_finished(success: bool, message: String)
signal load_finished(success: bool, message: String)

const CURRENT_VERSION := 4
const SAVE_PATH := "user://return_to_cage_save.json"

enum IdentityInspectionStatus {
	SAVE_NOT_FOUND,
	INVALID_SAVE,
	SINGLE_CANDIDATE,
	MULTIPLE_CANDIDATES,
}

func can_save() -> CommandResult:
	if NetworkManager.is_multiplayer_active() and not NetworkManager.is_server():
		return CommandResult.make(false, "Only the host can save a multiplayer session")
	if GameSession.phase != GameSession.Phase.SETTLEMENT or GameSession.adventure.active_session != null:
		return CommandResult.make(false, "Save is only available in the settlement")
	return CommandResult.make(true)

func can_load() -> CommandResult:
	if not NetworkManager.is_local_identity_activated():
		return CommandResult.make(false, "Local player identity is not activated")
	if NetworkManager.is_multiplayer_active():
		if not NetworkManager.is_server():
			return CommandResult.make(false, "Only the host can load a multiplayer session")
		if NetworkManager.players.size() > 1:
			return CommandResult.make(false, "Disconnect remote players before loading a session")
	if GameSession.adventure.active_session != null or GameSession.phase not in [GameSession.Phase.MENU, GameSession.Phase.SETTLEMENT]:
		return CommandResult.make(false, "Load is unavailable during an expedition or respawn")
	return CommandResult.make(true)

func save_game(path: String = SAVE_PATH) -> bool:
	var permission: CommandResult = can_save()
	if not permission.success:
		save_finished.emit(false, permission.message)
		return false
	var envelope: Dictionary = GameSession.export_persistent_state()
	envelope["format_version"] = CURRENT_VERSION
	envelope["saved_at"] = Time.get_datetime_string_from_system(true)
	var json := JSON.stringify(envelope, "  ")
	var temporary := path + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		var message := "Cannot create temporary save: %s" % FileAccess.get_open_error()
		save_finished.emit(false, message)
		return false
	file.store_string(json)
	file.flush()
	var write_error := file.get_error()
	file.close()
	var absolute_temp := ProjectSettings.globalize_path(temporary)
	var absolute_path := ProjectSettings.globalize_path(path)
	if write_error != OK:
		DirAccess.remove_absolute(absolute_temp)
		save_finished.emit(false, "Cannot write temporary save: %s" % error_string(write_error))
		return false
	var absolute_backup := absolute_path + ".bak"
	if FileAccess.file_exists(path + ".bak"):
		var remove_error := DirAccess.remove_absolute(absolute_backup)
		if remove_error != OK:
			DirAccess.remove_absolute(absolute_temp)
			save_finished.emit(false, "Cannot replace save backup: %s" % error_string(remove_error))
			return false
	if FileAccess.file_exists(path):
		var backup_error := DirAccess.rename_absolute(absolute_path, absolute_backup)
		if backup_error != OK:
			DirAccess.remove_absolute(absolute_temp)
			save_finished.emit(false, "Cannot create save backup: %s" % error_string(backup_error))
			return false
	var error := DirAccess.rename_absolute(absolute_temp, absolute_path)
	if error != OK:
		var rollback_error := OK
		if FileAccess.file_exists(path + ".bak"):
			rollback_error = DirAccess.rename_absolute(absolute_backup, absolute_path)
		if FileAccess.file_exists(temporary):
			DirAccess.remove_absolute(absolute_temp)
		var rollback_suffix := "" if rollback_error == OK else "; rollback failed: %s" % error_string(rollback_error)
		save_finished.emit(false, "Atomic save rename failed: %s%s" % [error_string(error), rollback_suffix])
		return false
	save_finished.emit(true, "Game saved")
	return true

func load_game(path: String = SAVE_PATH) -> bool:
	var permission: CommandResult = can_load()
	if not permission.success:
		load_finished.emit(false, permission.message)
		return false
	var read_result := _read_save_dictionary(path)
	if not read_result.success:
		load_finished.emit(false, read_result.error)
		return false
	var envelope: Dictionary = read_result.data
	var migrated := migrate(envelope)
	if migrated.is_empty():
		load_finished.emit(false, "Unsupported save format")
		return false
	if GameSession.get_start_definition() == null:
		load_finished.emit(false, "Cannot load game: invalid start configuration")
		return false
	var snapshot: SessionSnapshot = GameSession.prepare_persistent_restore(migrated)
	if not snapshot.fatal_error.is_empty():
		load_finished.emit(false, snapshot.fatal_error)
		return false
	if not GameSession.apply_persistent_snapshot(snapshot):
		load_finished.emit(false, "Cannot apply the staged Save v4 session")
		return false
	var errors: PackedStringArray = snapshot.warnings
	var message := "Game loaded" if errors.is_empty() else "Game loaded with warnings: %s" % "; ".join(errors)
	load_finished.emit(true, message)
	return true

# Reads only the primary Save v4 file and validates the identity-bearing
# envelope contract. It never migrates, stages domain objects, applies live
# state, writes the save, or changes the local profile.
func inspect_identity_candidates(path: String = SAVE_PATH) -> Dictionary:
	var read_result := _read_save_dictionary(path)
	if not read_result.success:
		var missing: bool = read_result.error_code == ERR_FILE_NOT_FOUND
		return _identity_inspection_result(
			IdentityInspectionStatus.SAVE_NOT_FOUND if missing else IdentityInspectionStatus.INVALID_SAVE,
			read_result.error
		)
	var envelope: Dictionary = read_result.data
	var raw_version: Variant = envelope.get("format_version", null)
	if not SaveData.is_integer(raw_version) or int(raw_version) != CURRENT_VERSION:
		return _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, "Identity recovery requires a primary Save v4 file")
	if not envelope.get("shared", null) is Dictionary or not envelope.get("players", null) is Dictionary:
		return _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, "Invalid Save v4 shared or players object")
	var shared: Dictionary = envelope["shared"]
	for key in ["session", "settlement", "progression", "difficulty", "adventure"]:
		if not shared.get(key, null) is Dictionary:
			return _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, "Invalid Save v4 shared object: %s" % key)
	var raw_players: Dictionary = envelope["players"]
	if raw_players.is_empty():
		return _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, "Save v4 contains no player records")
	var candidate_names: Array[String] = []
	for raw_player_id in raw_players:
		if (not raw_player_id is String and not raw_player_id is StringName) \
				or not LocalPlayerProfile.is_valid_player_id(raw_player_id):
			return _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, "Save v4 contains an invalid player ID")
		var record: Variant = raw_players[raw_player_id]
		if not record is Dictionary \
				or not record.get("player_state", null) is Dictionary \
				or not record.get("personal_progression", null) is Dictionary:
			return _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, "Invalid Save v4 player record: %s" % raw_player_id)
		candidate_names.append(String(raw_player_id))
	candidate_names.sort()
	var candidates: Array[StringName] = []
	for candidate_name in candidate_names:
		candidates.append(StringName(candidate_name))
	var status := IdentityInspectionStatus.SINGLE_CANDIDATE if candidates.size() == 1 \
			else IdentityInspectionStatus.MULTIPLE_CANDIDATES
	var result := _identity_inspection_result(status)
	result.candidates = candidates
	result.saved_at = String(envelope.get("saved_at", "")) if SaveData.is_text(envelope.get("saved_at", "")) else ""
	result.format_version = CURRENT_VERSION
	return result

# Re-reads the primary save and performs the complete existing Save v4 staging
# validation for the explicitly selected identity. No live state is applied.
func validate_identity_candidate(player_id: StringName, path: String = SAVE_PATH) -> Dictionary:
	var result := {
		"success": false,
		"snapshot": null,
		"warnings": PackedStringArray(),
		"error": "",
	}
	if not LocalPlayerProfile.is_valid_player_id(player_id):
		result.error = "Invalid selected player identity"
		return result
	var inspection := inspect_identity_candidates(path)
	if inspection.status not in [IdentityInspectionStatus.SINGLE_CANDIDATE, IdentityInspectionStatus.MULTIPLE_CANDIDATES]:
		result.error = inspection.error
		return result
	if not inspection.candidates.has(player_id):
		result.error = "Save v4 does not contain the selected player identity"
		return result
	# Inspection results are deliberately not authoritative. Re-read before
	# staging to avoid committing a candidate from stale UI state.
	var read_result := _read_save_dictionary(path)
	if not read_result.success:
		result.error = read_result.error
		return result
	var envelope: Dictionary = read_result.data
	var raw_version: Variant = envelope.get("format_version", null)
	if not SaveData.is_integer(raw_version) or int(raw_version) != CURRENT_VERSION:
		result.error = "Identity recovery requires a primary Save v4 file"
		return result
	var snapshot: SessionSnapshot = GameSession.prepare_persistent_restore(envelope, player_id)
	if snapshot == null or not snapshot.fatal_error.is_empty():
		result.error = snapshot.fatal_error if snapshot != null else "Cannot stage Save v4 identity recovery"
		return result
	if snapshot.local_player_id != player_id or snapshot.player == null \
			or snapshot.players_by_id.get(player_id) != snapshot.player:
		result.error = "Save v4 staged a different local player identity"
		return result
	result.success = true
	result.snapshot = snapshot
	result.warnings = snapshot.warnings
	return result

# Caller-driven recovery only: there is no automatic candidate selection. The
# complete save stages first, then the profile performs its disk transaction.
func recover_identity_from_save(
	player_id: StringName,
	path: String = SAVE_PATH
) -> CommandResult:
	var staged := validate_identity_candidate(player_id, path)
	if not staged.success:
		return CommandResult.make(false, staged.error)
	return NetworkManager.commit_local_profile_identity(player_id)

func _read_save_dictionary(path: String) -> Dictionary:
	var result := {
		"success": false,
		"data": {},
		"error_code": ERR_INVALID_DATA,
		"error": "Corrupted save file",
	}
	if not FileAccess.file_exists(path):
		result.error_code = ERR_FILE_NOT_FOUND
		result.error = "Save file does not exist"
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		result.error_code = FileAccess.get_open_error()
		result.error = "Cannot open save"
		return result
	var contents := file.get_as_text()
	file.close()
	var json := JSON.new()
	var parse_error := json.parse(contents)
	if parse_error != OK or not json.data is Dictionary:
		return result
	result.success = true
	result.data = json.data
	result.error_code = OK
	result.error = ""
	return result

func _identity_inspection_result(status: IdentityInspectionStatus, error: String = "") -> Dictionary:
	return {
		"status": status,
		"candidates": Array([], TYPE_STRING_NAME, "", null),
		"saved_at": "",
		"format_version": 0,
		"error": error,
	}

func migrate(envelope: Dictionary) -> Dictionary:
	var raw_version: Variant = envelope.get("format_version", null)
	if not SaveData.is_integer(raw_version):
		return {}
	var version: int = int(raw_version)
	if version <= 3 and (not envelope.has("game_state") or not envelope["game_state"] is Dictionary):
		return {}
	var result: Dictionary = envelope.duplicate(true)
	while version < CURRENT_VERSION:
		match version:
			1:
				result = _migrate_v1_to_v2(result)
			2:
				result = _migrate_v2_to_v3(result)
			3:
				result = _migrate_v3_to_v4(result)
			_:
				return {}
		var next_version: int = int(result.get("format_version", version))
		if next_version <= version:
			return {}
		version = next_version
	if version != CURRENT_VERSION:
		return {}
	if not result.get("shared", null) is Dictionary or not result.get("players", null) is Dictionary:
		return {}
	return result

func _migrate_v1_to_v2(envelope: Dictionary) -> Dictionary:
	var state: Dictionary = envelope.get("game_state", {})
	if not state.has("difficulty_overrides"):
		state["difficulty_overrides"] = {}
	if not state.has("protected_inventory"):
		state["protected_inventory"] = []
	envelope["game_state"] = state
	envelope["format_version"] = 2
	return envelope

func _migrate_v2_to_v3(envelope: Dictionary) -> Dictionary:
	var state: Dictionary = envelope.get("game_state", {})
	for key in ["active_effects", "death_drops", "pending_loot"]:
		if not state.has(key):
			state[key] = []
	envelope["game_state"] = state
	envelope["format_version"] = 3
	return envelope

func _migrate_v3_to_v4(envelope: Dictionary) -> Dictionary:
	var local_player_id := NetworkManager.local_profile_player_id()
	if not LocalPlayerProfile.is_valid_player_id(local_player_id):
		return {}
	var legacy: Dictionary = envelope.get("game_state", {})
	var player_state := _select_keys(legacy, [
		"player_stats", "player_inventory", "equipment", "protected_inventory",
		"active_effects", "survival_state", "player_health", "last_safe_position",
	])
	var result := {
		"format_version": 4,
		"saved_at": envelope.get("saved_at", ""),
		"shared": {
			"session": _select_keys(legacy, ["session_id", "play_time_seconds"]),
			"settlement": _select_keys(legacy, [
				"settlement_storage", "pending_loot", "facility_levels", "resident_states",
			]),
			"progression": _select_keys(legacy, [
				"quests", "unlocked_regions", "unlocked_exits", "unlocked_flags",
				"discovered_escape_points",
			]),
			"difficulty": _select_keys(legacy, ["difficulty_id", "difficulty_overrides"]),
			"adventure": _select_keys(legacy, ["death_drops"]),
		},
		"players": {
			String(local_player_id): {
				"player_state": player_state,
				"personal_progression": {"quests": []},
			},
		},
	}
	return result

func _select_keys(source: Dictionary, keys: Array) -> Dictionary:
	var result: Dictionary = {}
	for key in keys:
		if source.has(key):
			result[key] = source[key]
	return result
