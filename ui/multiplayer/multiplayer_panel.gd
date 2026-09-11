class_name MultiplayerPanel
extends CanvasLayer

signal host_requested
signal host_saved_requested
signal join_requested(address: String)
signal disconnect_requested

var address_edit: LineEdit
var host_button: Button
var host_saved_button: Button
var join_button: Button
var disconnect_button: Button
var status_label: Label
var _session_actions_enabled: bool = true
var _host_restore_busy: bool = false

func _ready() -> void:
	layer = 40
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-310, 18)
	panel.custom_minimum_size = Vector2(292, 0)
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, 10)
	panel.add_child(margin)
	var content := VBoxContainer.new()
	margin.add_child(content)
	var title := Label.new()
	title.text = "Experimental Multiplayer (2-4 players)"
	content.add_child(title)
	address_edit = LineEdit.new()
	address_edit.placeholder_text = "Host IP"
	address_edit.text = "127.0.0.1"
	content.add_child(address_edit)
	var buttons := HBoxContainer.new()
	content.add_child(buttons)
	host_button = Button.new(); host_button.text = "Host"; buttons.add_child(host_button)
	host_saved_button = Button.new(); host_saved_button.text = "Host Save"; buttons.add_child(host_saved_button)
	join_button = Button.new(); join_button.text = "Join"; buttons.add_child(join_button)
	disconnect_button = Button.new(); disconnect_button.text = "Disconnect"; buttons.add_child(disconnect_button)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(status_label)
	host_button.pressed.connect(host_requested.emit)
	host_saved_button.pressed.connect(host_saved_requested.emit)
	join_button.pressed.connect(func() -> void: join_requested.emit(address_edit.text))
	disconnect_button.pressed.connect(disconnect_requested.emit)
	NetworkManager.hosting_started.connect(refresh)
	NetworkManager.connected_to_server.connect(refresh)
	NetworkManager.connection_failed.connect(refresh)
	NetworkManager.server_disconnected.connect(refresh)
	NetworkManager.session_synchronized.connect(refresh)
	refresh()

func refresh() -> void:
	var active := NetworkManager.is_multiplayer_active()
	host_button.disabled = active or not _session_actions_enabled or _host_restore_busy
	host_saved_button.disabled = active or not _session_actions_enabled or _host_restore_busy
	join_button.disabled = active or not _session_actions_enabled or _host_restore_busy
	address_edit.editable = not active and _session_actions_enabled and not _host_restore_busy
	disconnect_button.disabled = not active or _host_restore_busy
	if not NetworkManager.last_error.is_empty():
		status_label.text = NetworkManager.last_error
	else:
		status_label.text = NetworkManager.ConnectionState.keys()[NetworkManager.state]

func set_session_actions_enabled(enabled: bool) -> void:
	_session_actions_enabled = enabled
	refresh()

func set_host_restore_busy(busy: bool) -> void:
	_host_restore_busy = busy
	refresh()
