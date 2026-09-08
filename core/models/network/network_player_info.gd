class_name NetworkPlayerInfo
extends RefCounted

var peer_id: int
var display_name: String
var ready: bool

func _init(p_peer_id: int = 0, p_display_name: String = "", p_ready: bool = false) -> void:
	peer_id = p_peer_id
	display_name = p_display_name
	ready = p_ready
