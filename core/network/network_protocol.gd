class_name NetworkProtocol
extends RefCounted

# v12 added world/revision-bound gameplay replication for player movement,
# enemies, loot, combat presentation, and shared field interactions.
# v13 adds authoritative stamina: PlayerRuntimeSnapshot carries stamina and
# max_stamina, and a throttled unreliable combat runtime channel mirrors
# regeneration. Old and new payload shapes are never mixed within one version;
# the handshake rejects mismatched peers.
# v14 adds the dodge intent channel: a reliable PlayerDodgeCommand (sequence +
# strict facing) and the authoritative dodge presentation broadcast that mirrors
# it. i-frames, stamina and position stay host-side and are never sent as a
# client decision.
# v15 expands presentation-only attack/dodge events with semantic animation
# metadata and adds a HURT presentation event. Gameplay action state and timers
# remain server-only; Save data is unchanged.
const VERSION := 15

static func valid_command_sender(sender_id: int, actor_peer_id: int, known_peer: bool) -> bool:
	return sender_id > 0 and sender_id == actor_peer_id and known_peer

static func valid_snapshot(position: Vector2, velocity: Vector2, facing: float, movement_mode: int) -> bool:
	return position.is_finite() and velocity.is_finite() and is_finite(facing) \
		and movement_mode >= MovementComponent.Mode.GROUND \
		and movement_mode <= MovementComponent.Mode.CLIMB
