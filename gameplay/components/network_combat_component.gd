class_name NetworkCombatComponent
extends Node

signal attack_presented(peer_id: int, sequence: int, facing: float)

var actor: PlayerActor
var input: PlayerInputComponent
var _local_sequence: int = -1
var _last_server_sequence: int = -1

func configure(p_actor: PlayerActor, p_input: PlayerInputComponent) -> void:
	actor = p_actor
	input = p_input
	input.network_intents_enabled = actor.is_local_player() and NetworkManager.is_multiplayer_active()
	input.attack_requested.connect(_on_attack_requested)

func _on_attack_requested() -> void:
	if actor == null or not actor.is_local_player():
		return
	_local_sequence += 1
	if NetworkManager.is_authoritative_simulation():
		_server_execute_attack(actor.peer_id, _local_sequence)
	elif NetworkManager.is_session_connected():
		_request_attack.rpc_id(1, _local_sequence)

@rpc("any_peer", "call_remote", "reliable")
func _request_attack(sequence: int) -> void:
	if not NetworkManager.is_server() or actor == null:
		return
	var sender := multiplayer.get_remote_sender_id()
	if not NetworkProtocol.valid_command_sender(sender, actor.peer_id, GameSession.has_player(sender) and NetworkManager.has_peer(sender)):
		return
	_server_execute_attack(sender, sequence)

func _server_execute_attack(peer_id: int, sequence: int) -> CombatResult:
	if not NetworkManager.is_authoritative_simulation() or actor == null or actor.peer_id != peer_id:
		return CombatResult.make(false, peer_id, "Invalid attack authority")
	var command := PlayerAttackCommand.new(sequence)
	if not command.is_valid_after(_last_server_sequence):
		return CombatResult.make(false, peer_id, "Duplicate or stale attack")
	# Consume a valid sequence before gameplay validation so rejected spam cannot be
	# replayed later after cooldown or respawn.
	_last_server_sequence = sequence
	var runtime := GameSession.get_player_runtime(peer_id)
	if runtime == null or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE \
		or actor.is_death_handled() or GameSession.phase not in [GameSession.Phase.SETTLEMENT, GameSession.Phase.ADVENTURE]:
		print("[NET-COMBAT] Attack rejected peer %d: invalid life or session state" % peer_id)
		return CombatResult.make(false, peer_id, "Player cannot attack in the current state")
	var result := ServerCombatService.try_player_attack(actor)
	if not result.success:
		print("[NET-COMBAT] Attack rejected peer %d: %s" % [peer_id, result.message])
		return result
	print("[NET-COMBAT] Attack accepted peer %d sequence %d" % [peer_id, sequence])
	actor.cancel_return_channel_for_combat()
	attack_presented.emit(peer_id, sequence, actor.facing)
	if NetworkManager.is_multiplayer_active() and NetworkManager.is_server():
		for remote_peer_id in NetworkManager.ready_remote_peer_ids():
			if NetworkManager.can_send_to_peer(remote_peer_id):
				_present_attack.rpc_id(remote_peer_id, peer_id, sequence, actor.facing)
	return result

@rpc("authority", "call_remote", "reliable")
func _present_attack(peer_id: int, sequence: int, replicated_facing: float) -> void:
	if NetworkManager.is_server() or actor == null or peer_id != actor.peer_id \
		or sequence < 0 or not is_finite(replicated_facing):
		return
	actor.facing = replicated_facing
	attack_presented.emit(peer_id, sequence, replicated_facing)
