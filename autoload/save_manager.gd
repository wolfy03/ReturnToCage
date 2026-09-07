extends Node

signal save_finished(success: bool, message: String)
signal load_finished(success: bool, message: String)

const CURRENT_VERSION := 3
const SAVE_PATH := "user://return_to_cage_save.json"

func can_save() -> CommandResult:
	if GameSession.phase != GameSession.Phase.SETTLEMENT or GameSession.adventure.active_session != null:
		return CommandResult.make(false, "Save is only available in the settlement")
	return CommandResult.make(true)

func can_load() -> CommandResult:
	if GameSession.adventure.active_session != null or GameSession.phase not in [GameSession.Phase.MENU, GameSession.Phase.SETTLEMENT]:
		return CommandResult.make(false, "Load is unavailable during an expedition or respawn")
	return CommandResult.make(true)

func save_game(path: String = SAVE_PATH) -> bool:
	var permission: CommandResult = can_save()
	if not permission.success:
		save_finished.emit(false, permission.message)
		return false
	var envelope := {"format_version": CURRENT_VERSION, "saved_at": Time.get_datetime_string_from_system(true), "game_state": GameSession.export_state()}
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
	var snapshot: SessionSnapshot = GameSession.prepare_restore(migrated.get("game_state", {}))
	if not snapshot.fatal_error.is_empty():
		load_finished.emit(false, snapshot.fatal_error)
		return false
	GameSession.apply_snapshot(snapshot)
	var errors: PackedStringArray = snapshot.warnings
	var message := "Game loaded" if errors.is_empty() else "Game loaded with warnings: %s" % "; ".join(errors)
	load_finished.emit(true, message)
	return true

func migrate(envelope: Dictionary) -> Dictionary:
	var raw_version: Variant = envelope.get("format_version", 1)
	if not SaveData.is_number(raw_version) or float(raw_version) != int(raw_version):
		return {}
	if not envelope.has("game_state") or not envelope["game_state"] is Dictionary:
		return {}
	var version: int = int(raw_version)
	var result: Dictionary = envelope.duplicate(true)
	while version < CURRENT_VERSION:
		match version:
			1:
				result = _migrate_v1_to_v2(result)
			2:
				result = _migrate_v2_to_v3(result)
			_:
				return {}
		var next_version: int = int(result.get("format_version", version))
		if next_version <= version:
			return {}
		version = next_version
	if version != CURRENT_VERSION:
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
