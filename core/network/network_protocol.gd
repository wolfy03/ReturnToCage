class_name NetworkProtocol
extends RefCounted

# v11 adds owner-only player-world assignments and revision-bound world-ready
# acknowledgement. v10 clients cannot safely interpret independent routing.
const VERSION := 11

static func valid_command_sender(sender_id: int, actor_peer_id: int, known_peer: bool) -> bool:
	return sender_id > 0 and sender_id == actor_peer_id and known_peer

static func valid_snapshot(position: Vector2, velocity: Vector2, facing: float, movement_mode: int) -> bool:
	return position.is_finite() and velocity.is_finite() and is_finite(facing) \
		and movement_mode >= MovementComponent.Mode.GROUND \
		and movement_mode <= MovementComponent.Mode.CLIMB
