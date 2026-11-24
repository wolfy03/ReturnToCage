extends RefCounted

# STEP 2: Save primary/backup candidate policy and the save transaction.
# Every file lives under a unique user:// test path; the production save and
# the production profile are never touched.

const OTHER_PLAYER := &"player_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
const SUFFIXES: Array[String] = ["", ".bak", ".tmp", ".bak.rollback", ".corrupt"]
var _failure_operations: Array[StringName] = [
	SaveManager.OP_TEMP_OPEN,
	SaveManager.OP_TEMP_WRITE,
	SaveManager.OP_TEMP_VALIDATE,
	SaveManager.OP_BACKUP_PRESERVE,
	SaveManager.OP_BACKUP_CREATE,
	SaveManager.OP_PRIMARY_INSTALL,
]

var _token := ""

func run(t: Node) -> void:
	_token = "%s_%s" % [Time.get_ticks_usec(), randi()]
	t.assert_true(not SaveManager.resolve_save_candidate(SaveManager.SAVE_PATH).is_empty(), "candidate resolution is callable for the production path without side effects")
	_test_backup_rotation(t)
	_test_candidate_matrix(t)
	_test_legacy_primary_migrates(t)
	_test_identity_is_never_switched(t)
	_test_identity_pinning(t)
	_test_failed_load_keeps_session(t)
	_test_transaction_failures(t)
	_test_rollback_failure_keeps_a_valid_copy(t)
	_test_corrupt_primary_transaction(t)
	_test_missing_primary_transaction(t)
	SaveManager.set_failure_hook_for_tests(Callable())
	GameSession.start_new_game()

# Saves the live session with a distinguishing storage marker and returns the
# bytes written.
func _save_marker(t: Node, path: String, scrap: int) -> String:
	GameSession.start_new_game()
	GameSession.settlement.storage.add_item(&"rusty_scrap", scrap)
	t.assert_true(SaveManager.save_game(path), "fixture save with marker %d succeeds" % scrap)
	return _read(path)

func _loaded_marker() -> int:
	return GameSession.settlement.storage.count(&"rusty_scrap")

func _test_backup_rotation(t: Node) -> void:
	var path := _path("rotation")
	var first := _save_marker(t, path, 1)
	t.assert_true(not FileAccess.file_exists(path + ".bak"), "first save has no previous generation to back up")
	var second := _save_marker(t, path, 2)
	t.assert_equal(_read(path + ".bak"), first, "normal save rotates the previous valid primary to .bak")
	t.assert_equal(_read(path), second, "normal save installs the new primary")
	for suffix in [".tmp", ".bak.rollback", ".corrupt"]:
		t.assert_true(not FileAccess.file_exists(path + suffix), "successful save leaves no %s file" % suffix)
	_cleanup(path)

# Writes primary marker 2 / backup marker 1, then replaces either side.
func _prepare_pair(t: Node, path: String) -> void:
	_cleanup(path)
	_save_marker(t, path, 1)
	_save_marker(t, path, 2)

func _test_candidate_matrix(t: Node) -> void:
	var path := _path("matrix")
	var structure_broken := JSON.stringify({"format_version": 5, "shared": [], "players": {}})
	var cases := [
		# [label, primary override, backup override, expected marker, expect backup]
		["valid primary + valid backup", null, null, 2, false],
		["valid primary + corrupt backup", null, "{broken", 2, false],
		["missing primary + valid backup", "", null, 1, true],
		["JSON-corrupt primary + valid backup", "{broken", null, 1, true],
		["structure-corrupt primary + valid backup", structure_broken, null, 1, true],
		["valid primary + missing backup", null, "", 2, false],
	]
	for case in cases:
		_prepare_pair(t, path)
		_override(path, case[1])
		_override(path + ".bak", case[2])
		var primary_before := _read(path)
		var backup_before := _read(path + ".bak")
		GameSession.start_new_game()
		t.assert_true(SaveManager.load_game(path), "%s loads" % case[0])
		t.assert_equal(_loaded_marker(), case[3], "%s loads the expected generation" % case[0])
		t.assert_equal(bool(SaveManager.last_load_result.recovered_from_backup), case[4], "%s reports its source" % case[0])
		t.assert_equal(int(SaveManager.last_load_result.source),
			SaveManager.SaveSource.BACKUP if case[4] else SaveManager.SaveSource.PRIMARY, "%s source enum" % case[0])
		if case[4]:
			t.assert_true(String(SaveManager.last_load_result.message).begins_with(SaveManager.BACKUP_RECOVERY_NOTICE), "%s explains the backup recovery" % case[0])
			t.assert_equal(GameSession.last_message, SaveManager.last_load_result.message, "%s exposes the recovery notice to the HUD" % case[0])
		t.assert_equal(_read(path), primary_before, "%s does not rewrite the primary" % case[0])
		t.assert_equal(_read(path + ".bak"), backup_before, "%s does not rewrite the backup" % case[0])
		t.assert_true(not FileAccess.file_exists(path + ".tmp"), "%s creates no temporary file" % case[0])

	# A domain-invalid primary (valid JSON and envelope, failing full staging)
	# is treated as corrupt, not as a usable save.
	_prepare_pair(t, path)
	var domain_broken: Dictionary = JSON.parse_string(_read(path))
	var local_record: Dictionary = domain_broken.players[String(NetworkManager.local_profile_player_id())]
	local_record.player_state.player_inventory = "corrupt"
	_write(path, JSON.stringify(domain_broken))
	t.assert_true(SaveManager.load_game(path) and _loaded_marker() == 1 and SaveManager.last_load_result.recovered_from_backup,
		"primary failing full staging falls back to the valid backup")

	for both in [["{broken", "{broken"], ["", ""]]:
		_prepare_pair(t, path)
		_override(path, both[0])
		_override(path + ".bak", both[1])
		var prepared := SaveManager.prepare_load(path)
		t.assert_true(not prepared.success and prepared.snapshot == null, "primary %s / backup %s cannot load" % [
			"missing" if both[0].is_empty() else "corrupt", "missing" if both[1].is_empty() else "corrupt"])
		var candidate := SaveManager.resolve_save_candidate(path)
		t.assert_equal(bool(candidate.missing), both[0].is_empty(), "missing-vs-corrupt is reported exactly")
		if both[0].is_empty():
			t.assert_equal(prepared.error, "Save file does not exist", "no save at all keeps the existing not-found message")
	_cleanup(path)

func _test_legacy_primary_migrates(t: Node) -> void:
	var path := _path("legacy")
	_prepare_pair(t, path)
	_write(path, _read("res://tests/fixtures/legacy_v2_progress.json"))
	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path), "legacy v2 primary loads through migration")
	t.assert_true(not SaveManager.last_load_result.recovered_from_backup, "a migratable legacy primary is preferred over a valid backup")
	t.assert_true(_loaded_marker() != 1, "legacy primary content is used, not the backup marker")
	_cleanup(path)

func _test_identity_is_never_switched(t: Node) -> void:
	var path := _path("identity")
	_prepare_pair(t, path)
	# Primary is valid but belongs to someone else; the backup contains the
	# local player. The valid primary still wins and nothing switches identity.
	var foreign: Dictionary = JSON.parse_string(_read(path))
	var record: Variant = foreign.players[String(NetworkManager.local_profile_player_id())]
	foreign.players = {String(OTHER_PLAYER): record}
	_write(path, JSON.stringify(foreign))
	var profile_before := NetworkManager.local_profile_player_id()
	var prepared := SaveManager.prepare_load(path)
	t.assert_true(not prepared.success and prepared.source == SaveManager.SaveSource.PRIMARY, "valid foreign primary is selected and rejected, not replaced by the backup")
	t.assert_true(not prepared.recovered_from_backup, "identity mismatch never triggers backup recovery")
	var inspection := SaveManager.inspect_identity_candidates(path)
	t.assert_equal(inspection.candidates, [OTHER_PLAYER], "identity inspection lists the primary's identities only")
	t.assert_equal(NetworkManager.local_profile_player_id(), profile_before, "candidate selection never changes the local profile")
	_cleanup(path)

func _test_identity_pinning(t: Node) -> void:
	var path := _path("pinning")
	_prepare_pair(t, path)
	_override(path, "")
	var inspection := SaveManager.inspect_identity_candidates(path)
	var local_id := NetworkManager.local_profile_player_id()
	t.assert_true(inspection.source == SaveManager.SaveSource.BACKUP and inspection.candidates.has(local_id), "inspection resolves to the backup when primary is missing")
	t.assert_true(SaveManager.validate_identity_candidate(local_id, path, inspection).success, "validation stages the same inspected backup")
	_save_marker(t, path, 3)
	var stale := SaveManager.validate_identity_candidate(local_id, path, inspection)
	t.assert_true(not stale.success and stale.source == SaveManager.SaveSource.PRIMARY, "a primary appearing after inspection is not silently substituted")
	_cleanup(path)

func _test_failed_load_keeps_session(t: Node) -> void:
	var path := _path("unchanged")
	_prepare_pair(t, path)
	_override(path, "{broken")
	_override(path + ".bak", "{broken")
	GameSession.start_new_game()
	GameSession.settlement.storage.add_item(&"berry", 3)
	var live_before := GameSession.export_persistent_state()
	var phase_before := GameSession.phase
	t.assert_true(not SaveManager.load_game(path), "both-corrupt load fails")
	t.assert_equal(GameSession.export_persistent_state(), live_before, "failed load leaves the live GameSession unchanged")
	t.assert_equal(GameSession.phase, phase_before, "failed load leaves the session phase unchanged")
	t.assert_true(not SaveManager.last_load_result.success and not String(SaveManager.last_load_result.message).is_empty(), "failed load reports why")
	_cleanup(path)

func _test_transaction_failures(t: Node) -> void:
	var path := _path("transaction")
	for operation in _failure_operations:
		_prepare_pair(t, path)
		var primary_before := _read(path)
		var backup_before := _read(path + ".bak")
		GameSession.start_new_game()
		GameSession.settlement.storage.add_item(&"rusty_scrap", 9)
		SaveManager.set_failure_hook_for_tests(func(op: StringName) -> bool: return op == operation)
		t.assert_true(not SaveManager.save_game(path), "%s failure fails the save" % operation)
		SaveManager.set_failure_hook_for_tests(Callable())
		t.assert_equal(_read(path), primary_before, "%s failure keeps the previous primary bytes" % operation)
		t.assert_equal(_read(path + ".bak"), backup_before, "%s failure keeps the previous backup bytes" % operation)
		for suffix in [".tmp", ".bak.rollback"]:
			t.assert_true(not FileAccess.file_exists(path + suffix), "%s failure leaves no %s file" % [operation, suffix])
		GameSession.start_new_game()
		t.assert_true(SaveManager.load_game(path) and _loaded_marker() == 2 and not SaveManager.last_load_result.recovered_from_backup,
			"%s failure keeps the previous save loadable from primary" % operation)
	_cleanup(path)

func _test_rollback_failure_keeps_a_valid_copy(t: Node) -> void:
	var path := _path("rollback")
	_prepare_pair(t, path)
	var primary_before := _read(path)
	SaveManager.set_failure_hook_for_tests(func(op: StringName) -> bool:
		return op in [SaveManager.OP_PRIMARY_INSTALL, SaveManager.OP_ROLLBACK])
	GameSession.start_new_game()
	t.assert_true(not SaveManager.save_game(path), "install plus rollback failure fails the save")
	SaveManager.set_failure_hook_for_tests(Callable())
	t.assert_true(not FileAccess.file_exists(path), "the failed rollback leaves the primary slot empty (crash-like state)")
	t.assert_equal(_read(path + ".bak"), primary_before, "the previous valid primary is still on disk as .bak")
	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path) and _loaded_marker() == 2 and SaveManager.last_load_result.recovered_from_backup,
		"load recovers the previous save from the backup after a failed rollback")
	# The next successful save repairs the layout without promoting the stale
	# rollback copy and without overwriting the recovered backup first.
	_save_marker(t, path, 4)
	t.assert_equal(_read(path + ".bak"), primary_before, "save over a missing primary keeps the recovered backup")
	t.assert_true(not FileAccess.file_exists(path + ".tmp"), "repair save leaves no temporary file")
	_cleanup(path)

func _test_corrupt_primary_transaction(t: Node) -> void:
	var path := _path("corrupt_primary")
	_prepare_pair(t, path)
	var backup_before := _read(path + ".bak")
	_write(path, "{broken")
	SaveManager.set_failure_hook_for_tests(func(op: StringName) -> bool: return op == SaveManager.OP_CORRUPT_PRESERVE)
	t.assert_true(not _save_marker_raw(path, 5), "failing to set the corrupt primary aside fails the save")
	SaveManager.set_failure_hook_for_tests(Callable())
	t.assert_true(_read(path) == "{broken" and _read(path + ".bak") == backup_before, "that failure changes neither file")
	SaveManager.set_failure_hook_for_tests(func(op: StringName) -> bool: return op == SaveManager.OP_PRIMARY_INSTALL)
	t.assert_true(not _save_marker_raw(path, 5), "install failure over a corrupt primary fails the save")
	SaveManager.set_failure_hook_for_tests(Callable())
	t.assert_true(_read(path) == "{broken" and _read(path + ".bak") == backup_before and not FileAccess.file_exists(path + ".corrupt"),
		"install failure restores the corrupt primary and keeps the backup")
	_save_marker(t, path, 5)
	t.assert_equal(_read(path + ".bak"), backup_before, "a corrupt primary is never rotated over the valid backup")
	t.assert_equal(_read(path + ".corrupt"), "{broken", "the corrupt primary bytes are preserved, not deleted")
	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path) and _loaded_marker() == 5, "the new primary loads")
	_cleanup(path)

func _test_missing_primary_transaction(t: Node) -> void:
	var path := _path("missing_primary")
	_prepare_pair(t, path)
	var backup_before := _read(path + ".bak")
	_override(path, "")
	SaveManager.set_failure_hook_for_tests(func(op: StringName) -> bool: return op == SaveManager.OP_PRIMARY_INSTALL)
	t.assert_true(not _save_marker_raw(path, 6), "install failure without a primary fails the save")
	SaveManager.set_failure_hook_for_tests(Callable())
	t.assert_true(not FileAccess.file_exists(path) and _read(path + ".bak") == backup_before, "the backup survives a failed first install")
	_cleanup(path)

func _save_marker_raw(path: String, scrap: int) -> bool:
	GameSession.start_new_game()
	GameSession.settlement.storage.add_item(&"rusty_scrap", scrap)
	return SaveManager.save_game(path)

# null keeps the file, "" deletes it, any other text replaces it.
func _override(path: String, contents: Variant) -> void:
	if contents == null:
		return
	if String(contents).is_empty():
		_remove(path)
	else:
		_write(path, String(contents))

func _path(label: String) -> String:
	return "user://save_backup_recovery_%s_%s.json" % [label, _token]

func _read(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var text := file.get_as_text()
	file.close()
	return text

func _write(path: String, contents: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(contents)
		file.flush()
		file.close()

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func _cleanup(path: String) -> void:
	for suffix in SUFFIXES:
		_remove(path + suffix)
