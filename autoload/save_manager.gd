extends Node

signal save_finished(success: bool, message: String)
signal load_finished(success: bool, message: String)

const CURRENT_VERSION := 5
const SAVE_PATH := "user://return_to_cage_save.json"

enum SaveSource {
	NONE,
	PRIMARY,
	BACKUP,
}

const BACKUP_SUFFIX := ".bak"
const TEMP_SUFFIX := ".tmp"
const BACKUP_ROLLBACK_SUFFIX := ".bak.rollback"
const CORRUPT_SUFFIX := ".corrupt"
const BACKUP_RECOVERY_NOTICE := "Primary save is missing or corrupted. A valid backup was found."

# Failure-injection seam for the save transaction tests. The hook receives the
# operation name and returns true to make that operation fail before it runs.
const OP_TEMP_OPEN := &"temp_open"
const OP_TEMP_WRITE := &"temp_write"
const OP_TEMP_VALIDATE := &"temp_validate"
const OP_BACKUP_PRESERVE := &"backup_preserve"
const OP_BACKUP_CREATE := &"backup_create"
const OP_CORRUPT_PRESERVE := &"corrupt_preserve"
const OP_PRIMARY_INSTALL := &"primary_install"
const OP_ROLLBACK := &"rollback"

var last_load_result: Dictionary = {}
var _failure_hook: Callable

enum IdentityInspectionStatus {
	SAVE_NOT_FOUND,
	INVALID_SAVE,
	SINGLE_CANDIDATE,
	MULTIPLE_CANDIDATES,
}

func can_save() -> CommandResult:
	if NetworkManager.is_host_restoring():
		return CommandResult.make(false, "Save is unavailable while the host session is restoring")
	if NetworkManager.is_multiplayer_active() and not NetworkManager.is_server():
		return CommandResult.make(false, "Only the host can save a multiplayer session")
	if GameSession.phase != GameSession.Phase.SETTLEMENT or GameSession.has_active_player_adventures():
		return CommandResult.make(false, "Save is only available in the settlement")
	return CommandResult.make(true)

func can_load() -> CommandResult:
	if not NetworkManager.is_local_identity_activated():
		return CommandResult.make(false, "Local player identity is not activated")
	if NetworkManager.is_host_restoring():
		return CommandResult.make(false, "Load is unavailable while the host session is restoring")
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
	var staged := GameSession.prepare_persistent_restore(envelope)
	if not staged.fatal_error.is_empty():
		save_finished.emit(false, staged.fatal_error)
		return false
	var transaction := _write_save_transaction(path, JSON.stringify(envelope, "  "))
	save_finished.emit(transaction.success, transaction.message)
	return transaction.success

func load_game(path: String = SAVE_PATH) -> bool:
	var permission: CommandResult = can_load()
	if not permission.success:
		_finish_load(false, permission.message)
		return false
	var prepared := prepare_load(path)
	if not prepared.success:
		_finish_load(false, prepared.error, prepared)
		return false
	var snapshot: SessionSnapshot = prepared.snapshot
	if not GameSession.apply_persistent_snapshot(snapshot):
		_finish_load(false, "Cannot apply the staged Save v5 session", prepared)
		return false
	var errors: PackedStringArray = prepared.warnings
	var message := "Game loaded" if errors.is_empty() else "Game loaded with warnings: %s" % "; ".join(errors)
	if prepared.recovered_from_backup:
		message = "%s Game loaded from backup. %s" % [BACKUP_RECOVERY_NOTICE, message]
	# The HUD status line reads last_message, so a backup recovery stays visible
	# after the menu has been replaced by the Settlement scene.
	GameSession.last_message = message
	_finish_load(true, message, prepared)
	return true

func _finish_load(success: bool, message: String, prepared: Dictionary = {}) -> void:
	last_load_result = {
		"success": success,
		"message": message,
		"source": prepared.get("source", SaveSource.NONE),
		"recovered_from_backup": bool(prepared.get("recovered_from_backup", false)),
		"primary_error": String(prepared.get("primary_error", "")),
	}
	load_finished.emit(success, message)

# Reads, migrates, and fully validates a save into a detached SessionSnapshot.
# It never mutates the live GameSession or opens multiplayer transport. Offline
# Load applies the result immediately; Host Saved Game applies it only after a
# gated server transport has opened successfully. The file is chosen by
# resolve_save_candidate(): primary first, backup only if primary is invalid.
func prepare_load(
	path: String = SAVE_PATH,
	selected_player_id: StringName = &""
) -> Dictionary:
	var result := _staging_result()
	var candidate := resolve_save_candidate(path)
	_copy_candidate_origin(candidate, result)
	if not candidate.valid:
		result.error = candidate.error
		return result
	var player_id := selected_player_id if not selected_player_id.is_empty() else NetworkManager.local_profile_player_id()
	var snapshot := _stage_candidate(candidate, player_id)
	if not snapshot.fatal_error.is_empty():
		result.error = snapshot.fatal_error
		return result
	result.success = true
	result.snapshot = snapshot
	result.warnings = snapshot.warnings
	return result

# Identity inspection uses the same fully validated candidate as Load and
# Host Saved Game. It never writes the save, changes the local profile, or
# applies live state. The returned source/fingerprint pin the inspected file so
# a later validate/recover call cannot silently stage a different file.
func inspect_identity_candidates(path: String = SAVE_PATH) -> Dictionary:
	var candidate := resolve_save_candidate(path)
	if not candidate.valid:
		var result := _identity_inspection_result(
			IdentityInspectionStatus.SAVE_NOT_FOUND if candidate.missing else IdentityInspectionStatus.INVALID_SAVE,
			candidate.error
		)
		_copy_candidate_origin(candidate, result)
		return result
	var version_error := _identity_version_error(candidate)
	if not version_error.is_empty():
		var rejected := _identity_inspection_result(IdentityInspectionStatus.INVALID_SAVE, version_error)
		_copy_candidate_origin(candidate, rejected)
		return rejected
	var candidates: Array[StringName] = candidate.player_ids
	var status := IdentityInspectionStatus.SINGLE_CANDIDATE if candidates.size() == 1 \
			else IdentityInspectionStatus.MULTIPLE_CANDIDATES
	var result := _identity_inspection_result(status)
	result.candidates = candidates.duplicate()
	result.saved_at = candidate.saved_at
	result.format_version = candidate.format_version
	_copy_candidate_origin(candidate, result)
	return result

# Resolves the candidate again and performs the complete Save v5 staging for the
# explicitly selected identity. No live state is applied. When `expected` is an
# inspection result, the candidate must still be the same source and bytes.
func validate_identity_candidate(
	player_id: StringName,
	path: String = SAVE_PATH,
	expected: Dictionary = {}
) -> Dictionary:
	var result := _staging_result()
	if not LocalPlayerProfile.is_valid_player_id(player_id):
		result.error = "Invalid selected player identity"
		return result
	var candidate := resolve_save_candidate(path)
	_copy_candidate_origin(candidate, result)
	if not candidate.valid:
		result.error = candidate.error
		return result
	if not expected.is_empty() and (
			int(expected.get("source", SaveSource.NONE)) != int(candidate.source)
			or String(expected.get("fingerprint", "")) != candidate.fingerprint):
		result.error = "Save changed since identity inspection; inspect it again"
		return result
	var version_error := _identity_version_error(candidate)
	if not version_error.is_empty():
		result.error = version_error
		return result
	if not candidate.player_ids.has(player_id):
		result.error = "Save does not contain the selected player identity"
		return result
	var snapshot := _stage_candidate(candidate, player_id)
	if snapshot == null or not snapshot.fatal_error.is_empty():
		result.error = snapshot.fatal_error if snapshot != null else "Cannot stage save identity recovery"
		return result
	if snapshot.local_player_id != player_id or snapshot.player == null \
			or snapshot.players_by_id.get(player_id) != snapshot.player:
		result.error = "Save staged a different local player identity"
		return result
	result.success = true
	result.snapshot = snapshot
	result.warnings = snapshot.warnings
	return result

# Caller-driven recovery only: there is no automatic candidate selection. The
# complete save stages first, then the profile performs its disk transaction.
func recover_identity_from_save(
	player_id: StringName,
	path: String = SAVE_PATH,
	expected: Dictionary = {}
) -> CommandResult:
	var staged := validate_identity_candidate(player_id, path, expected)
	if not staged.success:
		return CommandResult.make(false, staged.error)
	return NetworkManager.commit_local_profile_identity(player_id)

func backup_path(path: String = SAVE_PATH) -> String:
	return path + BACKUP_SUFFIX

# Candidate policy shared by every entry point:
#   1. Primary is used whenever it passes the full validation pipeline, even if
#      it does not contain the identity the caller wants. A valid primary never
#      falls back to a backup with a different identity.
#   2. Backup is considered only when primary is missing or invalid, and must
#      pass the same pipeline. `.tmp` and rollback/corrupt copies are never
#      candidates.
# Validation is identity-independent (every player record is staged), so the
# chosen file does not depend on which identity is asked for later.
func resolve_save_candidate(path: String = SAVE_PATH) -> Dictionary:
	var primary := _validate_save_file(path, SaveSource.PRIMARY)
	if primary.valid:
		return primary
	var backup := _validate_save_file(backup_path(path), SaveSource.BACKUP)
	if backup.valid:
		backup.recovered_from_backup = true
		backup.primary_error = primary.error
		backup.notice = BACKUP_RECOVERY_NOTICE
		return backup
	var failed := _candidate_result(path, SaveSource.NONE)
	failed.missing = primary.missing and backup.missing
	failed.primary_error = primary.error
	if backup.missing:
		failed.error = primary.error
		failed.error_code = primary.error_code
	else:
		failed.error = "Primary save: %s; backup save: %s" % [primary.error, backup.error]
		failed.error_code = ERR_INVALID_DATA
	return failed

func set_failure_hook_for_tests(hook: Callable) -> void:
	_failure_hook = hook

func _validate_save_file(file_path: String, source: SaveSource) -> Dictionary:
	var result := _candidate_result(file_path, source)
	var read_result := _read_save_dictionary(file_path)
	if not read_result.success:
		result.missing = read_result.error_code == ERR_FILE_NOT_FOUND
		result.error = read_result.error
		result.error_code = read_result.error_code
		return result
	result.fingerprint = read_result.fingerprint
	var envelope: Dictionary = read_result.data
	var raw_version: Variant = envelope.get("format_version", null)
	if not SaveData.is_integer(raw_version) or int(raw_version) < 1 or int(raw_version) > CURRENT_VERSION:
		result.error = "Unsupported save format"
		return result
	result.format_version = int(raw_version)
	result.saved_at = String(envelope.get("saved_at", "")) if SaveData.is_text(envelope.get("saved_at", "")) else ""
	if GameSession.get_start_definition() == null:
		result.error = "Cannot load game: invalid start configuration"
		return result
	var migrated := migrate(envelope)
	if migrated.is_empty():
		result.error = "Unsupported save format"
		return result
	var raw_players: Dictionary = migrated["players"]
	if raw_players.is_empty():
		result.error = "Save contains no player records"
		return result
	var names: Array[String] = []
	for raw_player_id in raw_players:
		if (not raw_player_id is String and not raw_player_id is StringName) \
				or not LocalPlayerProfile.is_valid_player_id(raw_player_id):
			result.error = "Save contains an invalid player ID"
			return result
		names.append(String(raw_player_id))
	names.sort()
	var player_ids: Array[StringName] = []
	for player_name in names:
		player_ids.append(StringName(player_name))
	# Full staging validates the shared state and every player record, item
	# instance registry and reference, not just the probed local record.
	var legacy: bool = int(result.format_version) < CURRENT_VERSION
	var probe := GameSession.prepare_persistent_restore(migrated.duplicate(true), player_ids[0], legacy)
	if probe == null or not probe.fatal_error.is_empty():
		result.error = probe.fatal_error if probe != null else "Cannot stage save"
		return result
	result.valid = true
	result.error = ""
	result.error_code = OK
	result.migrated = migrated
	result.player_ids = player_ids
	result.legacy = legacy
	result.probe_player_id = player_ids[0]
	result.probe_snapshot = probe
	return result

func _stage_candidate(candidate: Dictionary, player_id: StringName) -> SessionSnapshot:
	if player_id == candidate.probe_player_id and candidate.probe_snapshot != null:
		return candidate.probe_snapshot
	return GameSession.prepare_persistent_restore(candidate.migrated.duplicate(true), player_id, candidate.legacy)

func _identity_version_error(candidate: Dictionary) -> String:
	if candidate.format_version not in [4, CURRENT_VERSION]:
		return "Identity recovery requires a Save v4/v5 file"
	return ""

func _candidate_result(file_path: String, source: SaveSource) -> Dictionary:
	return {
		"valid": false,
		"source": source,
		"path": file_path,
		"missing": false,
		"error": "",
		"error_code": ERR_INVALID_DATA,
		"fingerprint": "",
		"format_version": 0,
		"saved_at": "",
		"migrated": {},
		"player_ids": Array([], TYPE_STRING_NAME, "", null),
		"legacy": false,
		"probe_player_id": &"",
		"probe_snapshot": null,
		"recovered_from_backup": false,
		"primary_error": "",
		"notice": "",
	}

func _staging_result() -> Dictionary:
	return {
		"success": false,
		"snapshot": null,
		"warnings": PackedStringArray(),
		"error": "",
		"source": SaveSource.NONE,
		"recovered_from_backup": false,
		"primary_error": "",
		"notice": "",
		"fingerprint": "",
	}

func _copy_candidate_origin(candidate: Dictionary, target: Dictionary) -> void:
	for key in ["source", "recovered_from_backup", "primary_error", "notice", "fingerprint"]:
		target[key] = candidate[key]

# Save transaction. Invariants:
#   * The new data is written to `.tmp`, flushed, read back and fully validated
#     before any existing file is touched.
#   * A valid primary is rotated to `.bak`; the previous `.bak` is moved aside to
#     `.bak.rollback` (not deleted) until the new primary is installed.
#   * An invalid primary is never rotated into `.bak` (that would replace the
#     last good copy); it is preserved as `.corrupt` and `.bak` is kept.
#   * Every failure restores the files that were moved, so at least one
#     previously valid copy remains reachable through resolve_save_candidate().
# flush() hands data to the OS; it is not an fsync of the file or directory, so
# this protects against crashes and failed operations, not power loss.
func _write_save_transaction(path: String, json: String) -> Dictionary:
	var temporary := path + TEMP_SUFFIX
	var backup := backup_path(path)
	var backup_rollback := path + BACKUP_ROLLBACK_SUFFIX
	var corrupt := path + CORRUPT_SUFFIX
	if FileAccess.file_exists(temporary) and _remove(temporary, &"") != OK:
		return _transaction_failure("Cannot clear stale temporary save")
	if _should_fail(OP_TEMP_OPEN):
		return _transaction_failure("Cannot create temporary save: %s" % error_string(ERR_CANT_CREATE))
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if file == null:
		return _transaction_failure("Cannot create temporary save: %s" % error_string(FileAccess.get_open_error()))
	file.store_string(json)
	file.flush()
	var write_error: Error = ERR_FILE_CANT_WRITE if _should_fail(OP_TEMP_WRITE) else file.get_error()
	file.close()
	if write_error != OK:
		_remove(temporary, &"")
		return _transaction_failure("Cannot write temporary save: %s" % error_string(write_error))
	var written := _validate_save_file(temporary, SaveSource.NONE)
	if _should_fail(OP_TEMP_VALIDATE) or not written.valid or _read_text(temporary) != json:
		_remove(temporary, &"")
		return _transaction_failure("Temporary save failed verification: %s" % (written.error if not written.valid else "content mismatch"))
	var primary_exists := FileAccess.file_exists(path)
	var primary_valid: bool = primary_exists and _validate_save_file(path, SaveSource.PRIMARY).valid
	if not primary_exists:
		return _install_primary(temporary, path, "", "")
	if not primary_valid:
		# Keep the existing backup; it may be the only good copy.
		if FileAccess.file_exists(corrupt) and _remove(corrupt, &"") != OK:
			_remove(temporary, &"")
			return _transaction_failure("Cannot clear previous corrupt save copy")
		if _rename(path, corrupt, OP_CORRUPT_PRESERVE) != OK:
			_remove(temporary, &"")
			return _transaction_failure("Cannot preserve corrupted primary save")
		return _install_primary(temporary, path, corrupt, "")
	var had_backup := FileAccess.file_exists(backup)
	if had_backup:
		if FileAccess.file_exists(backup_rollback) and _remove(backup_rollback, &"") != OK:
			_remove(temporary, &"")
			return _transaction_failure("Cannot clear stale backup rollback copy")
		var preserve_error := _rename(backup, backup_rollback, OP_BACKUP_PRESERVE)
		if preserve_error != OK:
			_remove(temporary, &"")
			return _transaction_failure("Cannot replace save backup: %s" % error_string(preserve_error))
	var backup_error := _rename(path, backup, OP_BACKUP_CREATE)
	if backup_error != OK:
		var restore_detail := _restore(backup_rollback, backup) if had_backup else ""
		_remove(temporary, &"")
		return _transaction_failure("Cannot create save backup: %s%s" % [error_string(backup_error), restore_detail])
	var installed := _install_primary(temporary, path, backup, backup_rollback if had_backup else "")
	if installed.success and had_backup and FileAccess.file_exists(backup_rollback):
		# The previous generation is no longer needed once the new primary and the
		# rotated backup are both in place. A failed cleanup is retried next save.
		_remove(backup_rollback, &"")
	return installed

# Installs the verified temporary as primary. On failure the file that was moved
# out of the primary slot (`displaced`) returns to it, and the backup generation
# set aside in `backup_rollback` returns to `.bak`.
func _install_primary(temporary: String, path: String, displaced: String, backup_rollback: String) -> Dictionary:
	var install_error := _rename(temporary, path, OP_PRIMARY_INSTALL)
	if install_error == OK:
		return {"success": true, "message": "Game saved"}
	var details := ""
	if not displaced.is_empty():
		details += _restore(displaced, path)
	if not backup_rollback.is_empty():
		details += _restore(backup_rollback, displaced)
	_remove(temporary, &"")
	return _transaction_failure("Atomic save rename failed: %s%s" % [error_string(install_error), details])

func _restore(from_path: String, to_path: String) -> String:
	if not FileAccess.file_exists(from_path):
		return ""
	var error := _rename(from_path, to_path, OP_ROLLBACK)
	return "" if error == OK else "; rollback failed: %s" % error_string(error)

func _transaction_failure(message: String) -> Dictionary:
	return {"success": false, "message": message}

func _rename(from_path: String, to_path: String, operation: StringName) -> Error:
	if _should_fail(operation):
		return ERR_CANT_CREATE
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(from_path), ProjectSettings.globalize_path(to_path))

func _remove(file_path: String, operation: StringName) -> Error:
	if _should_fail(operation):
		return ERR_CANT_OPEN
	return DirAccess.remove_absolute(ProjectSettings.globalize_path(file_path))

func _should_fail(operation: StringName) -> bool:
	return not operation.is_empty() and _failure_hook.is_valid() and bool(_failure_hook.call(operation))

func _read_text(file_path: String) -> String:
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _read_save_dictionary(path: String) -> Dictionary:
	var result := {
		"success": false,
		"data": {},
		"fingerprint": "",
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
	result.fingerprint = contents.sha256_text()
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
			4:
				result = _migrate_v4_to_v5(result)
			_:
				return {}
		if result.is_empty():
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

func _migrate_v4_to_v5(envelope: Dictionary) -> Dictionary:
	if not envelope.get("shared") is Dictionary or not envelope.get("players") is Dictionary:
		return {}
	var start := GameSession.get_start_definition()
	if start == null or not envelope.shared.get("settlement") is Dictionary:
		return {}
	for record in envelope.players.values():
		if not record is Dictionary or not record.get("player_state") is Dictionary:
			return {}
		for key in ["player_inventory", "protected_inventory"]:
			var capacity := start.inventory_capacity if key == "player_inventory" else start.protected_capacity
			var layout := _index_legacy_inventory(record.player_state.get(key, []), capacity)
			if layout.is_empty():
				return {}
			record.player_state[key] = layout
	var storage := _index_legacy_inventory(envelope.shared.settlement.get("settlement_storage", []), start.storage_capacity)
	if storage.is_empty():
		return {}
	envelope.shared.settlement.settlement_storage = storage
	envelope.format_version = 5
	return envelope

func _index_legacy_inventory(raw: Variant, configured_capacity: int) -> Dictionary:
	if not raw is Array or raw.size() > InventoryModel.MAX_CAPACITY:
		return {}
	var slots: Array[Dictionary] = []
	for index in raw.size():
		slots.append({"index": index, "stack": raw[index]})
	return {"capacity": maxi(configured_capacity, raw.size()), "slots": slots}
