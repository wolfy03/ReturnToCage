class_name CombatResult
extends RefCounted

var success: bool
var attacker_peer_id: int
var hit_count: int
var message: String

static func make(p_success: bool, p_peer_id: int = 0, p_message: String = "") -> CombatResult:
	var result := CombatResult.new()
	result.success = p_success
	result.attacker_peer_id = p_peer_id
	result.message = p_message
	return result
