extends RefCounted

const PLAYER_A := &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const PLAYER_B := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLAYER_C := &"player_cccccccccccccccccccccccccccccccc"

func run(t: Node) -> void:
	var token := "%s_%s" % [Time.get_ticks_usec(), randi()]
	await _test_dialog_action_modes(t)
	await _test_resolved_and_failed_states(t, token)
	await _test_unavailable_save_states(t, token)
	await _test_single_candidate_cancel_and_recover(t, token)
	await _test_multiple_candidate_selection(t, token)
	await _test_create_new_confirmation(t, token)
	await _test_recovery_failure_and_retry(t, token)
	await _test_profile_commit_failure(t, token)
	await _test_activation_retry(t, token)
	await _test_create_new_activation_retry(t, token, false)
	await _test_create_new_activation_retry(t, token, true)
	_restore_environment(t)

func _test_dialog_action_modes(t: Node) -> void:
	var dialog := (load("res://ui/identity_recovery_dialog.tscn") as PackedScene).instantiate() as IdentityRecoveryDialog
	t.add_child(dialog)
	await t.get_tree().process_frame
	var recovered: Array[StringName] = []
	var retries := [0]
	dialog.recover_requested.connect(func(player_id: StringName) -> void: recovered.append(player_id))
	dialog.activation_retry_requested.connect(func() -> void: retries[0] += 1)
	dialog.present_inspection({
		"status": SaveManager.IdentityInspectionStatus.MULTIPLE_CANDIDATES,
		"candidates": [PLAYER_A, PLAYER_B],
	})
	dialog.recover_button.pressed.emit()
	t.assert_true(recovered.is_empty(), "normal recovery with no selection emits no candidate request")
	dialog.select_candidate(0)
	dialog.recover_button.pressed.emit()
	t.assert_equal(recovered, [PLAYER_A], "normal recovery emits the explicitly selected candidate")
	dialog.present_inspection({"status": SaveManager.IdentityInspectionStatus.SAVE_NOT_FOUND, "candidates": []})
	t.assert_true(dialog.selected_player_id().is_empty(), "new inspection clears previous candidate selection")
	dialog.set_activation_retry("activation pending")
	dialog.recover_button.pressed.emit()
	t.assert_equal(retries[0], 1, "activation retry emits independently of candidate selection")
	dialog.set_busy(true)
	t.assert_true(dialog.recover_button.disabled, "busy retry mode disables Retry Activation")
	dialog.set_busy(false)
	t.assert_true(not dialog.recover_button.disabled, "leaving busy state restores Retry Activation without a candidate")
	dialog.recover_button.pressed.emit()
	t.assert_equal(retries[0], 2, "activation retry signal remains repeatable")
	t.assert_true(dialog.create_button.disabled and dialog.cancel_button.disabled, "retry mode disables Create New and Cancel")
	dialog.queue_free()
	await t.get_tree().process_frame

func _test_resolved_and_failed_states(t: Node, token: String) -> void:
	var valid_path := _profile_path(token, "valid")
	_write_profile(valid_path, PLAYER_A)
	t.assert_equal(NetworkManager._load_local_profile_for_test(valid_path), OK, "valid primary profile loads for startup gate")
	t.assert_equal(NetworkManager.local_profile_load_status(), LocalPlayerProfile.LoadStatus.VALID_PRIMARY, "valid primary keeps resolved status")
	t.assert_true(GameSession.activate_offline_local_identity(), "valid primary identity activates before AppRoot")
	var app := await _spawn_app(t, _save_path(token, "valid"))
	_assert_ready(t, app, "valid primary")
	await _free_app(t, app)
	_cleanup_profile(valid_path)

	var fresh_path := _profile_path(token, "fresh")
	_cleanup_profile(fresh_path)
	t.assert_equal(NetworkManager._load_local_profile_for_test(fresh_path), OK, "missing profile copies create a fresh identity")
	t.assert_equal(NetworkManager.local_profile_load_status(), LocalPlayerProfile.LoadStatus.NEW_PROFILE_CREATED, "fresh identity has resolved creation status")
	t.assert_true(GameSession.activate_offline_local_identity(), "fresh identity activates before AppRoot")
	app = await _spawn_app(t, _save_path(token, "fresh"))
	_assert_ready(t, app, "fresh profile")
	await _free_app(t, app)
	_cleanup_profile(fresh_path)

	var backup_path := _profile_path(token, "backup")
	_cleanup_profile(backup_path)
	_write(backup_path, "{corrupt primary")
	_write_profile(backup_path + ".bak", PLAYER_B)
	t.assert_equal(NetworkManager._load_local_profile_for_test(backup_path), OK, "valid backup recovers startup identity")
	t.assert_equal(NetworkManager.local_profile_load_status(), LocalPlayerProfile.LoadStatus.RECOVERED_FROM_BACKUP, "backup recovery is a resolved startup status")
	t.assert_true(GameSession.activate_offline_local_identity(), "backup identity activates before AppRoot")
	app = await _spawn_app(t, _save_path(token, "backup"))
	_assert_ready(t, app, "backup-recovered profile")
	await _free_app(t, app)
	_cleanup_profile(backup_path)

	var failed_path := "user://identity_gate_missing_%s/local_player_profile.json" % token
	t.assert_true(NetworkManager._load_local_profile_for_test(failed_path) != OK, "filesystem failure fixture cannot persist a profile")
	t.assert_equal(NetworkManager.local_profile_load_status(), LocalPlayerProfile.LoadStatus.FAILED, "filesystem failure remains distinct from identity recovery")
	app = await _spawn_app(t, _save_path(token, "failed"))
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.FAILED, "FAILED profile enters startup failure state")
	t.assert_true(not app.identity_dialog.is_open(), "filesystem failure does not open candidate recovery dialog")
	_assert_actions_disabled(t, app, "failed profile")
	await _free_app(t, app)
	_restore_environment(t)

func _test_unavailable_save_states(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "unavailable")
	_install_recovery_profile(t, profile_path)
	var missing_save := _save_path(token, "missing")
	_cleanup_save(missing_save)
	var app := await _spawn_app(t, missing_save)
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "missing Save keeps recovery gate open")
	t.assert_equal(app.identity_dialog.candidate_count(), 0, "missing Save exposes no recovery candidates")
	t.assert_true(app.identity_dialog.recover_button.disabled and app.identity_dialog.create_button.visible, "missing Save offers only explicit new-player escape path")
	t.assert_true(app.identity_dialog.message_label.text.contains("No Save v4"), "missing Save has a distinct recovery explanation")
	await _free_app(t, app)

	_install_recovery_profile(t, profile_path)
	var invalid_save := _save_path(token, "invalid")
	_write(invalid_save, "{invalid Save")
	app = await _spawn_app(t, invalid_save)
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "invalid Save keeps recovery gate open")
	t.assert_equal(app.identity_dialog.candidate_count(), 0, "invalid Save is not presented as a candidate list")
	t.assert_true(app.identity_dialog.recover_button.disabled and app.identity_dialog.error_label.visible, "invalid Save reports backend error and cannot recover")
	await _free_app(t, app)
	_cleanup_profile(profile_path)
	_cleanup_save(invalid_save)
	_restore_environment(t)

func _test_single_candidate_cancel_and_recover(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "single")
	_install_recovery_profile(t, profile_path)
	var save_path := _save_path(token, "single")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var profile_before := _read_text(profile_path)
	var backup_before := _read_text(profile_path + ".bak")
	var save_before := _read_text(save_path)
	var session_before := GameSession.export_persistent_state()
	var old_local_state := GameSession.get_local_player()
	var app := await _spawn_app(t, save_path)
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "recovery-required startup opens the modal dialog")
	t.assert_true(app.identity_dialog.is_open(), "identity dialog is visible")
	t.assert_equal(app.identity_dialog.candidate_count(), 1, "single Save candidate is displayed")
	t.assert_equal(app.identity_dialog.selected_player_id(), PLAYER_A, "single candidate is preselected without auto-commit")
	t.assert_true(not app.identity_dialog.recover_button.disabled, "single candidate can be explicitly confirmed")
	_assert_actions_disabled(t, app, "unresolved single candidate")

	app._start_new_game()
	app._load_game()
	app._host_game()
	app._host_saved_game(save_path, 19500 + randi_range(0, 400), 3)
	app._join_game("127.0.0.1")
	t.assert_true(not SaveManager.load_game(save_path), "direct Load call is blocked before GameSession identity activation")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "guarded AppRoot commands do not mutate unresolved GameSession")
	t.assert_true(NetworkManager.host_game(19000 + randi_range(0, 500)) != OK, "direct Host call is blocked before GameSession identity activation")
	t.assert_true(NetworkManager.join_game("127.0.0.1", 19000 + randi_range(501, 999)) != OK, "direct Join call is blocked before GameSession identity activation")

	app.identity_dialog.cancel_button.pressed.emit()
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_REQUIRED, "Cancel returns to blocked recovery-required state")
	t.assert_true(not app.identity_dialog.is_open() and app.recover_identity_button.visible, "Cancel leaves an explicit dialog reopen action")
	t.assert_equal(_read_text(profile_path), profile_before, "Cancel preserves primary profile bytes")
	t.assert_equal(_read_text(profile_path + ".bak"), backup_before, "Cancel preserves backup profile bytes")
	t.assert_equal(_read_text(save_path), save_before, "Cancel preserves Save bytes")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "Cancel preserves GameSession")

	app.recover_identity_button.pressed.emit()
	t.assert_true(app.identity_dialog.is_open(), "Recover Identity button reopens the dialog")
	app.identity_dialog.recover_button.pressed.emit()
	_assert_ready(t, app, "single candidate recovery")
	t.assert_equal(NetworkManager.local_profile_player_id(), PLAYER_A, "selected profile identity is committed")
	t.assert_equal(GameSession.get_local_player_id(), PLAYER_A, "selected identity is explicitly activated in GameSession")
	t.assert_true(GameSession.get_local_player() != old_local_state, "activation removes the previous placeholder PlayerState")
	t.assert_equal(GameSession.persistent_player_ids(), [PLAYER_A], "activation leaves one canonical recovered player state")
	t.assert_equal(GameSession._player_vitals_callbacks.size(), 1, "activation leaves one vitals callback")
	t.assert_equal(GameSession._player_item_callbacks.size(), 1, "activation leaves one item callback")
	t.assert_equal(_read_text(save_path), save_before, "identity recovery does not auto-load or rewrite Save")

	var port := 20000 + randi_range(0, 1000)
	t.assert_equal(NetworkManager.host_game(port), OK, "Host becomes available after recovered identity activation")
	t.assert_equal(NetworkManager.player_id_for_peer(1), PLAYER_A, "Host uses the recovered persistent identity")
	NetworkManager.leave_game()
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _test_multiple_candidate_selection(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "multiple")
	_install_recovery_profile(t, profile_path)
	var save_path := _save_path(token, "multiple")
	_write_json(save_path, _valid_envelope([PLAYER_C, PLAYER_A, PLAYER_B]))
	var save_before := _read_text(save_path)
	var app := await _spawn_app(t, save_path)
	t.assert_equal(app.identity_dialog.candidate_count(), 3, "multiple Save players are valid recovery candidates")
	t.assert_true(app.identity_dialog.selected_player_id().is_empty(), "multiple candidates have no implicit selection")
	t.assert_true(app.identity_dialog.recover_button.disabled, "Recover remains disabled until an explicit multiple-candidate selection")
	t.assert_equal(app.identity_dialog.candidate_list.get_item_tooltip(0), String(PLAYER_A), "dialog preserves backend deterministic ordering")
	t.assert_equal(app.identity_dialog.candidate_list.get_item_tooltip(1), String(PLAYER_B), "full ID remains available as secondary tooltip metadata")
	t.assert_true(app.identity_dialog.select_candidate(1), "user can explicitly select candidate B")
	app.identity_dialog.recover_button.pressed.emit()
	_assert_ready(t, app, "multiple candidate recovery")
	t.assert_equal(NetworkManager.local_profile_player_id(), PLAYER_B, "explicit B selection never falls back to A")
	t.assert_equal(GameSession.get_local_player_id(), PLAYER_B, "GameSession activates explicitly selected B")
	t.assert_equal(_read_text(save_path), save_before, "multiple selection does not rewrite Save")
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _test_create_new_confirmation(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "create")
	_install_recovery_profile(t, profile_path)
	var save_path := _save_path(token, "create")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var save_before := _read_text(save_path)
	var app := await _spawn_app(t, save_path)
	app.identity_dialog.create_button.pressed.emit()
	t.assert_true(app.identity_dialog.create_confirmation.visible, "Create New Player opens a separate destructive-choice confirmation")
	t.assert_true(not NetworkManager.has_valid_local_profile(), "opening confirmation does not create an identity")
	app.identity_dialog.create_confirmation.confirmed.emit()
	var created_id := NetworkManager.local_profile_player_id()
	_assert_ready(t, app, "explicit new identity")
	t.assert_true(LocalPlayerProfile.is_valid_player_id(created_id) and created_id != PLAYER_A, "confirmed creation transaction persists a fresh identity instead of attaching Save candidate")
	t.assert_equal(GameSession.get_local_player_id(), created_id, "new identity is explicitly activated in GameSession")
	t.assert_equal(_read_text(save_path), save_before, "creating a new identity does not modify the existing Save")
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _test_recovery_failure_and_retry(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "retry")
	_install_recovery_profile(t, profile_path)
	var save_path := _save_path(token, "retry")
	var corrupt := _valid_envelope([PLAYER_A])
	corrupt["players"][String(PLAYER_A)]["player_state"]["player_inventory"] = "corrupt"
	_write_json(save_path, corrupt)
	var session_before := GameSession.export_persistent_state()
	var app := await _spawn_app(t, save_path)
	app.identity_dialog.recover_button.pressed.emit()
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "staging failure keeps recovery dialog open")
	t.assert_true(app.identity_dialog.error_label.visible and not NetworkManager.has_valid_local_profile(), "staging failure is shown without committing profile")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "staging failure leaves GameSession unchanged")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	app.identity_dialog.recover_button.pressed.emit()
	_assert_ready(t, app, "retry after Save repair")
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _test_profile_commit_failure(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "commit_failure")
	_cleanup_profile(profile_path)
	var primary_before := "{corrupt primary"
	var backup_before := "{corrupt backup"
	_write(profile_path, primary_before)
	_write(profile_path + ".bak", backup_before)
	t.assert_equal(NetworkManager._load_local_profile_for_test(profile_path, _failure_hook([LocalPlayerProfile.OP_AFTER_BACKUP_INSTALL])), ERR_INVALID_DATA, "commit failure profile enters recovery state")
	var save_path := _save_path(token, "commit_failure")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var save_before := _read_text(save_path)
	var session_before := GameSession.export_persistent_state()
	var app := await _spawn_app(t, save_path)
	app.identity_dialog.recover_button.pressed.emit()
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "profile transaction failure keeps dialog retryable")
	t.assert_true(app.identity_dialog.error_label.visible and not NetworkManager.has_valid_local_profile(), "profile commit failure remains unresolved")
	t.assert_equal(_read_text(profile_path), primary_before, "profile commit failure restores primary")
	t.assert_equal(_read_text(profile_path + ".bak"), backup_before, "profile commit failure restores backup")
	t.assert_equal(_read_text(save_path), save_before, "profile commit failure preserves Save")
	t.assert_equal(GameSession.export_persistent_state(), session_before, "profile commit failure preserves GameSession")
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _test_activation_retry(t: Node, token: String) -> void:
	var profile_path := _profile_path(token, "activation_retry")
	_install_recovery_profile(t, profile_path)
	var save_path := _save_path(token, "activation_retry")
	_write_json(save_path, _valid_envelope([PLAYER_A]))
	var old_local_id := GameSession.get_local_player_id()
	var app := await _spawn_app(t, save_path)
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	app.identity_dialog.recover_button.pressed.emit()
	t.assert_equal(NetworkManager.local_profile_player_id(), PLAYER_A, "profile commit can succeed before a separately failing activation")
	t.assert_equal(GameSession.get_local_player_id(), old_local_id, "failed activation does not mutate GameSession identity")
	t.assert_equal(app.identity_dialog.recover_button.text, "Retry Activation", "activation failure offers activation-only retry")
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "activation failure does not unlock actions")
	_assert_actions_disabled(t, app, "candidate activation retry")
	var primary_after_commit := _read_text(profile_path)
	var backup_after_commit := _read_text(profile_path + ".bak")
	_write(save_path, "{Save changed after profile commit")
	NetworkManager.state = NetworkManager.ConnectionState.OFFLINE
	app.identity_dialog.recover_button.pressed.emit()
	_assert_ready(t, app, "activation-only retry")
	t.assert_equal(GameSession.get_local_player_id(), PLAYER_A, "activation retry completes without another candidate selection")
	t.assert_equal(_read_text(profile_path), primary_after_commit, "candidate activation retry does not rewrite primary profile")
	t.assert_equal(_read_text(profile_path + ".bak"), backup_after_commit, "candidate activation retry does not rewrite backup profile")
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _test_create_new_activation_retry(t: Node, token: String, invalid_save: bool) -> void:
	var label := "create_retry_invalid" if invalid_save else "create_retry_missing"
	var profile_path := _profile_path(token, label)
	_install_recovery_profile(t, profile_path)
	var save_path := _save_path(token, label)
	_cleanup_save(save_path)
	if invalid_save:
		_write(save_path, "{invalid Save")
	var app := await _spawn_app(t, save_path)
	t.assert_true(app.identity_dialog.selected_player_id().is_empty(), "%s starts without a selected candidate" % label)
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	app.identity_dialog.create_button.pressed.emit()
	app.identity_dialog.create_confirmation.confirmed.emit()
	var created_id := NetworkManager.local_profile_player_id()
	t.assert_true(LocalPlayerProfile.is_valid_player_id(created_id), "%s commits one explicit new identity before activation" % label)
	t.assert_true(app.identity_dialog.selected_player_id().is_empty(), "%s retry remains candidate-independent" % label)
	t.assert_equal(app.identity_dialog.recover_button.text, "Retry Activation", "%s enters activation retry mode" % label)
	t.assert_true(not app.identity_dialog.recover_button.disabled, "%s enables Retry Activation with empty selection" % label)
	t.assert_true(app.identity_dialog.create_button.disabled and app.identity_dialog.cancel_button.disabled, "%s prevents Create New and Cancel after persistence" % label)
	_assert_actions_disabled(t, app, label)
	var primary_after_commit := _read_text(profile_path)
	var backup_after_commit := _read_text(profile_path + ".bak")

	app.identity_dialog.set_busy(true)
	t.assert_true(app.identity_dialog.recover_button.disabled, "%s busy retry is disabled" % label)
	app.identity_dialog.set_busy(false)
	t.assert_true(not app.identity_dialog.recover_button.disabled, "%s busy release restores retry without candidate" % label)
	app.identity_dialog.recover_button.pressed.emit()
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.RECOVERY_DIALOG_OPEN, "%s repeated failed retry remains available" % label)
	t.assert_equal(NetworkManager.local_profile_player_id(), created_id, "%s failed retry never generates another identity" % label)
	t.assert_equal(_read_text(profile_path), primary_after_commit, "%s failed retry does not rewrite primary" % label)
	t.assert_equal(_read_text(profile_path + ".bak"), backup_after_commit, "%s failed retry does not rewrite backup" % label)

	NetworkManager.state = NetworkManager.ConnectionState.OFFLINE
	app.identity_dialog.recover_button.pressed.emit()
	_assert_ready(t, app, "%s successful retry" % label)
	t.assert_equal(NetworkManager.local_profile_player_id(), created_id, "%s successful retry retains the one generated identity" % label)
	t.assert_equal(GameSession.get_local_player_id(), created_id, "%s successful retry activates generated identity" % label)
	t.assert_equal(GameSession.players.size(), 1, "%s leaves exactly one offline player" % label)
	t.assert_equal(GameSession._player_vitals_callbacks.size(), 1, "%s leaves one vitals callback" % label)
	t.assert_equal(GameSession._player_item_callbacks.size(), 1, "%s leaves one item callback" % label)
	t.assert_equal(_read_text(profile_path), primary_after_commit, "%s successful retry does not recommit primary" % label)
	t.assert_equal(_read_text(profile_path + ".bak"), backup_after_commit, "%s successful retry does not recommit backup" % label)
	await _free_app(t, app)
	_cleanup_save(save_path)
	_cleanup_profile(profile_path)
	_restore_environment(t)

func _spawn_app(t: Node, save_path: String) -> AppRoot:
	var app := (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	app._identity_recovery_save_path = save_path
	t.add_child(app)
	await t.get_tree().process_frame
	return app

func _free_app(t: Node, app: AppRoot) -> void:
	app.queue_free()
	await t.get_tree().process_frame

func _assert_ready(t: Node, app: AppRoot, context: String) -> void:
	t.assert_equal(app.identity_gate_state, AppRoot.IdentityGateState.READY, "%s reaches READY" % context)
	t.assert_true(not app.new_game_button.disabled and not app.load_game_button.disabled, "%s enables New and Load" % context)
	t.assert_true(not app.multiplayer_panel.host_button.disabled and not app.multiplayer_panel.host_saved_button.disabled \
			and not app.multiplayer_panel.join_button.disabled, "%s enables Host, Host Save, and Join" % context)
	t.assert_true(not app.identity_dialog.is_open(), "%s closes recovery dialog" % context)

func _assert_actions_disabled(t: Node, app: AppRoot, context: String) -> void:
	t.assert_true(app.new_game_button.disabled and app.load_game_button.disabled, "%s disables New and Load" % context)
	t.assert_true(app.multiplayer_panel.host_button.disabled and app.multiplayer_panel.host_saved_button.disabled \
			and app.multiplayer_panel.join_button.disabled, "%s disables Host, Host Save, and Join" % context)

func _install_recovery_profile(t: Node, path: String) -> void:
	_cleanup_profile(path)
	_write(path, "{invalid primary")
	_write(path + ".bak", "{invalid backup")
	t.assert_equal(NetworkManager._load_local_profile_for_test(path), ERR_INVALID_DATA, "corrupt profile requires explicit identity recovery")

func _restore_environment(t: Node) -> void:
	if NetworkManager.is_multiplayer_active():
		NetworkManager.leave_game()
	t.assert_equal(NetworkManager._restore_local_profile_after_test(), OK, "test restores normal startup profile")
	t.assert_true(GameSession.activate_offline_local_identity(), "test restores normal offline GameSession identity")

func _valid_envelope(player_ids: Array) -> Dictionary:
	var players := {}
	for player_id in player_ids:
		players[String(player_id)] = {
			"player_state": {},
			"personal_progression": {"quests": []},
		}
	return {
		"format_version": 4,
		"saved_at": "identity-gate-test",
		"shared": {
			"session": {},
			"settlement": {},
			"progression": {},
			"difficulty": {},
			"adventure": {},
		},
		"players": players,
	}

func _profile_path(token: String, label: String) -> String:
	return "user://identity_gate_profile_%s_%s.json" % [token, label]

func _save_path(token: String, label: String) -> String:
	return "user://identity_gate_save_%s_%s.json" % [token, label]

func _write_profile(path: String, player_id: StringName) -> void:
	_cleanup_profile(path)
	_write_json(path, {
		"version": LocalPlayerProfile.PROFILE_VERSION,
		"player_id": String(player_id),
		"display_name": "Player",
	})

func _failure_hook(operations: Array) -> Callable:
	return func(operation: StringName) -> bool:
		return operations.has(operation)

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

func _cleanup_profile(path: String) -> void:
	for suffix in ["", ".bak", ".tmp", ".rollback", ".bak.rollback", ".transaction_rollback", ".bak.transaction_rollback"]:
		_remove(path + suffix)

func _cleanup_save(path: String) -> void:
	for suffix in ["", ".bak", ".tmp"]:
		_remove(path + suffix)

func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
