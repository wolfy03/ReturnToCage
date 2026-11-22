extends Node

const ShutdownGuard := preload("res://tools/map_bridge/shutdown_guard.gd")
const Contract := preload("res://tools/map_bridge/scene_contract.gd")
const PROTOCOL := 1
const COMMANDS := ["inspect_project", "inspect_region", "import_region", "validate_document", "export_region", "validate_export"]
var request: Dictionary
var region: RegionDefinition
var scene: PackedScene
var scene_root: Node2D

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--request":
		get_tree().quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	if not parsed is Dictionary or not parsed.get("result") is String:
		get_tree().quit(2)
		return
	request = parsed
	print("RTC_BRIDGE VALIDATION_STARTED ", request.get("operation"))
	if request.get("protocol") != PROTOCOL or not request.get("request_id") is String or request.get("operation") not in COMMANDS:
		_finish({}, "INVALID_DOCUMENT: invalid protocol or operation")
		return
	if request.operation == "inspect_project":
		var regions: Array = []
		for definition in ContentRegistry.all_definitions():
			if definition is RegionDefinition:
				regions.append({"id": String(definition.id), "name": definition.display_name,
					"definition": definition.resource_path.trim_prefix("res://"), "scene": definition.scene_path.trim_prefix("res://")})
		regions.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.id < b.id)
		_finish({"regions": regions})
		return
	var path: Variant = request.get("region_path")
	if not path is String or not path.begins_with("res://data/content/") or not path.ends_with(".tres") \
			or path != path.simplify_path() or not ResourceLoader.exists(path):
		_finish({}, "RESOURCE_MISSING: RegionDefinition path %s" % path)
		return
	region = ResourceLoader.load(path) as RegionDefinition
	if region == null or ContentRegistry.get_definition(region.id) != region or not ResourceLoader.exists(region.scene_path, "PackedScene"):
		_finish({}, "RESOURCE_MISSING: RegionDefinition or registered PackedScene %s" % path)
		return
	scene = ResourceLoader.load(region.scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if scene == null or not scene.can_instantiate():
		_finish({}, "RESOURCE_MISSING: cannot load %s" % region.scene_path)
		return
	var node := scene.instantiate()
	if not node is Node2D:
		node.free()
		_finish({}, "UNSUPPORTED_NODE: expected a Node2D region root")
		return
	scene_root = node
	print("RTC_BRIDGE SCENE_LOADED")
	var failures := region.validate_definition(ContentRegistry)
	if not failures.is_empty():
		_finish({}, "RUNTIME_LOAD_FAILED: " + "\n".join(failures))
		return
	var data := Contract.inventory(scene_root, String(region.id))
	if data.has("error"):
		_finish({}, "INVALID_DOCUMENT: " + data.error)
		return
	var signal_links := Contract.connections(scene, scene_root)
	var summary := _summary(data, signal_links)
	match request.operation:
		"inspect_region", "import_region":
			_finish(summary)
		"validate_export":
			var expected: Variant = request.get("expected")
			if not expected is Dictionary or not _same_json(expected.get("scene_state"), summary.scene_state):
				var details := _difference(expected.get("scene_state", {}) if expected is Dictionary else {}, summary.scene_state)
				_finish({}, "EXPORT_FAILED: semantic reload differs from approved tree " + details)
				return
			if expected.get("scene_uid") != summary.scene_uid or expected.get("region_uid") != summary.region_uid:
				_finish({}, "UID_CONFLICT: Scene or RegionDefinition UID changed on reload")
				return
			if expected.get("region_hash") != summary.region_hash or expected.get("output_hash") != summary.scene_hash:
				_finish({}, "SOURCE_MODIFIED: staged Scene or RegionDefinition bytes changed")
				return
			print("RTC_BRIDGE CONTRACT_PASS")
			var collision_issue := await _runtime_collision()
			_finish(summary, collision_issue)
		_:
			var source_pin: Variant = request.get("source")
			if (not source_pin is Dictionary or source_pin.get("region_hash") != summary.region_hash
					or source_pin.get("scene_hash") != summary.scene_hash or source_pin.get("scene_path") != summary.scene_path):
				_finish({}, "SOURCE_MODIFIED: loaded files do not match the imported source")
				return
			if source_pin.get("scene_uid") != summary.scene_uid or source_pin.get("region_uid") != summary.region_uid:
				_finish({}, "UID_CONFLICT: loaded resource UID does not match the imported source")
				return
			var issue := _apply_document(data, signal_links)
			if not issue.is_empty():
				_finish({}, issue)
				return
			var field_errors := RegionDefinition.validate_field_nodes(region, scene_root, ContentRegistry)
			if not field_errors.is_empty():
				_finish({}, "INVALID_DOCUMENT: " + "\n".join(field_errors))
				return
			if request.operation == "validate_document":
				var changed := Contract.inventory(scene_root, String(region.id))
				if changed.has("error"):
					_finish({}, "INVALID_DOCUMENT: " + changed.error)
				else:
					_finish(_summary(changed, signal_links))
				return
			_export(summary, signal_links)

func _difference(before: Dictionary, after: Dictionary) -> String:
	var old: Dictionary = before.get("nodes", {})
	var now: Dictionary = after.nodes
	var details: Array[String] = []
	for key: String in old:
		if not now.has(key):
			details.append("missing " + key)
		elif not _same_json(old[key], now[key]):
			var properties: Array[String] = []
			for property: String in old[key].properties:
				if old[key].properties[property] != now[key].properties.get(property):
					properties.append(property)
			details.append("%s [%s]" % [key, ", ".join(properties)])
	for key: String in now:
		if not old.has(key):
			details.append("added " + key)
	if before.get("order") != after.order:
		details.append("node order")
	if before.get("connections") != after.connections:
		details.append("persistent connections")
	if before.get("subresource_aliases") != after.subresource_aliases:
		details.append("shared built-in resources")
	return "; ".join(details.slice(0, 12))

func _summary(data: Dictionary, links: Array) -> Dictionary:
	var snapshot := Contract.scene_state(scene_root, links)
	return {"region_id": String(region.id), "display_name": region.display_name,
		"region_path": region.resource_path.trim_prefix("res://"), "scene_path": region.scene_path.trim_prefix("res://"),
		"region_uid": Contract.uid(region.resource_path), "scene_uid": Contract.uid(region.scene_path),
		"region_hash": FileAccess.get_sha256(region.resource_path), "scene_hash": FileAccess.get_sha256(region.scene_path),
		"scene_state": snapshot, "node_count": snapshot.nodes.size(),
		"objects": data.objects, "bindings": data.bindings, "extent": data.extent, "warnings": data.warnings}

func _apply_document(data: Dictionary, links: Array) -> String:
	var objects: Variant = request.get("objects")
	if not objects is Array or objects.size() > 50000:
		return "INVALID_DOCUMENT: expected at most 50,000 objects"
	if request.get("region_id") != String(region.id) or request.get("display_name") != region.display_name:
		return "INVALID_DOCUMENT: RegionDefinition metadata is read-only"
	if not _same_json(request.get("bindings"), data.bindings):
		return "SOURCE_MODIFIED: source node identity or transform differs from the imported binding"
	if scene.get_state().get_base_scene_state() != null:
		return "UNSUPPORTED_NODE: inherited root scene export is unavailable"
	var by_id := {}
	for previous: Dictionary in data.objects:
		by_id[previous.id] = previous
	var seen := {}
	for object: Variant in objects:
		if not object is Dictionary:
			return "INVALID_DOCUMENT: object must be a dictionary"
		var error := Contract.object_error(object)
		if not error.is_empty():
			return error
		if seen.has(object.id):
			return "INVALID_DOCUMENT: duplicate object ID %s" % object.id
		seen[object.id] = true
		var original: Dictionary = by_id.get(object.id, {})
		if not original.is_empty() and original.type != object.type:
			return "INVALID_DOCUMENT: imported object type changed (%s)" % object.id
		if not original.is_empty() and _same_object(original, object):
			continue
		var target := scene_root.get_node_or_null(NodePath(data.bindings[object.id].path)) as Node2D if not original.is_empty() else null
		error = Contract.apply(scene_root, target, object)
		if not error.is_empty():
			return error
	for key: String in by_id:
		if not seen.has(key):
			var victim := scene_root.get_node(NodePath(data.bindings[key].path))
			var issue := Contract.removal_issue(scene_root, victim, links)
			if not issue.is_empty():
				return issue
			victim.free()
	return ""

func _same_json(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for key: Variant in a:
			if not b.has(key) or not _same_json(a[key], b[key]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for index in range(a.size()):
			if not _same_json(a[index], b[index]):
				return false
		return true
	return a == b

func _same_object(a: Dictionary, b: Dictionary) -> bool:
	return _same_json(a.position, b.position) and _same_json(a.size, b.size) and a.rotation == b.rotation \
		and a.properties.get("one_way", false) == b.properties.get("one_way", false) \
		and a.properties.get("texture_path", "") == b.properties.get("texture_path", "")

func _export(original: Dictionary, links: Array) -> void:
	var expected := Contract.scene_state(scene_root, links)
	if expected != original.scene_state:
		var packed := PackedScene.new()
		var error := packed.pack(scene_root)
		var staged := region.scene_path.get_basename() + ".rtc-stage.tscn"
		if error != OK or FileAccess.file_exists(staged):
			_finish({}, "EXPORT_FAILED: pack failed or staging file exists (%s)" % error)
			return
		error = ResourceSaver.save(packed, staged)
		if error == OK and not original.scene_uid.is_empty():
			error = ResourceSaver.set_uid(staged, ResourceUID.text_to_id(original.scene_uid))
		if error != OK or DirAccess.rename_absolute(staged, region.scene_path) != OK:
			_finish({}, "EXPORT_FAILED: ResourceSaver or staging rename failed (%s)" % error)
			return
	var updated := Contract.inventory(scene_root, String(region.id))
	if updated.has("error"):
		_finish({}, "INVALID_DOCUMENT: " + updated.error)
		return
	_finish({"scene_path": original.scene_path, "scene_uid": original.scene_uid, "region_uid": original.region_uid,
		"region_hash": original.region_hash, "source_hash": original.scene_hash, "before_count": original.node_count,
		"node_count": expected.nodes.size(), "output_hash": FileAccess.get_sha256(region.scene_path),
		"scene_state": expected, "objects": updated.objects, "warnings": updated.warnings})

func _runtime_collision() -> String:
	GameSession.start_new_game()
	scene_root.configure_server_runtime(PlayerWorldState.adventure_world_id(region.id), region.id)
	add_child(scene_root)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var errors := RegionDefinition.validate_field_nodes(region, scene_root, ContentRegistry, false)
	for item in scene_root.find_children("*", "StaticBody2D", true, true):
		var data := Contract.classify(item, scene_root)
		if data.get("kind") != "platform":
			continue
		var collider := item.get_node("CollisionShape2D") as CollisionShape2D
		var visual := item.get_node("Visual") as Polygon2D
		var actual := collider.shape as RectangleShape2D
		if actual == null or not Contract.polygon_is_rectangle(visual.polygon, actual.size) \
				or collider.one_way_collision != data.properties.one_way:
			errors.append("Collision size or one-way differs at %s" % scene_root.get_path_to(item))
	if errors.is_empty():
		print("RTC_BRIDGE COLLISION_PASS")
	var instance_id := scene_root.get_instance_id()
	scene_root.queue_free()
	scene_root = null
	await get_tree().process_frame
	if is_instance_id_valid(instance_id):
		errors.append("Collision probe Scene remained alive after queued deletion")
	GameSession.start_new_game()
	return "RUNTIME_LOAD_FAILED: " + "\n".join(errors) if not errors.is_empty() else ""

func _finish(data: Dictionary, error: String = "") -> void:
	print("RTC_BRIDGE CLEANUP_STARTED")
	ShutdownGuard.retain_scripts()
	if is_instance_valid(scene_root):
		scene_root.free()
		scene_root = null
	scene = null
	region = null
	print("RTC_BRIDGE CLEANUP_COMPLETE")
	var result := {"protocol": PROTOCOL, "request_id": request.get("request_id"), "operation": request.get("operation"),
		"status": "PASS" if error.is_empty() else "FAIL", "error_code": error.get_slice(":", 0),
		"message": error, "godot_version": Engine.get_version_info().string,
		"warnings": data.get("warnings", []), "data": data}
	var file := FileAccess.open(request.result, FileAccess.WRITE)
	if file == null:
		get_tree().quit(3)
		return
	file.store_string(JSON.stringify(result, "", true, true))
	file.close()
	print("RTC_BRIDGE RESULT_WRITTEN")
	print("RTC_BRIDGE ENGINE_EXIT_REQUESTED")
	get_tree().quit(0 if error.is_empty() else 1)
