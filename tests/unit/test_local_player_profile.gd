extends RefCounted

const PLAYER_A := &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const PLAYER_B := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

func run(t: Node) -> void:
	var token := "%s_%s" % [Time.get_ticks_usec(), randi()]
	_test_first_creation_and_reuse(t, _path(token, "create"))
	_test_primary_backup_policy(t, token)
	_test_corruption_evidence(t, token)
	_test_validation_contract(t, token)
	_test_atomic_writer_failures(t, token)
	_test_override_path_contract(t, token)

	t.assert_equal(LocalPlayerProfile.DEFAULT_PATH, "user://local_player_profile.json", "production profile is separate from game saves")
	t.assert_equal(LocalPlayerProfile.PROFILE_VERSION, 1, "profile schema remains version 1")
	t.assert_true(NetworkManager.has_valid_local_profile(), "NetworkManager loaded the local persistent profile")
	t.assert_true(NetworkManager.local_profile_load_status() != LocalPlayerProfile.LoadStatus.NONE, "NetworkManager exposes profile load status for future recovery gating")
	t.assert_equal(GameSession.get_local_player_id(), NetworkManager.local_profile_player_id(), "offline GameSession uses the persistent profile identity")

func _test_first_creation_and_reuse(t: Node, path: String) -> void:
	_cleanup(path)
	var created := LocalPlayerProfile.new(path)
	t.assert_equal(created.load_or_create(), OK, "missing primary and backup create a new profile")
	t.assert_equal(created.load_status, LocalPlayerProfile.LoadStatus.NEW_PROFILE_CREATED, "first creation has an explicit load status")
	t.assert_true(created.is_valid(), "created profile exposes a valid persistent identity")
	t.assert_true(LocalPlayerProfile.is_valid_player_id(created.get_player_id()), "generated identity uses the required format")
	t.assert_true(FileAccess.file_exists(path) and FileAccess.file_exists(path + ".bak"), "first creation persists primary and backup")
	t.assert_equal(_read_id(path), created.get_player_id(), "created primary contains the active identity")
	t.assert_equal(_read_id(path + ".bak"), created.get_player_id(), "created backup contains the same identity")
	t.assert_true(not created.primary_exists and not created.backup_exists, "first load preserves evidence that both copies were initially missing")
	var original_id := created.get_player_id()
	var reloaded := LocalPlayerProfile.new(path)
	t.assert_equal(reloaded.load_or_create(), OK, "existing redundant profile reloads")
	t.assert_equal(reloaded.load_status, LocalPlayerProfile.LoadStatus.VALID_PRIMARY, "valid primary remains canonical")
	t.assert_equal(reloaded.get_player_id(), original_id, "profile reload reuses the same persistent identity")
	t.assert_true(reloaded.primary_exists and reloaded.backup_exists, "reload records both original copies")
	_cleanup(path)

func _test_primary_backup_policy(t: Node, token: String) -> void:
	var missing_backup_path := _path(token, "missing_backup")
	_cleanup(missing_backup_path)
	_write_profile(missing_backup_path, PLAYER_A, "Primary")
	var missing_backup := LocalPlayerProfile.new(missing_backup_path)
	t.assert_equal(missing_backup.load_or_create(), OK, "valid primary loads when backup is missing")
	t.assert_equal(missing_backup.load_status, LocalPlayerProfile.LoadStatus.VALID_PRIMARY, "missing backup does not change primary status")
	t.assert_equal(missing_backup.get_player_id(), PLAYER_A, "valid primary identity is retained")
	t.assert_equal(_read_id(missing_backup_path + ".bak"), PLAYER_A, "missing backup is rebuilt from primary")
	t.assert_true(missing_backup.primary_exists and not missing_backup.backup_exists, "missing backup evidence is preserved after rebuild")
	_cleanup(missing_backup_path)

	var stale_path := _path(token, "stale")
	_cleanup(stale_path)
	_write_profile(stale_path, PLAYER_A, "Primary")
	_write_profile(stale_path + ".bak", PLAYER_B, "Stale")
	var stale := LocalPlayerProfile.new(stale_path)
	t.assert_equal(stale.load_or_create(), OK, "valid primary wins over stale backup")
	t.assert_equal(stale.get_player_id(), PLAYER_A, "stale backup never replaces primary identity")
	t.assert_equal(_read_id(stale_path + ".bak"), PLAYER_A, "stale backup is rebuilt with primary identity")
	_cleanup(stale_path)

	var corrupt_primary_path := _path(token, "corrupt_primary")
	_cleanup(corrupt_primary_path)
	_write(corrupt_primary_path, "{invalid json")
	_write_profile(corrupt_primary_path + ".bak", PLAYER_A, "Backup")
	var corrupt_primary := LocalPlayerProfile.new(corrupt_primary_path)
	t.assert_equal(corrupt_primary.load_or_create(), OK, "valid backup recovers a corrupt primary")
	t.assert_equal(corrupt_primary.load_status, LocalPlayerProfile.LoadStatus.RECOVERED_FROM_BACKUP, "backup recovery is externally visible")
	t.assert_equal(corrupt_primary.get_player_id(), PLAYER_A, "backup recovery preserves the existing identity")
	t.assert_equal(_read_id(corrupt_primary_path), PLAYER_A, "backup recovery repairs primary")
	t.assert_equal(_read_id(corrupt_primary_path + ".bak"), PLAYER_A, "backup remains consistent after recovery")
	_cleanup(corrupt_primary_path)

	var missing_primary_path := _path(token, "missing_primary")
	_cleanup(missing_primary_path)
	_write_profile(missing_primary_path + ".bak", PLAYER_B, "Backup")
	var missing_primary := LocalPlayerProfile.new(missing_primary_path)
	t.assert_equal(missing_primary.load_or_create(), OK, "valid backup recovers a missing primary")
	t.assert_equal(missing_primary.load_status, LocalPlayerProfile.LoadStatus.RECOVERED_FROM_BACKUP, "missing primary uses backup recovery status")
	t.assert_equal(missing_primary.get_player_id(), PLAYER_B, "missing primary recovery preserves backup identity")
	t.assert_equal(_read_id(missing_primary_path), PLAYER_B, "missing primary is recreated")
	t.assert_true(not missing_primary.primary_exists and missing_primary.backup_exists, "missing primary evidence is preserved")
	_cleanup(missing_primary_path)

func _test_corruption_evidence(t: Node, token: String) -> void:
	var corrupt_path := _path(token, "both_corrupt")
	_cleanup(corrupt_path)
	_write(corrupt_path, "{invalid primary")
	_write(corrupt_path + ".bak", "{invalid backup")
	var corrupt := LocalPlayerProfile.new(corrupt_path)
	t.assert_equal(corrupt.load_or_create(), ERR_INVALID_DATA, "two corrupt copies require identity recovery")
	t.assert_equal(corrupt.load_status, LocalPlayerProfile.LoadStatus.IDENTITY_RECOVERY_REQUIRED, "unrecoverable files expose recovery-required status")
	t.assert_true(not corrupt.is_valid() and corrupt.get_player_id().is_empty(), "corruption never activates a replacement identity")
	t.assert_true(corrupt.primary_exists and corrupt.backup_exists, "corruption evidence records that both files existed")
	t.assert_true(not corrupt.primary_error.is_empty() and not corrupt.backup_error.is_empty(), "each corrupt copy retains its own validation error")
	_cleanup(corrupt_path)

	var only_invalid_path := _path(token, "one_invalid")
	_cleanup(only_invalid_path)
	_write_profile(only_invalid_path, &"bad_id", "Invalid")
	var only_invalid := LocalPlayerProfile.new(only_invalid_path)
	t.assert_equal(only_invalid.load_or_create(), ERR_INVALID_DATA, "an invalid primary with no backup is not silently replaced")
	t.assert_equal(only_invalid.load_status, LocalPlayerProfile.LoadStatus.IDENTITY_RECOVERY_REQUIRED, "existing invalid data is distinct from a new install")
	t.assert_true(only_invalid.primary_exists and not only_invalid.backup_exists, "single-file corruption evidence is preserved")
	_cleanup(only_invalid_path)

func _test_validation_contract(t: Node, token: String) -> void:
	var valid_float_path := _path(token, "float_version")
	_cleanup(valid_float_path)
	_write(valid_float_path, JSON.stringify({"version": 1.0, "player_id": String(PLAYER_A), "display_name": "  A  "}))
	var valid_float := LocalPlayerProfile.new(valid_float_path)
	t.assert_equal(valid_float.load_or_create(), OK, "integer-equivalent JSON profile version is accepted")
	t.assert_equal(valid_float.get_display_name(), "A", "display name is sanitized after full validation")
	_cleanup(valid_float_path)

	var index := 0
	for invalid_version in [null, "1", 1.5, 2]:
		var version_path := _path(token, "version_%d" % index)
		index += 1
		_cleanup(version_path)
		var payload := {"player_id": String(PLAYER_A), "display_name": "Player"}
		if invalid_version != null:
			payload["version"] = invalid_version
		_write(version_path, JSON.stringify(payload))
		var invalid_version_profile := LocalPlayerProfile.new(version_path)
		t.assert_equal(invalid_version_profile.load_or_create(), ERR_INVALID_DATA, "missing, string, fractional, and unsupported versions require recovery")
		t.assert_true(invalid_version_profile.primary_error.contains("Unsupported"), "invalid version retains a clear validation error")
		_cleanup(version_path)

	for invalid_id in ["", "abc", "player_", "player_0123456789abcdef0123456789abcdeg", "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaextra"]:
		var invalid_path := _path(token, "invalid_id_%s" % String(invalid_id).length())
		_cleanup(invalid_path)
		_write(invalid_path, JSON.stringify({"version": LocalPlayerProfile.PROFILE_VERSION, "player_id": invalid_id, "display_name": "Player"}))
		var invalid := LocalPlayerProfile.new(invalid_path)
		t.assert_equal(invalid.load_or_create(), ERR_INVALID_DATA, "invalid identity is rejected: %s" % invalid_id)
		t.assert_true(not invalid.is_valid(), "invalid identity is never activated: %s" % invalid_id)
		_cleanup(invalid_path)

func _test_atomic_writer_failures(t: Node, token: String) -> void:
	for operation in [LocalPlayerProfile.OP_TEMP_OPEN, LocalPlayerProfile.OP_TEMP_WRITE, LocalPlayerProfile.OP_TEMP_VALIDATE, LocalPlayerProfile.OP_BACKUP_CREATE]:
		var path := _path(token, "failure_%s" % operation)
		_create_known_profile(path, PLAYER_A)
		var failing := LocalPlayerProfile.new(path, _failure_hook([operation]))
		t.assert_equal(failing.load_or_create(), OK, "failure fixture first loads its valid profile")
		var original_valid := failing.is_valid()
		var result := failing.commit_identity(PLAYER_B, "Replacement")
		t.assert_true(result != OK, "%s is reported" % operation)
		t.assert_equal(failing.get_player_id(), PLAYER_A, "%s leaves the in-memory identity unchanged" % operation)
		t.assert_equal(failing.is_valid(), original_valid, "%s leaves in-memory validity unchanged" % operation)
		t.assert_true(not failing.last_error.is_empty(), "%s provides failure detail" % operation)
		_cleanup(path)

	var primary_failure_path := _path(token, "primary_failure")
	_create_known_profile(primary_failure_path, PLAYER_A)
	var primary_failure := LocalPlayerProfile.new(primary_failure_path, _failure_hook([LocalPlayerProfile.OP_PRIMARY_REPLACE]))
	t.assert_equal(primary_failure.load_or_create(), OK, "primary failure fixture loads")
	t.assert_true(primary_failure.commit_identity(PLAYER_B) != OK, "final primary rename failure is reported")
	t.assert_equal(primary_failure.get_player_id(), PLAYER_A, "primary failure does not activate the new identity")
	t.assert_equal(_read_id(primary_failure_path), PLAYER_A, "successful rollback preserves the previous primary")
	t.assert_true(primary_failure.last_error.begins_with("PRIMARY_REPLACE_FAILED"), "primary failure is distinguishable")
	_cleanup(primary_failure_path)

	var rollback_failure_path := _path(token, "rollback_failure")
	_create_known_profile(rollback_failure_path, PLAYER_A)
	var rollback_failure := LocalPlayerProfile.new(rollback_failure_path, _failure_hook([
		LocalPlayerProfile.OP_PRIMARY_REPLACE,
		LocalPlayerProfile.OP_ROLLBACK,
	]))
	t.assert_equal(rollback_failure.load_or_create(), OK, "rollback failure fixture loads")
	t.assert_true(rollback_failure.commit_identity(PLAYER_B) != OK, "rollback failure is reported")
	t.assert_equal(rollback_failure.get_player_id(), PLAYER_A, "rollback failure still does not activate the new identity")
	t.assert_true(rollback_failure.last_error.contains("ROLLBACK_FAILED"), "rollback failure has an explicit diagnostic")
	_cleanup(rollback_failure_path)

	var degraded_path := _path(token, "degraded_backup")
	_cleanup(degraded_path)
	_write_profile(degraded_path, PLAYER_A, "Primary")
	var degraded := LocalPlayerProfile.new(degraded_path, _failure_hook([LocalPlayerProfile.OP_BACKUP_CREATE]))
	t.assert_equal(degraded.load_or_create(), OK, "backup rebuild failure is nonfatal with a valid primary")
	t.assert_equal(degraded.load_status, LocalPlayerProfile.LoadStatus.VALID_PRIMARY, "degraded redundancy retains valid-primary status")
	t.assert_equal(degraded.get_player_id(), PLAYER_A, "degraded redundancy uses primary identity")
	t.assert_true(degraded.last_error.begins_with("BACKUP_CREATE_FAILED"), "degraded redundancy preserves warning detail")
	_cleanup(degraded_path)

	var recovery_failure_path := _path(token, "recovery_failure")
	_cleanup(recovery_failure_path)
	_write(recovery_failure_path, "{invalid primary")
	_write_profile(recovery_failure_path + ".bak", PLAYER_A, "Backup")
	var recovery_failure := LocalPlayerProfile.new(recovery_failure_path, _failure_hook([LocalPlayerProfile.OP_PRIMARY_REPLACE]))
	t.assert_true(recovery_failure.load_or_create() != OK, "backup recovery requires a successful redundant disk commit")
	t.assert_equal(recovery_failure.load_status, LocalPlayerProfile.LoadStatus.FAILED, "recovery persistence failure is distinct from corrupt inputs")
	t.assert_true(not recovery_failure.is_valid() and recovery_failure.get_player_id().is_empty(), "failed recovery never activates memory state")
	_cleanup(recovery_failure_path)

	var missing_directory_path := "user://missing_profile_directory_%s/local_player_profile.json" % token
	var unavailable := LocalPlayerProfile.new(missing_directory_path)
	t.assert_true(unavailable.load_or_create() != OK, "profile temporary open failure is reported")
	t.assert_equal(unavailable.load_status, LocalPlayerProfile.LoadStatus.FAILED, "write failure has FAILED status")
	t.assert_true(not unavailable.is_valid() and unavailable.get_player_id().is_empty(), "write failure never exposes an ephemeral identity")
	t.assert_true(unavailable.last_error.begins_with("TEMP_OPEN_FAILED"), "profile write failure identifies the temporary open stage")

func _test_override_path_contract(t: Node, token: String) -> void:
	var override_path := _path(token, "override")
	_cleanup(override_path)
	var profile := LocalPlayerProfile.new(override_path)
	t.assert_equal(profile.profile_path(), override_path, "explicit profile path is retained")
	t.assert_equal(profile.backup_path(), override_path + ".bak", "override derives an adjacent backup")
	t.assert_equal(profile.temporary_path(), override_path + ".tmp", "override derives an adjacent temporary file")
	t.assert_equal(profile.load_or_create(), OK, "override path supports redundant creation")
	t.assert_true(FileAccess.file_exists(override_path) and FileAccess.file_exists(override_path + ".bak"), "override creates independent primary and backup files")
	_cleanup(override_path)

func _path(token: String, label: String) -> String:
	return "user://local_profile_test_%s_%s.json" % [token, label]

func _create_known_profile(path: String, player_id: StringName) -> void:
	_cleanup(path)
	_write_profile(path, player_id, "Original")
	_write_profile(path + ".bak", player_id, "Original")

func _write_profile(path: String, player_id: StringName, display_name: String, version: Variant = LocalPlayerProfile.PROFILE_VERSION) -> void:
	_write(path, JSON.stringify({
		"version": version,
		"player_id": String(player_id),
		"display_name": display_name,
	}))

func _read_id(path: String) -> StringName:
	var file := FileAccess.open(path, FileAccess.READ)
	var payload: Variant = JSON.parse_string(file.get_as_text()) if file != null else null
	return StringName(payload.get("player_id", "")) if payload is Dictionary else &""

func _failure_hook(operations: Array) -> Callable:
	return func(operation: StringName) -> bool:
		return operations.has(operation)

func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(contents)
		file.flush()
		file.close()

func _cleanup(path: String) -> void:
	for suffix in ["", ".bak", ".tmp", ".rollback", ".bak.rollback"]:
		var candidate: String = path + suffix
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))
