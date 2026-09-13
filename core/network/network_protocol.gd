class_name NetworkProtocol
extends RefCounted

# v12 added world/revision-bound gameplay replication for player movement,
# enemies, loot, combat presentation, and shared field interactions.
# v13 adds authoritative stamina: PlayerRuntimeSnapshot carries stamina and
# max_stamina, and a throttled unreliable combat runtime channel mirrors
# regeneration. Old and new payload shapes are never mixed within one version;
# the handshake rejects mismatched peers.
const VERSION := 13

static func valid_command_sender(sender_id: int, actor_peer_id: int, known_peer: bool) -> bool:
	return sender_id > 0 and sender_id == actor_peer_id and known_peer

static func valid_snapshot(position: Vector2, velocity: Vector2, facing: float, movement_mode: int) -> bool:
	return position.is_finite() and velocity.is_finite() and is_finite(facing) \
		and movement_mode >= MovementComponent.Mode.GROUND \
		and movement_mode <= MovementComponent.Mode.CLIMB
