class_name LocalPlayerProfile
extends RefCounted

enum LoadStatus {
	NONE,
	VALID_PRIMARY,
	NEW_PROFILE_CREATED,
	RECOVERED_FROM_BACKUP,
	IDENTITY_RECOVERY_REQUIRED,
	FAILED,
}

const DEFAULT_PATH := "user://local_player_profile.json"
const PROFILE_VERSION := 1
const PLAYER_ID_PREFIX := "player_"
const PLAYER_ID_HEX_LENGTH := 32
const MAX_DISPLAY_NAME_LENGTH := 24

# Narrow failure-injection seam used by profile writer unit tests. A hook passed
# to _init returns true for the operation it wants to fail.
const OP_TEMP_OPEN := &"temp_open"
const OP_TEMP_WRITE := &"temp_write"
const OP_TEMP_VALIDATE := &"temp_validate"
const OP_BACKUP_CREATE := &"backup_create"
const OP_PRIMARY_REPLACE := &"primary_replace"
const OP_ROLLBACK := &"rollback"

var _path: String
var _player_id: StringName = &""
var _display_name: String = "Player"
var _valid: bool = false
var _failure_hook: Callable

var load_status: LoadStatus = LoadStatus.NONE
var last_error: String = ""
var primary_exists: bool = false
var backup_exists: bool = false
var primary_error: String = ""
var backup_error: String = ""

func _init(path: String = DEFAULT_PATH, failure_hook: Callable = Callable()) -> void:
	_path = path
	_failure_hook = failure_hook

func load_or_create() -> Error:
	_reset_load_state()
	primary_exists = FileAccess.file_exists(_path)
	backup_exists = FileAccess.file_exists(backup_path())
	var primary := _read_profile_file(_path)
	var backup := _read_profile_file(backup_path())
	primary_error = primary.error
	backup_error = backup.error

	if primary.success:
		_activate(primary.player_id, primary.display_name, LoadStatus.VALID_PRIMARY)
		if not backup.success or backup.player_id != primary.player_id \
				or backup.display_name != primary.display_name:
			var rebuild_error := _install_profile_copy(backup_path(), primary.player_id, primary.display_name, OP_BACKUP_CREATE)
			if rebuild_error != OK:
				# A valid primary remains sufficient to use the identity. Preserve the
				# writer detail so a future UI can report degraded redundancy.
				print("[PROFILE] Loaded primary profile; backup rebuild failed: %s" % last_error)
			else:
				print("[PROFILE] Rebuilt missing or stale profile backup")
		return OK

	if backup.success:
		var recovery_error := _persist_identity(backup.player_id, backup.display_name)
		if recovery_error != OK:
			load_status = LoadStatus.FAILED
			print("[PROFILE] Profile recovery persistence failed: %s" % last_error)
			return recovery_error
		_activate(backup.player_id, backup.display_name, LoadStatus.RECOVERED_FROM_BACKUP)
		print("[PROFILE] Recovered profile from backup")
		return OK

	if not primary_exists and not backup_exists:
		var generated := _generate_player_id()
		var create_error := _persist_identity(generated, "Player")
		if create_error != OK:
			load_status = LoadStatus.FAILED
			print("[PROFILE] Profile persistence failed: %s" % last_error)
			return create_error
		_activate(generated, "Player", LoadStatus.NEW_PROFILE_CREATED)
		print("[PROFILE] Created primary and backup profiles")
		return OK

	load_status = LoadStatus.IDENTITY_RECOVERY_REQUIRED
	last_error = "Local player identity recovery is required (primary: %s; backup: %s)" % [
		primary_error,
		backup_error,
	]
	print("[PROFILE] Detected unrecoverable profile files")
	return ERR_INVALID_DATA

# Persists an explicitly selected identity for future recovery flows. Live
# state is changed only after both redundant copies are installed and verified.
func commit_identity(player_id: StringName, display_name: String = "Player") -> Error:
	if not is_valid_player_id(player_id):
		last_error = "Cannot commit an invalid local player identity"
		return ERR_INVALID_PARAMETER
	var safe_name := _sanitize_display_name(display_name)
	var result := _persist_identity(player_id, safe_name)
	if result != OK:
		return result
	_activate(player_id, safe_name, LoadStatus.VALID_PRIMARY)
	return OK

func get_player_id() -> StringName:
	return _player_id if _valid else &""

func get_display_name() -> String:
	return _display_name if _valid else ""

func is_valid() -> bool:
	return _valid and is_valid_player_id(_player_id)

func profile_path() -> String:
	return _path

func backup_path() -> String:
	return _path + ".bak"

func temporary_path() -> String:
	return _path + ".tmp"

static func is_valid_player_id(value: Variant) -> bool:
	if not value is String and not value is StringName:
		return false
	var text := String(value)
	if text.length() != PLAYER_ID_PREFIX.length() + PLAYER_ID_HEX_LENGTH \
			or not text.begins_with(PLAYER_ID_PREFIX):
		return false
	var suffix := text.substr(PLAYER_ID_PREFIX.length())
	for character in suffix:
		if character not in "0123456789abcdef":
			return false
	return true

func _reset_load_state() -> void:
	_valid = false
	_player_id = &""
	_display_name = "Player"
	load_status = LoadStatus.NONE
	last_error = ""
	primary_exists = false
	backup_exists = false
	primary_error = ""
	backup_error = ""

func _activate(player_id: StringName, display_name: String, status: LoadStatus) -> void:
	_player_id = player_id
	_display_name = _sanitize_display_name(display_name)
	_valid = true
	load_status = status
	last_error = ""

func _read_profile_file(path: String) -> Dictionary:
	var result := {
		"success": false,
		"player_id": &"",
		"display_name": "Player",
		"error_code": ERR_INVALID_DATA,
		"error": "",
	}
	if not FileAccess.file_exists(path):
		result.error_code = ERR_FILE_NOT_FOUND
		result.error = "Profile file does not exist"
		return result
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var open_error := FileAccess.get_open_error()
		result.error_code = open_error
		result.error = "Cannot read profile file: %s" % error_string(open_error)
		return result
	var contents := file.get_as_text()
	file.close()
	var parser := JSON.new()
	var parse_error := parser.parse(contents)
	if parse_error != OK or not parser.data is Dictionary:
		result.error_code = ERR_PARSE_ERROR
		result.error = "Profile file contains invalid JSON"
		return result
	var payload: Dictionary = parser.data
	var raw_version: Variant = payload.get("version")
	# JSON represents numbers as floats in Godot. Accept exact integer-equivalent
	# v1 values only; strings, fractional values, and future versions are invalid.
	if (not raw_version is int and not raw_version is float) \
			or not is_equal_approx(float(raw_version), float(int(raw_version))) \
			or int(raw_version) != PROFILE_VERSION:
		result.error = "Unsupported local player profile version"
		return result
	var raw_player_id: Variant = payload.get("player_id")
	if not is_valid_player_id(raw_player_id):
		result.error = "Profile file contains an invalid player_id"
		return result
	result.success = true
	result.player_id = StringName(raw_player_id)
	result.display_name = _sanitize_display_name(payload.get("display_name", "Player"))
	result.error_code = OK
	result.error = ""
	return result

func _persist_identity(player_id: StringName, display_name: String) -> Error:
	# Install the redundant copy first. If primary replacement later fails, the
	# previous primary is rolled back and remains canonical on the next load.
	var backup_result := _install_profile_copy(backup_path(), player_id, display_name, OP_BACKUP_CREATE)
	if backup_result != OK:
		return backup_result
	var primary_result := _install_profile_copy(_path, player_id, display_name, OP_PRIMARY_REPLACE)
	if primary_result != OK:
		return primary_result
	var primary := _read_profile_file(_path)
	var backup := _read_profile_file(backup_path())
	if not primary.success or not backup.success or primary.player_id != player_id \
			or backup.player_id != player_id:
		last_error = "TEMP_VALIDATE_FAILED: installed profile copies did not verify"
		return ERR_INVALID_DATA
	return OK

func _install_profile_copy(target_path: String, player_id: StringName, display_name: String, failure_operation: StringName) -> Error:
	var temp_result := _write_validated_temporary(player_id, display_name)
	if temp_result != OK:
		return temp_result
	var absolute_target := ProjectSettings.globalize_path(target_path)
	var absolute_temp := ProjectSettings.globalize_path(temporary_path())
	var rollback_path := target_path + ".rollback"
	var absolute_rollback := ProjectSettings.globalize_path(rollback_path)
	if FileAccess.file_exists(rollback_path):
		var cleanup_error := DirAccess.remove_absolute(absolute_rollback)
		if cleanup_error != OK:
			_remove_temporary()
			last_error = "%s: cannot clear stale rollback file: %s" % [_failure_label(failure_operation), error_string(cleanup_error)]
			return cleanup_error
	var had_target := FileAccess.file_exists(target_path)
	if had_target:
		var preserve_error := DirAccess.rename_absolute(absolute_target, absolute_rollback)
		if preserve_error != OK:
			_remove_temporary()
			last_error = "%s: cannot preserve existing profile: %s" % [_failure_label(failure_operation), error_string(preserve_error)]
			return preserve_error
	var install_error := ERR_CANT_CREATE if _should_fail(failure_operation) \
			else DirAccess.rename_absolute(absolute_temp, absolute_target)
	if install_error != OK:
		return _handle_install_failure(target_path, rollback_path, had_target, install_error, failure_operation)
	var installed := _read_profile_file(target_path)
	if not installed.success or installed.player_id != player_id:
		if FileAccess.file_exists(target_path):
			DirAccess.remove_absolute(absolute_target)
		return _handle_install_failure(target_path, rollback_path, had_target, ERR_INVALID_DATA, failure_operation)
	if had_target and FileAccess.file_exists(rollback_path):
		DirAccess.remove_absolute(absolute_rollback)
	last_error = ""
	return OK

func _write_validated_temporary(player_id: StringName, display_name: String) -> Error:
	_remove_temporary()
	if _should_fail(OP_TEMP_OPEN):
		last_error = "TEMP_OPEN_FAILED: injected failure"
		return ERR_CANT_OPEN
	var file := FileAccess.open(temporary_path(), FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		last_error = "TEMP_OPEN_FAILED: %s" % error_string(open_error)
		return open_error
	file.store_string(JSON.stringify({
		"version": PROFILE_VERSION,
		"player_id": String(player_id),
		"display_name": _sanitize_display_name(display_name),
	}, "\t"))
	file.flush()
	var write_error: Error = ERR_FILE_CANT_WRITE if _should_fail(OP_TEMP_WRITE) else file.get_error()
	file.close()
	if write_error != OK:
		_remove_temporary()
		last_error = "TEMP_WRITE_FAILED: %s" % error_string(write_error)
		return write_error
	if _should_fail(OP_TEMP_VALIDATE):
		_remove_temporary()
		last_error = "TEMP_VALIDATE_FAILED: injected failure"
		return ERR_INVALID_DATA
	var verified := _read_profile_file(temporary_path())
	if not verified.success or verified.player_id != player_id:
		_remove_temporary()
		last_error = "TEMP_VALIDATE_FAILED: %s" % verified.error
		return ERR_INVALID_DATA
	return OK

func _handle_install_failure(target_path: String, rollback_path: String, had_target: bool, install_error: Error, failure_operation: StringName) -> Error:
	_remove_temporary()
	var rollback_error := OK
	if had_target and FileAccess.file_exists(rollback_path):
		rollback_error = ERR_CANT_CREATE if _should_fail(OP_ROLLBACK) else DirAccess.rename_absolute(
			ProjectSettings.globalize_path(rollback_path),
			ProjectSettings.globalize_path(target_path)
		)
	var message := "%s: %s" % [_failure_label(failure_operation), error_string(install_error)]
	if rollback_error != OK:
		message += "; ROLLBACK_FAILED: %s" % error_string(rollback_error)
	last_error = message
	return install_error if rollback_error == OK else rollback_error

func _remove_temporary() -> void:
	if FileAccess.file_exists(temporary_path()):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(temporary_path()))

func _should_fail(operation: StringName) -> bool:
	return _failure_hook.is_valid() and bool(_failure_hook.call(operation))

func _failure_label(operation: StringName) -> String:
	return "BACKUP_CREATE_FAILED" if operation == OP_BACKUP_CREATE else "PRIMARY_REPLACE_FAILED"

func _generate_player_id() -> StringName:
	return StringName("%s%s" % [PLAYER_ID_PREFIX, Crypto.new().generate_random_bytes(16).hex_encode()])

func _sanitize_display_name(value: Variant) -> String:
	var result := String(value).strip_edges().left(MAX_DISPLAY_NAME_LENGTH) if value is String or value is StringName else ""
	return result if not result.is_empty() else "Player"
