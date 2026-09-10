extends RefCounted

func run(t: Node) -> void:
	var token := "%s_%s" % [Time.get_ticks_usec(), randi()]
	var profile_path := "user://local_profile_test_%s.json" % token
	_remove(profile_path)

	var created := LocalPlayerProfile.new(profile_path)
	t.assert_equal(created.load_or_create(), OK, "missing local profile is created")
	t.assert_true(created.is_valid(), "created profile exposes a valid persistent identity")
	t.assert_true(LocalPlayerProfile.is_valid_player_id(created.get_player_id()), "generated identity uses the required format")
	t.assert_true(FileAccess.file_exists(profile_path), "created profile is persisted under user data")
	var original_id := created.get_player_id()
	var reloaded := LocalPlayerProfile.new(profile_path)
	t.assert_equal(reloaded.load_or_create(), OK, "existing local profile reloads")
	t.assert_equal(reloaded.get_player_id(), original_id, "profile reload reuses the same persistent identity")

	_write(profile_path, "{invalid json")
	var malformed := LocalPlayerProfile.new(profile_path)
	t.assert_equal(malformed.load_or_create(), OK, "malformed profile JSON is repaired without crashing")
	t.assert_true(malformed.is_valid() and malformed.get_player_id() != original_id, "malformed profile receives a replacement identity")
	_assert_repaired_payload(t, profile_path, malformed.get_player_id(), "malformed profile repair is persisted")

	_write(profile_path, JSON.stringify({"version": LocalPlayerProfile.PROFILE_VERSION + 1, "player_id": String(original_id), "display_name": "Player"}))
	var unsupported := LocalPlayerProfile.new(profile_path)
	t.assert_equal(unsupported._load_existing(), ERR_INVALID_DATA, "unsupported profile version is rejected by the load contract")
	t.assert_equal(unsupported.last_error, "Unsupported local player profile version", "unsupported profile version reports a clear error")
	t.assert_equal(unsupported.load_or_create(), OK, "unsupported profile version is repaired without migration")
	t.assert_true(unsupported.is_valid() and unsupported.get_player_id() != original_id, "unsupported profile version receives a replacement identity")
	_assert_repaired_payload(t, profile_path, unsupported.get_player_id(), "profile version repair is persisted")

	for invalid_version in [null, "1", 1.5]:
		var version_payload := {"player_id": String(original_id), "display_name": "Player"}
		if invalid_version != null:
			version_payload["version"] = invalid_version
		_write(profile_path, JSON.stringify(version_payload))
		var invalid_version_profile := LocalPlayerProfile.new(profile_path)
		t.assert_equal(invalid_version_profile._load_existing(), ERR_INVALID_DATA, "missing, non-numeric, and fractional profile versions are rejected")
		t.assert_equal(invalid_version_profile.last_error, "Unsupported local player profile version", "invalid profile version uses the stable load error")

	for invalid_id in ["", "abc", "player_", "player_0123456789abcdef0123456789abcdeg"]:
		_write(profile_path, JSON.stringify({"version": LocalPlayerProfile.PROFILE_VERSION, "player_id": invalid_id, "display_name": "Player"}))
		var invalid := LocalPlayerProfile.new(profile_path)
		t.assert_equal(invalid.load_or_create(), OK, "invalid profile identity is repaired: %s" % invalid_id)
		t.assert_true(invalid.is_valid(), "repaired profile identity is valid: %s" % invalid_id)
		_assert_repaired_payload(t, profile_path, invalid.get_player_id(), "invalid identity repair is persisted")

	var missing_directory_path := "user://missing_profile_directory_%s/local_player_profile.json" % token
	var unavailable := LocalPlayerProfile.new(missing_directory_path)
	t.assert_true(unavailable.load_or_create() != OK, "profile write failure is reported")
	t.assert_true(not unavailable.is_valid() and unavailable.get_player_id().is_empty(), "write failure never exposes an ephemeral identity")
	t.assert_true(not unavailable.last_error.is_empty(), "profile write failure provides an explicit error")

	t.assert_equal(LocalPlayerProfile.DEFAULT_PATH, "user://local_player_profile.json", "production profile is separate from game saves")
	t.assert_true(NetworkManager.has_valid_local_profile(), "NetworkManager loaded the local persistent profile")
	t.assert_equal(GameSession.get_local_player_id(), NetworkManager.local_profile_player_id(), "offline GameSession uses the persistent profile identity")
	_remove(profile_path)

func _assert_repaired_payload(t: Node, path: String, expected_id: StringName, message: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	var payload: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	t.assert_true(payload is Dictionary and StringName(payload.get("player_id", "")) == expected_id, message)

func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(contents)
		file.flush()

func _remove(path: String) -> void:
	var absolute := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(absolute)
