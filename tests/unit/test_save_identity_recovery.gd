extends RefCounted

const PLAYER_A := &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const PLAYER_B := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLAYER_C := &"player_cccccccccccccccccccccccccccccccc"

func run(t: Node) -> void:
	var token := "%s_%s" % [Time.get_ticks_usec(), randi()]
	_test_inspection_statuses(t, token)
	_test_candidate_contract(t, token)
	_test_read_only_and_explicit_staging(t, token)
	_test_full_staging_rejection(t, token)
	_test_recovery_commit(t, token)
	_test_recovery_commit_failure(t, token)
	_test_stale_inspection(t, token)

func _test_inspection_statuses(t: Node, token: String) -> void:
	var path := _path(token, "statuses")
	_cleanup_save(path)
	var missing := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(missing.status, SaveManager.IdentityInspectionStatus.SAVE_NOT_FOUND, "missing primary save has a distinct inspection status")
	t.assert_true(missing.candidates.is_empty(), "missing save exposes no candidates")
	_write_json(path + ".bak", _valid_envelope([PLAYER_A]))
	t.assert_equal(SaveManager.inspect_identity_candidates(path).status, SaveManager.IdentityInspectionStatus.SAVE_NOT_FOUND, "game-save backup is not an identity recovery source")
	_remove(path + ".bak")

	_write(path, "{invalid json")
	var invalid_json := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(invalid_json.status, SaveManager.IdentityInspectionStatus.INVALID_SAVE, "invalid JSON is not an identity source")

	for invalid_version in [null, "4", 1, 2, 3, 4.5, 5]:
		var envelope := _valid_envelope([PLAYER_A])
		if invalid_version == null:
			envelope.erase("format_version")
		else:
			envelope["format_version"] = invalid_version
		_write_json(path, envelope)
		var invalid := SaveManager.inspect_identity_candidates(path)
		t.assert_equal(invalid.status, SaveManager.IdentityInspectionStatus.INVALID_SAVE, "missing, legacy, future, string, and fractional versions are rejected")

	var numeric := _valid_envelope([PLAYER_A])
	numeric["format_version"] = 4.0
	_write_json(path, numeric)
	var accepted := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(accepted.status, SaveManager.IdentityInspectionStatus.SINGLE_CANDIDATE, "integer-equivalent JSON v4 is accepted")
	t.assert_equal(accepted.format_version, 4, "accepted inspection reports Save v4")
	_cleanup_save(path)

func _test_candidate_contract(t: Node, token: String) -> void:
	var path := _path(token, "contract")
	for missing_shared_key in ["session", "settlement", "progression", "difficulty", "adventure"]:
		var malformed_shared := _valid_envelope([PLAYER_A])
		malformed_shared["shared"].erase(missing_shared_key)
		_write_json(path, malformed_shared)
		t.assert_equal(SaveManager.inspect_identity_candidates(path).status, SaveManager.IdentityInspectionStatus.INVALID_SAVE, "missing shared object rejects identity inspection: %s" % missing_shared_key)

	for malformed in [
		{"format_version": 4, "shared": [], "players": {}},
		{"format_version": 4, "shared": _shared(), "players": []},
		{"format_version": 4, "shared": _shared(), "players": {}},
	]:
		_write_json(path, malformed)
		t.assert_equal(SaveManager.inspect_identity_candidates(path).status, SaveManager.IdentityInspectionStatus.INVALID_SAVE, "malformed or empty player root is rejected")

	var malformed_key := _valid_envelope([PLAYER_A])
	malformed_key["players"]["bad_key"] = _player_record()
	_write_json(path, malformed_key)
	t.assert_equal(SaveManager.inspect_identity_candidates(path).status, SaveManager.IdentityInspectionStatus.INVALID_SAVE, "valid candidate plus malformed sibling rejects the whole save")

	for malformed_record in [null, [], {"player_state": {}}, {"personal_progression": {}}]:
		var bad_record := _valid_envelope([PLAYER_A])
		bad_record["players"][String(PLAYER_A)] = malformed_record
		_write_json(path, bad_record)
		t.assert_equal(SaveManager.inspect_identity_candidates(path).status, SaveManager.IdentityInspectionStatus.INVALID_SAVE, "malformed player record rejects the whole save")

	var single := _valid_envelope([PLAYER_A])
	single["saved_at"] = "2030-01-02T03:04:05Z"
	_write_json(path, single)
	var one := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(one.status, SaveManager.IdentityInspectionStatus.SINGLE_CANDIDATE, "one valid player produces SINGLE_CANDIDATE")
	t.assert_equal(one.candidates, [PLAYER_A], "single candidate identity comes from the players key")
	t.assert_equal(one.saved_at, "2030-01-02T03:04:05Z", "saved_at is returned only as display metadata")

	var multiple := _valid_envelope([PLAYER_C, PLAYER_A, PLAYER_B])
	_write_json(path, multiple)
	var many := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(many.status, SaveManager.IdentityInspectionStatus.MULTIPLE_CANDIDATES, "multiple valid players produce MULTIPLE_CANDIDATES")
	t.assert_equal(many.candidates, [PLAYER_A, PLAYER_B, PLAYER_C], "candidate ordering is deterministic and independent of dictionary insertion")
	_cleanup_save(path)

func _test_read_only_and_explicit_staging(t: Node, token: String) -> void:
	var path := _path(token, "readonly")
	var envelope := _valid_envelope([PLAYER_A, PLAYER_B])
	_write_json(path, envelope)
	var save_before := _read_text(path)
	var session_before := GameSession.export_persistent_state()
	var profile_id_before := NetworkManager.local_profile_player_id()
	var profile_status_before := NetworkManager.local_profile_load_status()
	var first := SaveManager.inspect_identity_candidates(path)
	var second := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(first.candidates, second.candidates, "repeated inspection is deterministic")
	t.assert_equal(_read_text(path), save_before, "inspection does not rewrite Save bytes")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "inspection does not mutate live GameSession")
	t.assert_equal(NetworkManager.local_profile_player_id(), profile_id_before, "inspection does not mutate local profile identity")
	t.assert_equal(NetworkManager.local_profile_load_status(), profile_status_before, "inspection does not mutate profile status")

	var staged := SaveManager.validate_identity_candidate(PLAYER_B, path)
	t.assert_true(staged.success, "candidate different from current profile stages with an explicit selected ID")
	var snapshot: SessionSnapshot = staged.snapshot
	t.assert_true(snapshot != null and snapshot.local_player_id == PLAYER_B, "explicit staging selects the requested local player")
	t.assert_true(snapshot.player == snapshot.players_by_id.get(PLAYER_B), "staged local player points at the selected canonical record")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "candidate staging does not apply the snapshot")
	t.assert_true(not SaveManager.validate_identity_candidate(&"invalid", path).success, "malformed selected ID is rejected before staging")
	t.assert_true(not SaveManager.validate_identity_candidate(PLAYER_C, path).success, "missing selected ID is rejected without fallback")
	_cleanup_save(path)

func _test_full_staging_rejection(t: Node, token: String) -> void:
	var corrupt_path := _path(token, "corrupt_state")
	var corrupt := _valid_envelope([PLAYER_A])
	corrupt["players"][String(PLAYER_A)]["player_state"]["player_inventory"] = "corrupt"
	_write_json(corrupt_path, corrupt)
	t.assert_equal(SaveManager.inspect_identity_candidates(corrupt_path).status, SaveManager.IdentityInspectionStatus.SINGLE_CANDIDATE, "shallow inspection can expose a structurally valid record key")
	t.assert_true(not SaveManager.validate_identity_candidate(PLAYER_A, corrupt_path).success, "corrupt player domain state fails full recovery staging")

	var duplicate_path := _path(token, "duplicate")
	var duplicate := _valid_envelope([PLAYER_A, PLAYER_B])
	var stack := {
		"item_id": "leaf_vest",
		"quantity": 1,
		"instance_id": "recovery_global_duplicate",
		"durability": 45,
	}
	duplicate["players"][String(PLAYER_A)]["player_state"]["player_inventory"] = [stack]
	duplicate["players"][String(PLAYER_B)]["player_state"]["protected_inventory"] = [stack]
	_write_json(duplicate_path, duplicate)
	t.assert_equal(SaveManager.inspect_identity_candidates(duplicate_path).status, SaveManager.IdentityInspectionStatus.MULTIPLE_CANDIDATES, "key inspection does not instantiate item domains")
	t.assert_true(not SaveManager.validate_identity_candidate(PLAYER_A, duplicate_path).success, "global duplicate instance fails full recovery staging")
	_cleanup_save(corrupt_path)
	_cleanup_save(duplicate_path)

func _test_recovery_commit(t: Node, token: String) -> void:
	var save_path := _path(token, "recover_single")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var profile_path := _profile_path(token, "recover_single")
	var profile := _recovery_profile(profile_path)
	var save_before := _read_text(save_path)
	var session_before := GameSession.export_persistent_state()
	var result := SaveManager.recover_identity_from_save(PLAYER_A, save_path, profile)
	t.assert_true(result.success, "explicit valid Save candidate commits profile identity")
	t.assert_equal(profile.get_player_id(), PLAYER_A, "successful recovery activates selected identity")
	t.assert_equal(_read_profile_id(profile_path), PLAYER_A, "successful recovery writes selected primary identity")
	t.assert_equal(_read_profile_id(profile_path + ".bak"), PLAYER_A, "successful recovery writes selected backup identity")
	t.assert_equal(_read_text(save_path), save_before, "successful recovery does not modify Save bytes")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "successful identity recovery does not apply staged GameSession")

	var multiple_path := _path(token, "recover_multiple")
	_write_json(multiple_path, _valid_envelope([PLAYER_C, PLAYER_A, PLAYER_B]))
	var multiple_profile_path := _profile_path(token, "recover_multiple")
	var multiple_profile := _recovery_profile(multiple_profile_path)
	t.assert_true(SaveManager.recover_identity_from_save(PLAYER_B, multiple_path, multiple_profile).success, "multiple candidates require and accept explicit selection")
	t.assert_equal(multiple_profile.get_player_id(), PLAYER_B, "explicit B selection never falls back to sorted candidate A")
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_cleanup_save(multiple_path)
	_cleanup_profile(multiple_profile_path)

func _test_recovery_commit_failure(t: Node, token: String) -> void:
	var save_path := _path(token, "commit_failure")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var save_before := _read_text(save_path)
	var profile_path := _profile_path(token, "commit_failure")
	var primary_before := "{corrupt primary recovery"
	var backup_before := "{corrupt backup recovery"
	_write(profile_path, primary_before)
	_write(profile_path + ".bak", backup_before)
	var profile := LocalPlayerProfile.new(profile_path, _failure_hook([LocalPlayerProfile.OP_AFTER_BACKUP_INSTALL]))
	t.assert_equal(profile.load_or_create(), ERR_INVALID_DATA, "commit failure fixture requires identity recovery")
	var session_before := GameSession.export_persistent_state()
	var result := SaveManager.recover_identity_from_save(PLAYER_A, save_path, profile)
	t.assert_true(not result.success, "profile transaction failure rejects recovery")
	t.assert_true(not profile.is_valid() and profile.get_player_id().is_empty(), "profile transaction failure does not activate memory identity")
	t.assert_equal(_read_text(profile_path), primary_before, "profile transaction failure restores primary bytes")
	t.assert_equal(_read_text(profile_path + ".bak"), backup_before, "profile transaction failure restores backup bytes")
	t.assert_equal(_read_text(save_path), save_before, "profile commit failure leaves Save bytes unchanged")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "profile commit failure leaves live GameSession unchanged")
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)

func _test_stale_inspection(t: Node, token: String) -> void:
	var save_path := _path(token, "stale")
	_write_json(save_path, _valid_envelope([PLAYER_B]))
	var inspected := SaveManager.inspect_identity_candidates(save_path)
	t.assert_equal(inspected.candidates, [PLAYER_B], "initial inspection exposes B")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var bytes_after_change := _read_text(save_path)
	var profile_path := _profile_path(token, "stale")
	var profile := _recovery_profile(profile_path)
	var result := SaveManager.recover_identity_from_save(PLAYER_B, save_path, profile)
	t.assert_true(not result.success, "recovery re-reads Save instead of trusting stale inspected candidates")
	t.assert_true(not profile.is_valid(), "stale candidate is not committed")
	t.assert_equal(_read_text(save_path), bytes_after_change, "stale candidate rejection does not rewrite Save")
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)

func _valid_envelope(player_ids: Array) -> Dictionary:
	var players := {}
	for player_id in player_ids:
		players[String(player_id)] = _player_record()
	return {
		"format_version": 4,
		"saved_at": "test-save",
		"shared": _shared(),
		"players": players,
	}

func _shared() -> Dictionary:
	return {
		"session": {},
		"settlement": {},
		"progression": {},
		"difficulty": {},
		"adventure": {},
	}

func _player_record() -> Dictionary:
	return {
		"player_state": {},
		"personal_progression": {"quests": []},
	}

func _recovery_profile(path: String) -> LocalPlayerProfile:
	_cleanup_profile(path)
	_write(path, "{invalid primary")
	_write(path + ".bak", "{invalid backup")
	var profile := LocalPlayerProfile.new(path)
	profile.load_or_create()
	return profile

func _failure_hook(operations: Array) -> Callable:
	return func(operation: StringName) -> bool:
		return operations.has(operation)

func _path(token: String, label: String) -> String:
	return "user://identity_inspection_%s_%s.json" % [token, label]

func _profile_path(token: String, label: String) -> String:
	return "user://identity_profile_%s_%s.json" % [token, label]

func _write_json(path: String, data: Dictionary) -> void:
	_write(path, JSON.stringify(data))

func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(contents)
		file.flush()
		file.close()

func _read_text(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var result := file.get_as_text()
	file.close()
	return result

func _read_profile_id(path: String) -> StringName:
	var parsed: Variant = JSON.parse_string(_read_text(path))
	return StringName(parsed.get("player_id", "")) if parsed is Dictionary else &""

func _cleanup_save(path: String) -> void:
	for suffix in ["", ".tmp", ".bak"]:
		_remove(path + suffix)

func _cleanup_profile(path: String) -> void:
	for suffix in ["", ".bak", ".tmp", ".rollback", ".bak.rollback", ".transaction_rollback", ".bak.transaction_rollback"]:
		_remove(path + suffix)

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
