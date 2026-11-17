@tool
extends Node

signal changed

const Analysis := preload("traversal_analysis.gd")
const Maintenance := preload("field_maintenance.gd")
const Recovery := preload("region_recovery.gd")
const BASE := "res://.godot/rtc_traversal"

var report: Dictionary = {}
var message := "Not evaluated. Analyze the current region explicitly."
var running := false
var root: Node2D
var region: RegionDefinition
var _job := ""
var _pid := -1
var _expected := ""
var _snapshot_expected := ""
var _elapsed := 0.0
var _cancelled := false

var _watched: Array[Object] = []
var _keys: Array[Array] = []
var _resources: Array[Resource] = []

func _ready() -> void:
	set_process(false)

func analyze(scene: Node2D, definition: RegionDefinition) -> void:
	if running:
		cancel()
		return
	clear()
	if scene == null or not scene.has_method("configure_server_runtime") or definition == null or definition.entry_point_ids.is_empty():
		message = "A uniquely linked RegionDefinition and an ENTRY are required."
		changed.emit()
		return
	if not scene.transform.is_finite() or is_zero_approx(scene.transform.determinant()):
		message = "Invalid region root Transform. Fix it before analysis."
		changed.emit()
		return
	if not Maintenance.disk_matches(definition):
		message = "RegionDefinition differs from disk. Reload/review the Resource before analyzing."
		changed.emit()
		return
	root = scene
	region = definition
	report = Analysis.extract(root, region)
	_expected = report.fingerprint
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	if not Recovery.safe_path(BASE) or DirAccess.make_dir_recursive_absolute(BASE) != OK:
		message = "Cannot create a safe traversal job folder."
		changed.emit()
		return
	_job = BASE.path_join(token)
	if DirAccess.make_dir_absolute(_job) != OK:
		message = "Cannot reserve traversal job."
		changed.emit()
		return
	var packed := PackedScene.new()
	if packed.pack(root) != OK or ResourceSaver.save(packed, _job.path_join("scene.tscn")) != OK:
		_initialization_failed("Cannot serialize the analysis snapshot.")
		return
	# The editor may have @tool-generated child resource state that is normalized
	# by .tscn serialization. Compare the worker with a cache-free snapshot, and
	# separately compare the current live scene with its original fingerprint.
	var snapshot_packed := ResourceLoader.load(_job.path_join("scene.tscn"), "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if snapshot_packed == null:
		_initialization_failed("Cannot reload serialized snapshot.")
		return
	var snapshot := snapshot_packed.instantiate() as Node2D
	if snapshot == null:
		_initialization_failed("Serialized snapshot has no Node2D root.")
		return
	_snapshot_expected = Analysis.fingerprint(snapshot, region)
	snapshot.free()
	var file := FileAccess.open(_job.path_join("request.json"), FileAccess.WRITE)
	if file == null:
		_initialization_failed("Cannot write traversal request.")
		return
	file.store_string(JSON.stringify({"region": String(region.id), "token": token, "fingerprint": _snapshot_expected,
		"scene": _job.path_join("scene.tscn"), "output": _job.path_join("result.json"), "fps": report.model.physics_fps}))
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		_initialization_failed("Cannot finish writing traversal request.")
		return
	_pid = OS.create_process("python", PackedStringArray([ProjectSettings.globalize_path("res://tools/analyze_traversal.py"),
		"--godot", OS.get_executable_path(), "--request", ProjectSettings.globalize_path(_job.path_join("request.json")),
		"--owner-pid", str(OS.get_process_id())]), false)
	if _pid < 0:
		_initialization_failed("Could not launch Python. Verify Python is on PATH.")
		return
	_watch(root)
	_cancelled = false
	running = true
	message = "Candidates extracted. Isolated PlayerActor physics verification is running."
	set_process(true)
	changed.emit()

func _initialization_failed(reason: String) -> void:
	# No child was launched. Only remove this reserved token directory, never
	# recurse through arbitrary content or an executing/linked job.
	if not running and _pid < 0 and _job.get_base_dir() == BASE and _job.get_file().length() == 32 and _job.get_file().is_valid_hex_number(false) and Recovery.safe_path(_job):
		var directory := DirAccess.open(_job)
		if directory != null:
			for name in directory.get_files():
				if name in ["scene.tscn", "request.json", "scene.tscn.uid"] and Recovery.safe_path(_job.path_join(name)):
					DirAccess.remove_absolute(_job.path_join(name))
			DirAccess.remove_absolute(_job)
	_job = ""
	report = {}
	root = null
	region = null
	message = reason
	changed.emit()

func _watch(scene: Node2D) -> void:
	if region != null:
		region.changed.connect(invalidate)
		_resources.append(region)
	for node in [scene] + scene.find_children("*", "Node2D", true, false):
		if node is Node2D:
			node.item_rect_changed.connect(invalidate)
			node.child_order_changed.connect(invalidate)
			_watched.append(node)
			_keys.append(_watch_key(node))
			var resource: Resource
			if node is CollisionShape2D:
				resource = node.shape
			elif node is ClimbableArea2D:
				resource = node.definition
			if resource != null and not _resources.has(resource):
				resource.changed.connect(invalidate)
				_resources.append(resource)

static func _watch_key(node: Node2D) -> Array:
	var key: Array = [node.transform, node.process_mode]
	if node is FieldPlatform:
		key.append_array([node.size, node.one_way])
	if node is CollisionObject2D:
		key.append_array([node.collision_layer, node.collision_mask])
	if node is CollisionShape2D:
		key.append_array([node.shape, node.disabled, node.one_way_collision])
	if node is PlayerSpawnPoint:
		key.append(node.spawn_index)
	if node is RegionPoint:
		key.append_array([node.point_id, node.kind, node.requires_landing])
	if node is ClimbableArea2D:
		key.append_array([node.definition, node.top_marker, node.bottom_marker])
		if node.definition != null:
			var definition: ClimbableDefinition = node.definition
			key.append_array([definition.speed_multiplier, definition.alignment_speed, definition.alignment_tolerance, definition.requires_interaction,
				definition.allow_top_exit, definition.allow_bottom_exit, definition.allow_jump_exit])
	return key

func invalidate() -> void:
	if report.is_empty():
		return
	if running:
		cancel()
	report = {}
	message = "Analysis is stale. Scene changed; analyze again."
	changed.emit()

func cancel() -> void:
	_cancelled = true
	if running and not _job.is_empty():
		var file := FileAccess.open(_job.path_join("cancel"), FileAccess.WRITE)
		if file != null:
			file.close()
	message = "Cancellation requested. Pending work is not verified."
	report = {}
	changed.emit()

func clear() -> void:
	if running:
		cancel()
	for object in _watched:
		if is_instance_valid(object) and object.item_rect_changed.is_connected(invalidate):
			object.item_rect_changed.disconnect(invalidate)
		if is_instance_valid(object) and object.child_order_changed.is_connected(invalidate):
			object.child_order_changed.disconnect(invalidate)
	_watched.clear()
	_keys.clear()
	for resource in _resources:
		if resource.changed.is_connected(invalidate):
			resource.changed.disconnect(invalidate)
	_resources.clear()
	if not running:
		set_process(false)
		_pid = -1
	report = {}
	root = null
	region = null
	message = "Not evaluated."
	changed.emit()

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.2:
		return
	_elapsed = 0
	# Transform changes have no public Node2D signal. Poll only cached local
	# transforms at 5 Hz; never rescan content or run physics in the editor.
	if not report.is_empty():
		for index in _watched.size():
			if not is_instance_valid(_watched[index]) or _watch_key(_watched[index]) != _keys[index]:
				invalidate()
				break
	if not running:
		set_process(not report.is_empty())
		return
	var path := _job.path_join("status.json")
	if not FileAccess.file_exists(path):
		if not OS.is_process_running(_pid):
			running = false
			set_process(false)
			report = {}
			message = "Verifier terminated without a status file. See " + _job.path_join("godot.log")
			changed.emit()
		return
	var status: Variant = _read_json(path, 65536)
	if not status is Dictionary:
		cancel()
		running = false
		report = {}
		set_process(false)
		message = "Malformed verifier status rejected. Analyze again."
		changed.emit()
		return
	running = false
	set_process(false)
	if _cancelled:
		report = {}
		message = "Analysis cancelled or invalidated. No verification result imported."
	elif status.get("state") != "complete" or status.get("return_code") != 0:
		report = {}
		message = "Verifier %s, exit %s. Log %s" % [status.get("state"), status.get("return_code"), _job.path_join("godot.log")]
	elif not is_instance_valid(root) or Analysis.fingerprint(root, region) != _expected:
		report = {}
		message = "Snapshot changed. Result discarded."
	else:
		var result: Variant = _read_json(_job.path_join("result.json"), 32000000)
		if valid_report(result, _snapshot_expected) and result.get("token") == _job.get_file():
			report = result
			message = "%s | %s" % [report.status, report.metrics]
		else:
			report = {}
			message = "Malformed or stale verifier report rejected."
	set_process(not report.is_empty())
	changed.emit()

static func _read_json(path: String, maximum_bytes: int) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > maximum_bytes:
		return null
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return null
	return parser.data

static func valid_report(value: Variant, fingerprint: String) -> bool:
	if not value is Dictionary or value.get("schema") != 1 or not value.get("region") is String or value.get("fingerprint") != fingerprint:
		return false
	for key in ["surfaces", "edges", "starts", "climbs", "escapes", "routes", "issues"]:
		if not value.get(key) is Array:
			return false
	if value.surfaces.size() > Analysis.SURFACE_LIMIT or value.edges.size() > Analysis.EDGE_LIMIT or value.routes.size() > 128 or value.starts.size() > 32 or value.escapes.size() > 4 or value.climbs.size() > 64 or value.issues.size() > 10000:
		return false
	if not value.get("partial") is bool or not value.get("status") is String or not value.get("metrics") is Dictionary or not value.get("model") is Dictionary:
		return false
	for key in ["speed", "acceleration", "deceleration", "gravity", "physics_fps"]:
		if not _number(value.model.get(key)) or value.model[key] <= 0:
			return false
	if not _number(value.model.get("jump_velocity")) or value.model.jump_velocity >= 0 or not _point(value.model.get("body")) or not value.model.get("profile") is String:
		return false
	if value.model.body[0] <= 0 or value.model.body[1] <= 0:
		return false
	if value.model.has("input_checks"):
		var checks: Variant = value.model.input_checks
		if not checks is Dictionary:
			return false
		for key in ["jump", "air_reverse", "landing"]:
			if not checks.get(key) is bool:
				return false
		if checks.has("trace") and not _trace(checks.trace):
			return false
	var samples := 0
	for index in value.surfaces.size():
		var surface: Variant = value.surfaces[index]
		if not surface is Dictionary or surface.get("id") != index or not _path(surface.get("path")) or not _path(surface.get("body_path")):
			return false
		for property in ["left", "right", "y", "top"]:
			if not _number(surface.get(property)):
				return false
		if surface.left > surface.right or not surface.get("status") in ["Candidate", "Verified", "Not Evaluated"]:
			return false
	for start in value.starts:
		if not _start(start):
			return false
	for escape in value.escapes:
		if not escape is Dictionary or not _path(escape.get("path")) or not escape.get("id") is String or not _point(escape.get("position")):
			return false
	for climb in value.climbs:
		if not climb is Dictionary or not _path(climb.get("path")) or not _point(climb.get("top")) or not _point(climb.get("bottom")):
			return false
	for edge in value.edges:
		if not edge is Dictionary or not _index(edge.get("from"), value.surfaces.size()) or not _index(edge.get("to"), value.surfaces.size()):
			return false
		if not edge.get("kind") in ["WALK", "JUMP", "DROP", "CLIMB_UP", "CLIMB_DOWN"] or not edge.get("status") in ["Verified", "Candidate", "Unreachable Within Tested Inputs", "Not Evaluated"] or not edge.get("reason") is String:
			return false
		if not _trace(edge.get("trace")) or edge.status == "Verified" and edge.trace.size() < 2:
			return false
		if edge.status == "Verified" and (not _trace(edge.get("inputs")) or edge.inputs.size() != edge.trace.size()):
			return false
		if edge.kind.begins_with("CLIMB") and edge.status == "Verified" and (not _path(edge.get("climb_path")) or edge.climb_path != edge.get("climb")):
			return false
		if edge.has("contacts"):
			if not edge.contacts is Array or edge.contacts.size() > 128:
				return false
			for contact in edge.contacts:
				if not _path(contact):
					return false
		samples += edge.trace.size()
	for route in value.routes:
		if not route is Dictionary or not _start(route.get("start")) or not _path(route.get("path")) or not route.get("escape") is String or not _trace(route.get("trace")) or not route.get("edges") is Array:
			return false
		if not route.get("status") in ["Verified Reachable", "Candidate Reachable", "Unreachable Within Tested Inputs", "Not Evaluated", "Invalid Spawn", "Invalid Destination"]:
			return false
		if route.status == "Verified Reachable" and (route.trace.size() < 2 or not route.get("inputs") is Array or route.inputs.size() != route.trace.size()):
			return false
		for edge_id in route.edges:
			if not _index(edge_id, value.edges.size()) or route.status == "Verified Reachable" and value.edges[int(edge_id)].status != "Verified":
				return false
		samples += route.trace.size()
	for issue in value.issues:
		if not issue is Dictionary or not _path(issue.get("path")) or not issue.get("reason") is String or not issue.get("status") is String:
			return false
	return samples <= 200000

static func _path(value: Variant) -> bool:
	return value is String and not value.is_empty() and not value.is_absolute_path() and not ".." in value.split("/") and not ":" in value

static func _point(value: Variant) -> bool:
	return value is Array and value.size() == 2 and _number(value[0]) and _number(value[1])

static func _trace(value: Variant) -> bool:
	if not value is Array or value.size() > 10000:
		return false
	for at in value:
		if not _point(at):
			return false
	return true

static func _index(value: Variant, count: int) -> bool:
	return _number(value) and float(value) == floorf(float(value)) and value >= 0 and value < count

static func _start(value: Variant) -> bool:
	return value is Dictionary and _path(value.get("path")) and value.get("kind") is String and _index(value.get("slot"), NetworkManager.MAX_PLAYERS) and _point(value.get("position"))

static func _number(value: Variant) -> bool:
	return (value is float or value is int) and is_finite(float(value))

func _exit_tree() -> void:
	# A retiring controller must not refresh UI that is also leaving the tree.
	set_block_signals(true)
	cancel()
	clear()
