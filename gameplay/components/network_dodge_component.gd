class_name NetworkDodgeComponent
extends Node
## Network boundary for the player dodge, mirroring [NetworkCombatComponent].
##
## A remote client sends an intent and nothing else. It never decides its own
## i-frames, never spends its own stamina, never enters DODGE by itself and
## never moves itself: the host runs the dodge and replicates the result.

signal dodge_presented(peer_id: int, sequence: int, direction: float)

var actor: PlayerActor
var input: PlayerInputComponent
var _local_sequence: int = -1
var _last_server_sequence: int = -1

func configure(p_actor: PlayerActor, p_input: PlayerInputComponent) -> void:
	actor = p_actor
	input = p_input
	input.dodge_requested.connect(_on_dodge_requested)
	NetworkManager.player_dodge_presented_received.connect(_on_dodge_presented_received)
	if actor.is_simulation_authority() and NetworkManager.is_server():
		NetworkManager.player_dodge_command_received.connect(_on_dodge_command_received)

func _exit_tree() -> void:
	if NetworkManager.player_dodge_presented_received.is_connected(_on_dodge_presented_received):
		NetworkManager.player_dodge_presented_received.disconnect(_on_dodge_presented_received)
	if NetworkManager.player_dodge_command_received.is_connected(_on_dodge_command_received):
		NetworkManager.player_dodge_command_received.disconnect(_on_dodge_command_received)

## Resolves the direction the client asks for, in priority order: the horizontal
## intent sampled at the button press, then the actor's current facing. Only a
## canonical -1 or +1 ever crosses the wire — a raw axis value would hand the
## host a number it must not trust.
##
## This is still only a *request*; the host re-validates it and decides whether
## the dodge happens at all.
func _on_dodge_requested(horizontal_direction: float) -> void:
	if actor == null or not actor.is_local_player():
		return
	var requested := horizontal_direction if is_finite(horizontal_direction) else 0.0
	if requested != 1.0 and requested != -1.0:
		requested = signf(actor.facing) if is_finite(actor.facing) else 0.0
	if requested == 0.0:
		requested = 1.0
	_local_sequence += 1
	if actor.is_simulation_authority() and not NetworkManager.is_multiplayer_active():
		_server_execute_dodge(actor.peer_id, _local_sequence, requested)
	elif NetworkManager.is_session_connected() and NetworkManager.is_local_world_ready():
		NetworkManager.submit_player_dodge(actor.peer_id, _local_sequence, requested)

func _on_dodge_command_received(peer_id: int, sequence: int, direction: float) -> void:
	if actor != null and actor.is_simulation_authority() and actor.peer_id == peer_id:
		_server_execute_dodge(peer_id, sequence, direction)

func _server_execute_dodge(peer_id: int, sequence: int, direction: float) -> CombatResult:
	if actor == null or not actor.is_simulation_authority() or actor.peer_id != peer_id:
		return CombatResult.make(false, peer_id, "Invalid dodge authority")
	var command := PlayerDodgeCommand.new(sequence, direction)
	if not command.is_valid_after(_last_server_sequence):
		return CombatResult.make(false, peer_id, "Duplicate or stale dodge")
	# Consume a valid sequence before any further validation so a rejected or
	# malformed command cannot be replayed once the actor is dodgeable again.
	_last_server_sequence = sequence
	if not command.has_valid_direction():
		print("[NET-DODGE] Dodge rejected peer %d: malformed direction" % peer_id)
		return CombatResult.make(false, peer_id, "Dodge direction is invalid")
	var runtime := GameSession.get_player_runtime(peer_id)
	if runtime == null or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE \
		or actor.is_death_handled() or GameSession.phase not in [GameSession.Phase.SETTLEMENT, GameSession.Phase.ADVENTURE]:
		print("[NET-DODGE] Dodge rejected peer %d: invalid life or session state" % peer_id)
		return CombatResult.make(false, peer_id, "Player cannot dodge in the current state")
	if actor.dodge == null or not actor.dodge.try_begin(command.direction):
		print("[NET-DODGE] Dodge rejected peer %d: rejected by dodge rules" % peer_id)
		return CombatResult.make(false, peer_id, "Dodge rejected by combat rules")
	# The return channel is cancelled by the dodge itself, on commit, so every
	# caller of try_begin() gets the same semantics without a second owner here.
	print("[NET-DODGE] Dodge accepted peer %d sequence %d" % [peer_id, sequence])
	dodge_presented.emit(peer_id, sequence, actor.dodge.direction)
	if NetworkManager.is_multiplayer_active() and NetworkManager.is_server():
		NetworkManager.broadcast_player_dodge(peer_id, sequence, actor.dodge.direction)
	return CombatResult.make(true, peer_id)

## Presentation only: the client mirrors the facing the host committed and plays
## the roll. It starts no timeline, opens no i-frames and touches no stamina.
func _on_dodge_presented_received(peer_id: int, sequence: int, replicated_direction: float) -> void:
	if actor == null or actor.is_simulation_authority() or peer_id != actor.peer_id \
		or sequence < 0 or not PlayerDodgeCommand.new(sequence, replicated_direction).has_valid_direction():
		return
	actor.facing = replicated_direction
	dodge_presented.emit(peer_id, sequence, replicated_direction)
