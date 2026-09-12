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
	NetworkManager.player_attack_presented_received.connect(_on_attack_presented_received)
	if actor.is_simulation_authority() and NetworkManager.is_server():
		NetworkManager.player_attack_command_received.connect(_on_attack_command_received)

func _exit_tree() -> void:
	if NetworkManager.player_attack_presented_received.is_connected(_on_attack_presented_received):
		NetworkManager.player_attack_presented_received.disconnect(_on_attack_presented_received)
	if NetworkManager.player_attack_command_received.is_connected(_on_attack_command_received):
		NetworkManager.player_attack_command_received.disconnect(_on_attack_command_received)

func _on_attack_requested() -> void:
	if actor == null or not actor.is_local_player():
		return
	_local_sequence += 1
	if actor.is_simulation_authority() and not NetworkManager.is_multiplayer_active():
		_server_execute_attack(actor.peer_id, _local_sequence)
	elif NetworkManager.is_session_connected() and NetworkManager.is_local_world_ready():
		NetworkManager.submit_player_attack(actor.peer_id, _local_sequence)

func _on_attack_command_received(peer_id: int, sequence: int) -> void:
	if actor != null and actor.is_simulation_authority() and actor.peer_id == peer_id:
		_server_execute_attack(peer_id, sequence)

func _server_execute_attack(peer_id: int, sequence: int) -> CombatResult:
	if actor == null or not actor.is_simulation_authority() or actor.peer_id != peer_id:
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
		NetworkManager.broadcast_player_attack(peer_id, sequence, actor.facing)
	return result

func _on_attack_presented_received(peer_id: int, sequence: int, replicated_facing: float) -> void:
	if actor == null or actor.is_simulation_authority() or peer_id != actor.peer_id \
		or sequence < 0 or not is_finite(replicated_facing):
		return
	actor.facing = replicated_facing
	attack_presented.emit(peer_id, sequence, replicated_facing)
