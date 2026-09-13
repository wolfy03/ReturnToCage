class_name PlayerRuntimeState
extends RefCounted

enum LifePhase { ALIVE, DEAD, RESPAWNING }

var peer_id: int
var life_id: int = 0
var life_phase: LifePhase = LifePhase.ALIVE
var death_result: RespawnResult
## Per-life combat values (stamina). Created with the runtime state; refilled by
## GameSession on registration and on respawn.
var combat: CombatRuntimeState = CombatRuntimeState.new()

func _init(p_peer_id: int = 0) -> void:
	peer_id = p_peer_id
