class_name CommandWatchdog
extends RefCounted
## The two time limits of a command-driven validation probe.
##
## A running command must finish within command_msec. A role that is only
## waiting for its next command gets the longer idle_msec: the controller drives
## the other roles in between, and that alone exceeds a minute on a slow
## rendered runner. The idle limit still ends an orphaned process.
##
## Both limits restart when a command is accepted. A command that completes
## inside the frame that accepted it is never seen as busy by observe(), so the
## idle limit cannot depend on observing a busy frame.

var command_msec: int
var idle_msec: int
var _command_deadline: int
var _idle_deadline: int

func _init(p_command_msec: int, p_idle_msec: int, now_msec: int) -> void:
	command_msec = p_command_msec
	idle_msec = p_idle_msec
	command_started(now_msec)

func command_started(now_msec: int) -> void:
	_command_deadline = now_msec + command_msec
	_idle_deadline = now_msec + idle_msec

## Call once per frame. Returns true when the applicable limit has passed.
func observe(now_msec: int, busy: bool) -> bool:
	if busy:
		_idle_deadline = now_msec + idle_msec
	return now_msec > (_command_deadline if busy else _idle_deadline)
