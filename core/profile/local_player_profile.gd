class_name LocalPlayerProfile
extends RefCounted

const DEFAULT_PATH := "user://local_player_profile.json"
const PROFILE_VERSION := 1
const PLAYER_ID_PREFIX := "player_"
const PLAYER_ID_HEX_LENGTH := 32
const MAX_DISPLAY_NAME_LENGTH := 24

var _path: String
var _player_id: StringName = &""
var _display_name: String = "Player"
var _valid: bool = false
var last_error: String = ""

func _init(path: String = DEFAULT_PATH) -> void:
	_path = path

func load_or_create() -> Error:
	_valid = false
	_player_id = &""
	last_error = ""
	if FileAccess.file_exists(_path):
		var loaded := _load_existing()
		if loaded == OK:
			return OK
		print("[PROFILE] Invalid local profile; generating a replacement")
	return _create_and_save()

func get_player_id() -> StringName:
	return _player_id if _valid else &""

func get_display_name() -> String:
	return _display_name if _valid else ""

func is_valid() -> bool:
	return _valid and is_valid_player_id(_player_id)

func profile_path() -> String:
	return _path

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

func _load_existing() -> Error:
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		last_error = "Cannot read local player profile: %s" % error_string(FileAccess.get_open_error())
		return FileAccess.get_open_error()
	var parser := JSON.new()
	var parse_error := parser.parse(file.get_as_text())
	if parse_error != OK or not parser.data is Dictionary:
		last_error = "Local player profile contains invalid JSON"
		return ERR_PARSE_ERROR
	var payload: Dictionary = parser.data
	var raw_player_id: Variant = payload.get("player_id")
	if not is_valid_player_id(raw_player_id):
		last_error = "Local player profile contains an invalid player_id"
		return ERR_INVALID_DATA
	_player_id = StringName(raw_player_id)
	_display_name = _sanitize_display_name(payload.get("display_name", "Player"))
	_valid = true
	last_error = ""
	return OK

func _create_and_save() -> Error:
	var generated := StringName("%s%s" % [PLAYER_ID_PREFIX, Crypto.new().generate_random_bytes(16).hex_encode()])
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		var open_error := FileAccess.get_open_error()
		last_error = "Cannot write local player profile: %s" % error_string(open_error)
		return open_error
	file.store_string(JSON.stringify({
		"version": PROFILE_VERSION,
		"player_id": String(generated),
		"display_name": _display_name,
	}, "\t"))
	file.flush()
	var write_error := file.get_error()
	if write_error != OK:
		last_error = "Cannot write local player profile: %s" % error_string(write_error)
		return write_error
	_player_id = generated
	_display_name = _sanitize_display_name(_display_name)
	_valid = true
	last_error = ""
	return OK

func _sanitize_display_name(value: Variant) -> String:
	var result := String(value).strip_edges().left(MAX_DISPLAY_NAME_LENGTH) if value is String or value is StringName else ""
	return result if not result.is_empty() else "Player"
