class_name DodgeDefinition
extends Resource
## The authored gameplay parameters of one dodge roll: its timing, its i-frame
## window, its speed and its cost.
##
## Deliberately a plain [Resource] and not a [ContentDefinition]: a dodge is not
## standalone content with an id registered in ContentRegistry, it is authored
## once and referenced by the actor that owns the move.
##
## Unlike [AttackDefinition], which is purely timing, this also owns the roll
## speed and the stamina cost — every number a dodge needs lives here so no
## component invents its own. The i-frame window is expressed as a half-open
## interval inside the dodge, so the definition alone says when the actor is
## untouchable.
## Nothing here knows about the network; the values are read, never written, at
## runtime.

## How long the whole dodge lasts. Controls stay locked for exactly this long.
@export_range(0.01, 10.0, 0.01) var duration_seconds: float = 0.30
## Start of the invulnerability window, measured from the start of the dodge.
## Zero means the dodge is evasive from its very first frame.
@export_range(0.0, 10.0, 0.01) var iframe_start_seconds: float = 0.0
## End of the invulnerability window (exclusive). Must be inside the dodge, so
## the recovery tail at the end is always punishable.
@export_range(0.01, 10.0, 0.01) var iframe_end_seconds: float = 0.18
## Constant horizontal speed for the whole dodge. Gravity and collisions still
## apply: the roll neither floats off a ledge nor passes through a wall.
@export_range(1.0, 2000.0, 1.0) var speed: float = 420.0
## Committed once, on a successful start. A dodge is never refunded.
@export_range(0.0, 1000.0, 0.1) var stamina_cost: float = 20.0

## Length of the invulnerability window. Zero would mean a dodge that never
## evades anything, which [method validation_errors] rejects.
func iframe_duration() -> float:
	return iframe_end_seconds - iframe_start_seconds

## True while [param elapsed] sits inside the authored i-frame window. The
## interval is half-open so the last i-frame tick cannot overlap the first
## vulnerable one.
func is_invulnerable_at(elapsed: float) -> bool:
	if not is_finite(elapsed):
		return false
	return elapsed >= iframe_start_seconds and elapsed < iframe_end_seconds

## Every duration must be positive and finite, and the i-frame window must be a
## real sub-interval of the dodge: a window that starts after it ends, or that
## runs past the dodge itself, would make the move unreadable to the player.
## [param owner_id] is prefixed to each message when the caller has one.
func validation_errors(owner_id: StringName = &"") -> PackedStringArray:
	var errors := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	if not is_finite(duration_seconds) or duration_seconds <= 0.0:
		errors.append("%sdodge duration_seconds must be a positive finite duration" % prefix)
	if not is_finite(iframe_start_seconds) or iframe_start_seconds < 0.0:
		errors.append("%sdodge iframe_start_seconds must be a finite duration at or after the start" % prefix)
	if not is_finite(iframe_end_seconds) or iframe_end_seconds <= 0.0:
		errors.append("%sdodge iframe_end_seconds must be a positive finite duration" % prefix)
	if is_finite(iframe_start_seconds) and is_finite(iframe_end_seconds) and iframe_end_seconds <= iframe_start_seconds:
		errors.append("%sdodge iframe_end_seconds must come after iframe_start_seconds" % prefix)
	if is_finite(iframe_end_seconds) and is_finite(duration_seconds) and iframe_end_seconds > duration_seconds:
		errors.append("%sdodge i-frames must end inside duration_seconds" % prefix)
	if not is_finite(speed) or speed <= 0.0:
		errors.append("%sdodge speed must be a positive finite speed" % prefix)
	if not is_finite(stamina_cost) or stamina_cost < 0.0:
		errors.append("%sdodge stamina_cost must be a finite, non-negative cost" % prefix)
	return errors
