class_name NetworkPlayerInfo
extends RefCounted

var peer_id: int
var player_id: StringName
var display_name: String
var ready: bool
var connected: bool

func _init(p_peer_id: int = 0, p_player_id: StringName = &"", p_display_name: String = "", p_ready: bool = false, p_connected: bool = true) -> void:
	peer_id = p_peer_id
	player_id = p_player_id
	display_name = p_display_name
	ready = p_ready
	connected = p_connected
