extends Node
## Tracks which local UI owners are currently suppressing gameplay input.

signal gameplay_input_blocked_changed(blocked: bool)

const GAMEPLAY_ACTIONS := [
	&"move_left", &"move_right", &"move_up", &"move_down",
	&"jump", &"primary_attack", &"dodge", &"interact", &"use_quick_item",
]

var _held_actions: Dictionary[StringName, bool] = {}
var _owners: Dictionary[int, WeakRef] = {}
var _blocked := false

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(_blocked)

func acquire(owner: Object) -> void:
	if not is_instance_valid(owner):
		return
	_prune_dead_owners()
	var id := owner.get_instance_id()
	if not _owners.has(id):
		_owners[id] = weakref(owner)
	_update_blocked()

func release(owner: Object) -> void:
	_prune_dead_owners()
	if is_instance_valid(owner):
		_owners.erase(owner.get_instance_id())
	_update_blocked()

func is_gameplay_blocked() -> bool:
	if _blocked:
		_prune_dead_owners()
		_update_blocked()
	return _blocked

## The release requirement belongs to this process and survives actor replacement.
func is_action_rearmed(action: StringName) -> bool:
	if not _held_actions.has(action):
		return true
	if Input.is_action_pressed(action):
		return false
	_held_actions.erase(action)
	return true

func _input(_event: InputEvent) -> void:
	# Observe key releases before the GUI can consume them, even in the menu.
	if _held_actions.is_empty():
		return
	for action in _held_actions.keys():
		is_action_rearmed(action)

func _process(_delta: float) -> void:
	is_gameplay_blocked()

func _prune_dead_owners() -> void:
	for id in _owners.keys():
		if _owners[id].get_ref() == null:
			_owners.erase(id)

func _update_blocked() -> void:
	var blocked := not _owners.is_empty()
	if blocked != _blocked:
		_blocked = blocked
		if not blocked:
			_held_actions.clear()
			for action: StringName in GAMEPLAY_ACTIONS:
				if Input.is_action_pressed(action):
					_held_actions[action] = true
		set_process(blocked)
		gameplay_input_blocked_changed.emit(blocked)
