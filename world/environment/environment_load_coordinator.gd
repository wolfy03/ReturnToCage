class_name EnvironmentLoadCoordinator
extends Node
## Client-side owner for threaded environment loads that may outlive a world.
##
## ResourceLoader requests are global and cannot be cancelled. Presenters detach
## their callbacks when removed, while this node remains under SceneTree.root,
## polls the request to completion, and collects its token without blocking a
## world transition. It is created lazily only when a visible presenter loads an
## environment; server runtime scenes never create it.

const NODE_NAME := &"EnvironmentLoadCoordinator"

var _next_request_id: int = 1
var _requests: Dictionary[int, Dictionary] = {}
var _path_request_ids: Dictionary[String, Array] = {}

static func for_node(owner: Node) -> EnvironmentLoadCoordinator:
	if owner == null or not owner.is_inside_tree():
		return null
	var root := owner.get_tree().root
	var existing := root.get_node_or_null(NodePath(String(NODE_NAME))) as EnvironmentLoadCoordinator
	if existing != null:
		return existing
	var coordinator := EnvironmentLoadCoordinator.new()
	coordinator.name = String(NODE_NAME)
	coordinator.process_mode = Node.PROCESS_MODE_ALWAYS
	root.add_child(coordinator)
	return coordinator

## Starts or joins a threaded load. The callback receives
## (request_id, path, status, resource). Returns 0 when the request is rejected.
func request(path: String, callback: Callable) -> int:
	if path.is_empty() or not callback.is_valid():
		return 0
	if not _path_request_ids.has(path):
		if ResourceLoader.load_threaded_request(path, "EnvironmentDefinition") != OK:
			return 0
		_path_request_ids[path] = []
	var request_id := _next_request_id
	_next_request_id += 1
	_requests[request_id] = {"path": path, "callback": callback}
	var request_ids: Array = _path_request_ids[path]
	request_ids.append(request_id)
	set_process(true)
	return request_id

## Detaches one consumer without abandoning the underlying loader token.
func cancel(request_id: int) -> void:
	if request_id <= 0:
		return
	_requests.erase(request_id)

func pending_path_count() -> int:
	return _path_request_ids.size()

func _ready() -> void:
	set_process(not _path_request_ids.is_empty())

func _process(_delta: float) -> void:
	for path: String in _path_request_ids.keys():
		var status := ResourceLoader.load_threaded_get_status(path)
		if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
			continue
		var resource := ResourceLoader.load_threaded_get(path)
		_finish_path(path, status, resource)
	if _path_request_ids.is_empty():
		set_process(false)

func _finish_path(path: String, status: ResourceLoader.ThreadLoadStatus, resource: Resource) -> void:
	var request_ids: Array = _path_request_ids.get(path, [])
	_path_request_ids.erase(path)
	for request_id: int in request_ids:
		var request: Dictionary = _requests.get(request_id, {})
		_requests.erase(request_id)
		if request.is_empty():
			continue
		var callback: Callable = request.get("callback", Callable())
		if callback.is_valid():
			callback.call(request_id, path, status, resource)

func _exit_tree() -> void:
	# The coordinator survives world replacement and normally has no pending work
	# here. At application shutdown only, collect anything left so Godot does not
	# retain ResourceLoader::LoadToken instances after SceneTree teardown.
	for path: String in _path_request_ids.keys():
		if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_get(path)
	_path_request_ids.clear()
	_requests.clear()
