class_name PlayerDodgeCommand
extends RefCounted
## One client dodge intent. Like [PlayerAttackCommand] this carries no gameplay
## outcome: the host decides whether the dodge happens at all.
##
## Direction is validated separately from the sequence on purpose. A malformed
## direction is still a command that occupied a sequence number, so the host
## consumes the sequence first and only then rejects the payload — otherwise a
## deliberately broken command could be replayed later with the same number.

var sequence: int
var direction: float

func _init(p_sequence: int = -1, p_direction: float = 0.0) -> void:
	sequence = p_sequence
	direction = p_direction

func is_valid_after(previous_sequence: int) -> bool:
	return sequence >= 0 and sequence > previous_sequence

## Strictly one of the two facings. Anything else — zero, a fraction, a huge
## value, NAN or INF — is rejected rather than normalised, so a remote peer can
## never smuggle a speed multiplier through the direction field.
func has_valid_direction() -> bool:
	return is_finite(direction) and (is_equal_approx(direction, 1.0) or is_equal_approx(direction, -1.0))
