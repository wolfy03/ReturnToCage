class_name PlayerRuntimeState
extends RefCounted

enum LifePhase { ALIVE, DEAD, RESPAWNING }

var peer_id: int
var life_id: int = 0
var life_phase: LifePhase = LifePhase.ALIVE
var death_result: RespawnResult

func _init(p_peer_id: int = 0) -> void:
	peer_id = p_peer_id
