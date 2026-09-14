class_name CombatActionWindowDefinition
extends Resource
## One authored window inside a combat action, during which a specific follow-up
## is permitted.
##
## Like [AttackDefinition] and [DodgeDefinition] this is a plain [Resource], not
## registry content: it only exists as a sub-resource of the action that owns it.
##
## The window is the *only* thing that decides whether a cancel or a chain may
## happen. [CombatActionController] validates the shape of a transition and knows
## nothing about time; this definition supplies the time.

## A disabled window permits nothing. Authoring a follow-up is deliberately
## opt-in, so an attack without an authored window simply cannot be cancelled.
@export var enabled: bool = false
## Start of the window, measured from the start of the owning action.
@export_range(0.0, 10.0, 0.01) var start_seconds: float = 0.0
## End of the window, exclusive.
@export_range(0.0, 10.0, 0.01) var end_seconds: float = 0.0

## Half-open interval `[start, end)`, matching the dodge i-frame convention, so
## the last permitted tick can never overlap the first forbidden one.
func contains(elapsed: float) -> bool:
	if not enabled or not is_finite(elapsed):
		return false
	return elapsed >= start_seconds and elapsed < end_seconds

## Validates the window against the bounds of the action that owns it.
## [param min_start] and [param max_end] are the earliest and latest points the
## owner allows, so an owner can forbid a window in its committed phases without
## this Resource knowing what those phases are.
func validation_errors(
	owner_id: StringName = &"",
	min_start: float = 0.0,
	max_end: float = INF
) -> PackedStringArray:
	var errors := PackedStringArray()
	if not enabled:
		return errors
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	if not is_finite(start_seconds) or start_seconds < 0.0:
		errors.append("%swindow start_seconds must be a finite, non-negative time" % prefix)
	if not is_finite(end_seconds):
		errors.append("%swindow end_seconds must be finite" % prefix)
	if is_finite(start_seconds) and is_finite(end_seconds) and end_seconds <= start_seconds:
		errors.append("%swindow end_seconds must come after start_seconds" % prefix)
	if is_finite(start_seconds) and is_finite(min_start) and start_seconds < min_start - 0.0001:
		errors.append("%swindow may not start before %.3fs of its action" % [prefix, min_start])
	if is_finite(end_seconds) and is_finite(max_end) and end_seconds > max_end + 0.0001:
		errors.append("%swindow may not end after %.3fs of its action" % [prefix, max_end])
	return errors
