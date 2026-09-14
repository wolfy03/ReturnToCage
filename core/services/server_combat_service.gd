class_name ServerCombatService
extends RefCounted

## Hands a validated intent to the actor's authoritative input buffer, which
## decides whether it runs now, waits for an authored window, or is refused.
## Network authentication and life-state checks deliberately stay in the network
## components; gameplay scheduling deliberately stays in the buffer.
static func submit_player_attack(actor: PlayerActor, sequence: int) -> CombatInputBufferComponent.SubmitResult:
	if actor == null or not is_instance_valid(actor) or actor.input_buffer == null:
		return CombatInputBufferComponent.SubmitResult.REJECTED
	return actor.input_buffer.submit_attack(sequence, actor.facing)

static func submit_player_dodge(
	actor: PlayerActor, sequence: int, direction: float
) -> CombatInputBufferComponent.SubmitResult:
	if actor == null or not is_instance_valid(actor) or actor.input_buffer == null:
		return CombatInputBufferComponent.SubmitResult.REJECTED
	return actor.input_buffer.submit_dodge(sequence, direction)
