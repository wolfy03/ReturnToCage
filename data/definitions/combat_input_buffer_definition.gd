class_name CombatInputBufferDefinition
extends Resource
## How long an authoritative combat intent waits for its moment.
##
## A plain [Resource], authored once per actor. The buffer this configures is a
## server-side scheduler, not a client convenience: it only decides *when* an
## already-validated intent runs, never whether the client may run it.

## How long a pending intent survives. Long enough that a player pressing
## slightly early still lands the follow-up, short enough that an input they have
## mentally abandoned does not fire on its own.
@export_range(0.01, 1.0, 0.01) var buffer_seconds: float = 0.15

func validation_errors(owner_id: StringName = &"") -> PackedStringArray:
	var errors := PackedStringArray()
	var prefix := "%s: " % owner_id if not owner_id.is_empty() else ""
	if not is_finite(buffer_seconds) or buffer_seconds <= 0.0:
		errors.append("%sinput buffer_seconds must be a positive finite duration" % prefix)
	return errors
