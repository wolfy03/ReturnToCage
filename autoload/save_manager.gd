extends Node

signal save_finished(success: bool, message: String)
signal load_finished(success: bool, message: String)

const CURRENT_VERSION := 4
const SAVE_PATH := "user://return_to_cage_save.json"

func can_save() -> CommandResult:
	if NetworkManager.is_multiplayer_active() and not NetworkManager.is_server():
		return CommandResult.make(false, "Only the host can save a multiplayer session")
	if GameSession.phase != GameSession.Phase.SETTLEMENT or GameSession.adventure.active_session != null:
		return CommandResult.make(false, "Save is only available in the settlement")
	return CommandResult.make(true)

func can_load() -> CommandResult:
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
	file.close()
	var absolute_temp := ProjectSettings.globalize_path(temporary)
	var absolute_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute_path + ".bak")
		DirAccess.rename_absolute(absolute_path, absolute_path + ".bak")
	var error := DirAccess.rename_absolute(absolute_temp, absolute_path)
	if error != OK:
		if FileAccess.file_exists(path + ".bak"):
			DirAccess.rename_absolute(absolute_path + ".bak", absolute_path)
		save_finished.emit(false, "Atomic save rename failed: %s" % error_string(error))
		return false
	save_finished.emit(true, "Game saved")
	return true

func load_game(path: String = SAVE_PATH) -> bool:
	var permission: CommandResult = can_load()
	if not permission.success:
		load_finished.emit(false, permission.message)
		return false
	if not FileAccess.file_exists(path):
		load_finished.emit(false, "Save file does not exist")
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		load_finished.emit(false, "Cannot open save")
		return false
	var json := JSON.new()
	var parse_error := json.parse(file.get_as_text())
	if parse_error != OK or not json.data is Dictionary:
		load_finished.emit(false, "Corrupted save file")
		return false
	var envelope: Dictionary = json.data
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

func migrate(envelope: Dictionary) -> Dictionary:
	var raw_version: Variant = envelope.get("format_version", 1)
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
