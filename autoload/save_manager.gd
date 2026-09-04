extends Node

signal save_finished(success: bool, message: String)
signal load_finished(success: bool, message: String)

const CURRENT_VERSION := 2
const SAVE_PATH := "user://return_to_cage_save.json"

func save_game(path: String = SAVE_PATH) -> bool:
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
	var errors := GameSession.restore_state(migrated.get("game_state", {}))
	var message := "Game loaded" if errors.is_empty() else "Game loaded with warnings: %s" % "; ".join(errors)
	load_finished.emit(true, message)
	return true

func migrate(envelope: Dictionary) -> Dictionary:
	var version := int(envelope.get("format_version", 1))
	var result := envelope.duplicate(true)
	if version == 1:
		var state: Dictionary = result.get("game_state", {})
		if not state.has("difficulty_overrides"):
			state["difficulty_overrides"] = {}
		if not state.has("protected_inventory"):
			state["protected_inventory"] = []
		result["game_state"] = state
		result["format_version"] = 2
		version = 2
	if version != CURRENT_VERSION:
		return {}
	return result
