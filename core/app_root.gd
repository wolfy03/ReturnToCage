extends Node

@onready var world_layer: Node = %WorldLayer
@onready var menu: Control = %MainMenu
@onready var error_label: Label = %ErrorLabel
@onready var multiplayer_panel: MultiplayerPanel = %MultiplayerPanel

func _ready() -> void:
	SceneRouter.register_world_layer(world_layer)
	%NewGameButton.pressed.connect(_start_new_game)
	%LoadGameButton.pressed.connect(_load_game)
	multiplayer_panel.host_requested.connect(_host_game)
	multiplayer_panel.join_requested.connect(_join_game)
	multiplayer_panel.disconnect_requested.connect(_leave_game)
	NetworkManager.session_synchronized.connect(_enter_network_session)
	NetworkManager.connection_failed.connect(_on_network_failure)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	var errors := ContentRegistry.validate_all()
	if not errors.is_empty():
		error_label.text = "Content validation failed:\n%s" % "\n".join(errors)
		error_label.visible = true

func _start_new_game() -> void:
	if not GameSession.start_new_game():
		error_label.text = "Cannot start game: invalid start configuration"
		error_label.visible = true
		return
	menu.visible = false
	SceneRouter.go_to_settlement()

func _load_game() -> void:
	if SaveManager.load_game():
		menu.visible = false
		SceneRouter.go_to_settlement()
	else:
		error_label.text = "No valid save found"
		error_label.visible = true

func _host_game() -> void:
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
	GameSession.end_network_session()
	_return_to_menu()

func _on_network_failure() -> void:
	var message := NetworkManager.last_error
	GameSession.end_network_session()
	_return_to_menu()
	_show_error(message)

func _on_server_disconnected() -> void:
	GameSession.end_network_session()
	_return_to_menu()
	_show_error("Host disconnected")

func _return_to_menu() -> void:
	for child in world_layer.get_children():
		child.queue_free()
	menu.visible = true
	multiplayer_panel.refresh()

func _show_error(message: String) -> void:
	error_label.text = message
	error_label.visible = true
