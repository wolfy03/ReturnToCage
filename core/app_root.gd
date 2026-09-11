class_name AppRoot
extends Node

enum IdentityGateState {
	CHECKING,
	READY,
	RECOVERY_REQUIRED,
	RECOVERY_DIALOG_OPEN,
	FAILED,
}

@onready var world_layer: Node = %WorldLayer
@onready var menu: Control = %MainMenu
@onready var error_label: Label = %ErrorLabel
@onready var multiplayer_panel: MultiplayerPanel = %MultiplayerPanel
@onready var new_game_button: Button = %NewGameButton
@onready var load_game_button: Button = %LoadGameButton
@onready var recover_identity_button: Button = %RecoverIdentityButton
@onready var identity_dialog: IdentityRecoveryDialog = %IdentityRecoveryDialog
var _menu_transition_pending: bool = false
var identity_gate_state: IdentityGateState = IdentityGateState.CHECKING
var _activation_pending: bool = false
# Test harnesses may point the gate at an isolated Save; production retains the
# canonical primary path and never inspects the game-save backup.
var _identity_recovery_save_path: String = SaveManager.SAVE_PATH

func _ready() -> void:
	SceneRouter.register_world_layer(world_layer)
	%NewGameButton.pressed.connect(_start_new_game)
	%LoadGameButton.pressed.connect(_load_game)
	recover_identity_button.pressed.connect(_open_recovery_dialog)
	multiplayer_panel.host_requested.connect(_host_game)
	multiplayer_panel.join_requested.connect(_join_game)
	multiplayer_panel.disconnect_requested.connect(_leave_game)
	NetworkManager.session_synchronized.connect(_enter_network_session)
	NetworkManager.connection_failed.connect(_on_network_failure)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	NetworkManager.multiplayer_session_ended.connect(_on_multiplayer_session_ended)
	identity_dialog.recover_requested.connect(_recover_identity)
	identity_dialog.create_new_requested.connect(_create_new_identity)
	identity_dialog.canceled.connect(_cancel_identity_recovery)
	var errors := ContentRegistry.validate_all()
	if not errors.is_empty():
		error_label.text = "Content validation failed:\n%s" % "\n".join(errors)
		error_label.visible = true
	refresh_identity_gate()

func refresh_identity_gate(open_dialog: bool = true) -> void:
	identity_gate_state = IdentityGateState.CHECKING
	_activation_pending = false
	var status := NetworkManager.local_profile_load_status()
	match status:
		LocalPlayerProfile.LoadStatus.VALID_PRIMARY, \
		LocalPlayerProfile.LoadStatus.NEW_PROFILE_CREATED, \
		LocalPlayerProfile.LoadStatus.RECOVERED_FROM_BACKUP:
			if NetworkManager.is_local_identity_activated():
				_set_identity_ready()
			else:
				_set_identity_failed("Local profile is valid but its GameSession identity is not active")
		LocalPlayerProfile.LoadStatus.IDENTITY_RECOVERY_REQUIRED:
			identity_gate_state = IdentityGateState.RECOVERY_REQUIRED
			_set_session_actions_enabled(false)
			recover_identity_button.visible = true
			if open_dialog:
				_open_recovery_dialog()
		LocalPlayerProfile.LoadStatus.FAILED:
			_set_identity_failed("Local profile persistence failed: %s" % NetworkManager.last_error)
		_:
			_set_identity_failed("Local profile initialization did not complete")

func _open_recovery_dialog() -> void:
	if identity_gate_state not in [IdentityGateState.RECOVERY_REQUIRED, IdentityGateState.RECOVERY_DIALOG_OPEN]:
		return
	identity_gate_state = IdentityGateState.RECOVERY_DIALOG_OPEN
	identity_dialog.present_inspection(SaveManager.inspect_identity_candidates(_identity_recovery_save_path))

func _recover_identity(player_id: StringName) -> void:
	if identity_gate_state != IdentityGateState.RECOVERY_DIALOG_OPEN:
		return
	if _activation_pending:
		_complete_identity_activation()
		return
	identity_dialog.set_busy(true)
	var result := SaveManager.recover_identity_from_save(player_id, _identity_recovery_save_path)
	identity_dialog.set_busy(false)
	if not result.success:
		identity_dialog.show_error(result.message)
		return
	_activation_pending = true
	_complete_identity_activation()

func _create_new_identity() -> void:
	if identity_gate_state != IdentityGateState.RECOVERY_DIALOG_OPEN:
		return
	identity_dialog.set_busy(true)
	var result := NetworkManager.create_new_local_identity()
	identity_dialog.set_busy(false)
	if not result.success:
		identity_dialog.show_error(result.message)
		return
	_activation_pending = true
	_complete_identity_activation()

func _complete_identity_activation() -> void:
	if not GameSession.activate_offline_local_identity() \
			or not NetworkManager.is_local_identity_activated() \
			or GameSession.players.size() != 1:
		identity_dialog.set_activation_retry("Profile identity was saved, but local session activation failed: %s" % GameSession.last_message)
		return
	_activation_pending = false
	identity_dialog.close_dialog()
	_set_identity_ready()

func _cancel_identity_recovery() -> void:
	if identity_gate_state != IdentityGateState.RECOVERY_DIALOG_OPEN or _activation_pending:
		return
	identity_dialog.close_dialog()
	identity_gate_state = IdentityGateState.RECOVERY_REQUIRED
	_set_session_actions_enabled(false)
	recover_identity_button.visible = true

func _set_identity_ready() -> void:
	identity_gate_state = IdentityGateState.READY
	_set_session_actions_enabled(true)
	recover_identity_button.visible = false
	if error_label.text.begins_with("Identity recovery") or error_label.text.begins_with("Local profile") \
			or error_label.text.begins_with("Resolve the local player identity"):
		error_label.visible = false

func _set_identity_failed(message: String) -> void:
	identity_gate_state = IdentityGateState.FAILED
	_set_session_actions_enabled(false)
	recover_identity_button.visible = false
	_show_error(message)

func _set_session_actions_enabled(enabled: bool) -> void:
	new_game_button.disabled = not enabled
	load_game_button.disabled = not enabled
	multiplayer_panel.set_session_actions_enabled(enabled)

func _identity_actions_allowed() -> bool:
	if identity_gate_state == IdentityGateState.READY and NetworkManager.is_local_identity_activated():
		return true
	_show_error("Resolve the local player identity before starting or loading a session")
	return false

func _start_new_game() -> void:
	if not _identity_actions_allowed():
		return
	if not GameSession.start_new_game():
		error_label.text = "Cannot start game: invalid start configuration"
		error_label.visible = true
		return
	menu.visible = false
	SceneRouter.go_to_settlement()

func _load_game() -> void:
	if not _identity_actions_allowed():
		return
	if SaveManager.load_game():
		menu.visible = false
		SceneRouter.go_to_settlement()
	else:
		error_label.text = "No valid save found"
		error_label.visible = true

func _host_game() -> void:
	if not _identity_actions_allowed():
		return
	var result := NetworkManager.host_game()
	if result != OK:
		_show_error(NetworkManager.last_error)
		return
	if not GameSession.start_new_game():
		NetworkManager.leave_game()
		_show_error("Cannot create multiplayer session")
		return
	menu.visible = false
	error_label.visible = false
	SceneRouter.go_to_settlement()

func _join_game(address: String) -> void:
	if not _identity_actions_allowed():
		return
	var result := NetworkManager.join_game(address)
	if result != OK:
		_show_error(NetworkManager.last_error)
	else:
		error_label.visible = false

func _enter_network_session() -> void:
	menu.visible = false
	error_label.visible = false
	SceneRouter.go_to_settlement()

func _leave_game() -> void:
	NetworkManager.leave_game()
	_return_to_menu()

func _on_network_failure() -> void:
	var message := NetworkManager.last_error
	_return_to_menu()
	_show_error(message)

func _on_server_disconnected() -> void:
	_return_to_menu()
	_show_error("Host disconnected")

func _on_multiplayer_session_ended(reason: String) -> void:
	_return_to_menu()
	if reason == NetworkManager.END_REASON_SERVER_DISCONNECTED:
		_show_error("Host disconnected")
	elif reason == NetworkManager.END_REASON_CONNECTION_FAILED:
		_show_error(NetworkManager.last_error)
	else:
		error_label.visible = false

func _return_to_menu() -> void:
	if _menu_transition_pending:
		return
	_menu_transition_pending = true
	for child in world_layer.get_children():
		child.process_mode = Node.PROCESS_MODE_DISABLED
		world_layer.remove_child(child)
		child.queue_free()
	menu.visible = true
	multiplayer_panel.refresh()
	call_deferred("_finish_menu_transition")

func _finish_menu_transition() -> void:
	_menu_transition_pending = false

func _show_error(message: String) -> void:
	error_label.text = message
	error_label.visible = true
