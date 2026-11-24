class_name SignalBindings
extends RefCounted

# Records the autoload signal connections a long-lived UI node makes, so it can
# release exactly those connections when it leaves the tree and restore them if
# it re-enters.
#
# Godot already drops a connection when its target object is freed (bound
# methods and GDScript lambdas alike), so nothing leaks after free(). What it
# does not cover is the window in which a node has left the tree but is not
# freed yet (remove_child(), a pending queue_free(), shutdown ordering): an
# autoload emitting then still reaches the node, and callbacks that use
# get_tree() or scene state fail. Disconnecting in _exit_tree closes it.
#
# Store a Callable once (including `method.unbind(n)` adapters) and reuse the
# same value for connect and disconnect; anonymous lambdas written inline at the
# connect site cannot be released this way.

var _bindings: Array[Array] = []

func add(source_signal: Signal, callable: Callable) -> void:
	for binding in _bindings:
		if binding[0] == source_signal and binding[1] == callable:
			push_error("SignalBindings: duplicate binding for %s" % source_signal.get_name())
			return
	_bindings.append([source_signal, callable])

func connect_all() -> void:
	for binding in _bindings:
		var source_signal: Signal = binding[0]
		if not source_signal.is_connected(binding[1]):
			source_signal.connect(binding[1])

func disconnect_all() -> void:
	for binding in _bindings:
		var source_signal: Signal = binding[0]
		if source_signal.is_connected(binding[1]):
			source_signal.disconnect(binding[1])

func connected_count() -> int:
	var count := 0
	for binding in _bindings:
		if (binding[0] as Signal).is_connected(binding[1]):
			count += 1
	return count

func size() -> int:
	return _bindings.size()
