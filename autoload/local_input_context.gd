extends Node
## Tracks which local UI owners are currently suppressing gameplay input.

signal gameplay_input_blocked_changed(blocked: bool)

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
		set_process(blocked)
		gameplay_input_blocked_changed.emit(blocked)
