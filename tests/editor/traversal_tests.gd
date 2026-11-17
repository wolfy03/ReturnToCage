extends Node

const Analysis := preload("res://addons/rtc_field_editor/traversal_analysis.gd")
const Controller := preload("res://addons/rtc_field_editor/traversal_controller.gd")
var assertions := 0
var failures := 0

func _ready() -> void:
	call_deferred("_run")

func check(condition: bool, message: String) -> void:
	assertions += 1
	if not condition:
		failures += 1
		push_error("TRAVERSAL TEST " + message)

func _run() -> void:
	var region := ContentRegistry.get_definition(&"sewer_region") as RegionDefinition
	var root := (load(region.scene_path) as PackedScene).instantiate() as Node2D
	var data := Analysis.extract(root, region)
	_lifecycle(root, region)
	check(data.surfaces.size() >= 5, "extract sewer rectangular terrain and landing")
	check(data.climbs.size() == 2, "extract ladder and rope")
	check(data.starts.size() == 8, "fresh and transition starts for all four slots")
	check(data.escapes.size() == 2, "escape markers remain separate from starts")
	check(data.edges.all(func(edge: Dictionary) -> bool: return edge.status == "Candidate"), "geometry never creates verified edges")
	var old_count: int = data.surfaces.size()
	var floor_shape := root.get_node("Terrain/Floor/CollisionShape2D") as CollisionShape2D
	floor_shape.disabled = true
	var reduced := Analysis.extract(root, region)
	check(reduced.surfaces.size() < old_count, "disabled collision excluded")
	floor_shape.disabled = false
	var floor_body := floor_shape.get_parent() as Node2D
	floor_body.rotation = 0.2
	reduced = Analysis.extract(root, region)
	check(reduced.issues.any(func(issue: Dictionary) -> bool: return issue.reason.contains("Rotated")), "rotated terrain explicitly not evaluated")
	floor_body.rotation = 0
	floor_body.scale = Vector2(-1, 1.5)
	reduced = Analysis.extract(root, region)
	check(reduced.surfaces.any(func(surface: Dictionary) -> bool: return surface.body_path == "Terrain/Floor"), "axis-aligned negative and nonuniform scale supported")
	floor_body.scale = Vector2.ONE
	var static_body := floor_body as StaticBody2D
	static_body.collision_layer = 2
	check(not Analysis.extract(root, region).surfaces.any(func(surface: Dictionary) -> bool: return surface.body_path == "Terrain/Floor"), "player collision mask filters authored terrain")
	static_body.collision_layer = 1
	static_body.process_mode = Node.PROCESS_MODE_DISABLED
	check(not Analysis.extract(root, region).surfaces.any(func(surface: Dictionary) -> bool: return surface.body_path == "Terrain/Floor"), "disabled physics body is not a standing candidate")
	static_body.process_mode = Node.PROCESS_MODE_INHERIT
	var saved_shape := floor_shape.shape
	floor_shape.shape = CircleShape2D.new()
	check(Analysis.extract(root, region).issues.any(func(issue: Dictionary) -> bool: return issue.reason.contains("Only rectangular")), "unsupported shape never promoted to rectangular surface")
	floor_shape.shape = saved_shape
	# Default-root runtime is covered by the editor integration; verify the
	# complete sewer input routes again with a translated Scene root here.
	root.position = Vector2(70, 32)
	var result := _verify(root, region)
	await _cancel_live(root, region)
	root.free()
	if not result.is_empty():
		check(result.model.input_checks.jump and result.model.input_checks.air_reverse and result.model.input_checks.landing, "actual jump, airborne reversal and real floor landing")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "JUMP" and edge.status == "Verified"), "jump verified through real input, floor collision and release")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "DROP" and edge.status == "Verified"), "directional drop verified through real movement")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "CLIMB_UP" and edge.status == "Verified"), "actual ladder ascent and stable landing verified")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "CLIMB_DOWN" and edge.status != "Verified"), "one-way landing is not invented as a downward climb-through")
		check(result.routes.size() == 16 and result.routes.all(func(route: Dictionary) -> bool: return route.status == "Verified Reachable" and route.trace.size() >= 2), "all four fresh and ENTRY assignments continuously reach both sewer escapes")
		check(result.routes.any(func(route: Dictionary) -> bool: return route.edges.any(func(id: float) -> bool: return result.edges[int(id)].kind == "CLIMB_UP")), "escape proof includes climb input instead of teleport")
		check(result.edges.filter(func(edge: Dictionary) -> bool: return edge.status == "Verified").all(func(edge: Dictionary) -> bool: return edge.trace.size() >= 2), "verified edges retain physical samples")
		var malformed := result.duplicate(true)
		malformed.edges[0].from = 999
		check(not Controller.valid_report(malformed, result.fingerprint), "report out-of-range node rejected")
		malformed = result.duplicate(true)
		malformed.edges[0].trace = [[NAN, 0]]
		check(not Controller.valid_report(malformed, result.fingerprint), "nonfinite evidence rejected")
		malformed = result.duplicate(true)
		malformed.routes[0].trace = []
		check(not Controller.valid_report(malformed, result.fingerprint), "verified route without input-only samples rejected")
		malformed = result.duplicate(true)
		malformed.issues = [{"path": "../Other", "reason": "bad", "status": "bad"}]
		check(not Controller.valid_report(malformed, result.fingerprint), "node selection cannot escape scene")
		check(not Controller.valid_report(result, "stale"), "stale report rejected")
		malformed = result.duplicate(true)
		malformed.model.input_checks = 42
		check(not Controller.valid_report(malformed, result.fingerprint), "malformed motion diagnostics rejected before UI reads them")
		malformed = result.duplicate(true)
		malformed.edges[0].inputs = []
		check(not Controller.valid_report(malformed, result.fingerprint), "verified edge requires complete frame inputs")
		malformed = result.duplicate(true)
		malformed.edges[0].contacts = ["../Other"]
		check(not Controller.valid_report(malformed, result.fingerprint), "collision source selection stays in authored scene")
		var graph := {"surfaces": [{}, {}], "edges": [{"from": 0, "to": 1, "kind": "DROP", "status": "Verified"}]}
		check(Analysis.reachable(graph, 0) == [0, 1] and Analysis.reachable(graph, 1) == [1], "directed drop graph does not invent an upward return")
	await _fixtures(region)
	print("TRAVERSAL TEST ", "PASS" if failures == 0 else "FAIL", " assertions=", assertions)
	get_tree().quit(0 if failures == 0 else 1)

func _lifecycle(root: Node2D, region: RegionDefinition) -> void:
	var controller := Controller.new()
	var folder := "res://.godot/rtc_traversal/" + Crypto.new().generate_random_bytes(16).hex_encode()
	DirAccess.make_dir_recursive_absolute(folder)
	for name in ["scene.tscn", "request.json"]:
		var file := FileAccess.open(folder.path_join(name), FileAccess.WRITE)
		file.store_string("failed initialization fixture")
		file.close()
	controller.set("_job", folder)
	controller.call("_initialization_failed", "injected save failure")
	check(not DirAccess.dir_exists_absolute(folder), "pre-launch failure removes only the reserved job files")
	check(controller.report.is_empty() and controller.get("_job") == "", "pre-launch failure clears candidate and job state")
	var original := FileAccess.get_sha256(region.scene_path)
	controller.set("_job", region.scene_path.get_base_dir())
	controller.call("_initialization_failed", "invalid cleanup target")
	check(FileAccess.get_sha256(region.scene_path) == original, "cleanup rejects a content directory outside the reserved job")
	controller.region = region
	controller.report = {"candidate": true}
	controller.call("_watch", root)
	region.emit_changed()
	check(controller.report.is_empty(), "RegionDefinition changes invalidate live evidence without a file scan")
	controller.clear()
	check(not region.changed.is_connected(controller.invalidate), "clear disconnects RegionDefinition lifecycle signal")
	DirAccess.make_dir_absolute(folder)
	var status := FileAccess.open(folder.path_join("status.json"), FileAccess.WRITE)
	status.store_string("{broken status")
	status.close()
	controller.set("_job", folder)
	controller.running = true
	controller.report = {"candidate": true}
	controller.call("_process", 0.2)
	check(not controller.running and controller.report.is_empty(), "malformed process status cannot import candidate evidence")
	check(FileAccess.file_exists(folder.path_join("cancel")), "malformed status still signals a potentially running worker to stop")
	DirAccess.remove_absolute(folder.path_join("cancel"))
	DirAccess.remove_absolute(folder.path_join("status.json"))
	DirAccess.remove_absolute(folder)
	controller.free()

func _prepare_job(root: Node2D, region: RegionDefinition) -> Dictionary:
	var token := Crypto.new().generate_random_bytes(16).hex_encode()
	var folder := "res://.godot/rtc_traversal/" + token
	DirAccess.make_dir_recursive_absolute(folder)
	var packed := PackedScene.new()
	check(packed.pack(root) == OK, "pack analysis scene")
	check(ResourceSaver.save(packed, folder.path_join("scene.tscn")) == OK, "save analysis snapshot")
	var snapshot := (ResourceLoader.load(folder.path_join("scene.tscn"), "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var hash := Analysis.fingerprint(root, region)
	check(hash == Analysis.fingerprint(snapshot, region), "cache-free snapshot fingerprint equality")
	snapshot.free()
	var request := {"region": String(region.id), "token": token, "fingerprint": hash,
		"scene": folder.path_join("scene.tscn"), "output": folder.path_join("result.json"), "fps": Analysis.model().physics_fps}
	var file := FileAccess.open(folder.path_join("request.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(request))
	file.close()
	return {"folder": folder, "hash": hash}

func _verify(root: Node2D, region: RegionDefinition) -> Dictionary:
	var job := _prepare_job(root, region)
	var folder: String = job.folder
	var hash: String = job.hash
	var output: Array = []
	var code := OS.execute("python", PackedStringArray([ProjectSettings.globalize_path("res://tools/analyze_traversal.py"),
		"--godot", OS.get_executable_path(), "--request", ProjectSettings.globalize_path(folder.path_join("request.json"))]), output, true)
	print(output)
	check(code == 0, "physics worker exits normally")
	if not FileAccess.file_exists(folder.path_join("result.json")):
		return {}
	var result: Variant = JSON.parse_string(FileAccess.get_file_as_string(folder.path_join("result.json")))
	check(Controller.valid_report(result, hash), "physics report schema and evidence valid")
	if result is Dictionary:
		print("TRAVERSAL BENCHMARK ", JSON.stringify(result.metrics))
		return result
	return {}

func _cancel_live(root: Node2D, region: RegionDefinition) -> void:
	var job := _prepare_job(root, region)
	var folder: String = job.folder
	var pid := OS.create_process("python", PackedStringArray([ProjectSettings.globalize_path("res://tools/analyze_traversal.py"),
		"--godot", OS.get_executable_path(), "--request", ProjectSettings.globalize_path(folder.path_join("request.json"))]), false)
	var deadline := Time.get_ticks_msec() + 5000
	var live := false
	while pid > 0 and OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		var log := folder.path_join("godot.log")
		if FileAccess.file_exists(log) and FileAccess.get_file_as_string(log).contains("TRAVERSAL INPUT EVIDENCE"):
			live = true
			break
		await get_tree().create_timer(0.02).timeout
	check(live, "cancellation fixture observed a live Actor performing physics inputs")
	var cancel := FileAccess.open(folder.path_join("cancel"), FileAccess.WRITE)
	cancel.close()
	deadline = Time.get_ticks_msec() + 7000
	while pid > 0 and OS.is_process_running(pid) and Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.02).timeout
	var status: Variant = Controller._read_json(folder.path_join("status.json"), 65536)
	check(not OS.is_process_running(pid) and status is Dictionary and status.get("state") == "cancelled" and status.get("return_code") == 0 and status.get("termination") == "none" and status.get("engine_error", true) == false, "live verifier cooperatively cleans its world and exits normally without forced termination or engine errors")
	check(not FileAccess.file_exists(folder.path_join("result.json")), "cancelled live verification does not publish partially verified results")
	print("TRAVERSAL LIVE CANCEL ", status)

func _platform(root: Node2D, name: String, at: Vector2, size: Vector2, one_way := false) -> FieldPlatform:
	var platform := (load("res://world/adventure/field_platform.tscn") as PackedScene).instantiate() as FieldPlatform
	platform.name = name
	platform.position = at
	platform.size = size
	platform.one_way = one_way
	root.get_node("Terrain").add_child(platform)
	platform.owner = root
	return platform

func _fixtures(region: RegionDefinition) -> void:
	var root := (load("res://addons/rtc_field_editor/region_scaffold.tscn") as PackedScene).instantiate() as Node2D
	var floor := _platform(root, "Floor", Vector2(150, 400), Vector2(300, 30))
	_platform(root, "Right", Vector2(420, 380), Vector2(240, 20))
	_platform(root, "Upper", Vector2(150, 240), Vector2(150, 20), true)
	for index in NetworkManager.MAX_PLAYERS:
		var slot := PlayerSpawnPoint.new()
		slot.name = "PlayerSpawnPoint%d" % index
		slot.spawn_index = index
		slot.position = Vector2(80 + 48 * index, 368)
		root.add_child(slot)
		slot.owner = root
	var entry := RegionPoint.new()
	entry.name = "Entry"
	entry.point_id = region.entry_point_ids[0]
	entry.position = Vector2(80, 368)
	root.add_child(entry)
	entry.owner = root
	for index in region.escape_point_ids.size():
		var escape := RegionPoint.new()
		escape.name = "Escape%d" % index
		escape.point_id = region.escape_point_ids[index]
		escape.kind = RegionPoint.Kind.ESCAPE
		escape.position = Vector2(150, 212) if index == 0 else Vector2(420, 353)
		escape.requires_landing = true
		root.add_child(escape)
		escape.owner = root
	var climb := ClimbableArea2D.new()
	climb.name = "Ladder"
	climb.position = Vector2(150, 310)
	climb.definition = (load("res://data/content/climbing/ladder.tres") as ClimbableDefinition).duplicate()
	climb.definition.requires_interaction = true
	climb.collision_layer = 0
	climb.collision_mask = 1
	root.get_node("Climbables").add_child(climb)
	climb.owner = root
	for spec in [["Top", Vector2(0, -98)], ["Bottom", Vector2(0, 58)]]:
		var marker := Marker2D.new()
		marker.name = spec[0]
		marker.position = spec[1]
		climb.add_child(marker)
		marker.owner = root
		if spec[0] == "Top":
			climb.top_marker = marker
		else:
			climb.bottom_marker = marker
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	var shape := RectangleShape2D.new()
	shape.size = Vector2(56, 210)
	collision.shape = shape
	climb.add_child(collision)
	collision.owner = root
	_platform(root, "UpperRight", Vector2(420, 220), Vector2(150, 20), true)
	var rope := climb.duplicate() as ClimbableArea2D
	rope.name = "Rope"
	rope.position = Vector2(520, 274)
	rope.definition = load("res://data/content/climbing/rope.tres")
	rope.top_marker = rope.get_node("Top")
	rope.bottom_marker = rope.get_node("Bottom")
	rope.top_marker.position.y = -81
	rope.bottom_marker.position.y = 79
	root.get_node("Climbables").add_child(rope)
	rope.owner = root
	for child in rope.get_children():
		child.owner = root
	var result := _verify(root, region)
	if not result.is_empty():
		check(result.model.input_checks.jump and result.model.input_checks.air_reverse and result.model.input_checks.landing, "actual jump, airborne reversal and real floor landing")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "JUMP" and edge.status == "Verified" and edge.from != edge.to), "fixture horizontal/upward jump lands on actual target collider")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "CLIMB_UP" and edge.status == "Verified" and edge.interaction_requested), "requires-interaction uses real E and W input")
		check(result.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "CLIMB_DOWN" and edge.climb.ends_with("Rope") and edge.status == "Verified"), "rope descent traverses actual area to a lower floor")
		check(result.routes.size() == 16, "all fixture slots and escapes explicitly reported")
		check(result.routes.all(func(route: Dictionary) -> bool: return route.status == "Verified Reachable"), "continuous multi-edge fixture replay reaches both goals for every slot")
	var gather := FieldGatherPoint.new()
	gather.name = "GripBlocker"
	gather.interaction_id = &"traversal_grip_blocker"
	gather.item_id = &"rusty_scrap"
	gather.amount = 1
	gather.position = Vector2(150, 368)
	root.get_node("GatherPoints").add_child(gather)
	gather.owner = root
	var blocked := _verify(root, region)
	if not blocked.is_empty():
		var climbs: Array = blocked.edges.filter(func(edge: Dictionary) -> bool: return edge.kind == "CLIMB_UP" and edge.climb.ends_with("Ladder"))
		check(not climbs.is_empty() and climbs.all(func(edge: Dictionary) -> bool: return edge.status == "Not Evaluated" and edge.reason.contains("takes E")), "authored gather priority prevents a fake E-grip proof")
		check(not blocked.routes.any(func(route: Dictionary) -> bool: return route.escape == String(region.escape_point_ids[0]) and route.status == "Verified Reachable"), "unverified interaction prerequisite cannot produce verified escape reachability")
	gather.free()
	# A StaticBody can own multiple independent standing shapes. Landing on its
	# upper shelf must never satisfy a target on its lower floor by body ID alone.
	var upper_platform := root.get_node("Terrain/Upper") as Node2D
	upper_platform.position.x += 1000
	var shelf := CollisionShape2D.new()
	shelf.name = "SeparateShelf"
	var shelf_shape := RectangleShape2D.new()
	shelf_shape.size = Vector2(110, 16)
	shelf.shape = shelf_shape
	shelf.position = Vector2(0, -100)
	floor.add_child(shelf)
	shelf.owner = root
	var multishape := _verify(root, region)
	if not multishape.is_empty():
		var bottom_id := -1
		var shelf_id := -1
		for surface in multishape.surfaces:
			if surface.path == "Terrain/Floor/CollisionShape2D":
				bottom_id = int(surface.id)
			elif surface.path == "Terrain/Floor/SeparateShelf":
				shelf_id = int(surface.id)
		check(bottom_id >= 0 and shelf_id >= 0, "multiple standing shapes on one body extracted independently")
		var jumps: Array = multishape.edges.filter(func(edge: Dictionary) -> bool: return edge.kind == "JUMP" and int(edge.from) == shelf_id and int(edge.to) == bottom_id)
		check(not jumps.is_empty() and jumps.all(func(edge: Dictionary) -> bool: return edge.status != "Verified"), "landing back on upper shape cannot verify lower target on the same body")
		check(multishape.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "DROP" and int(edge.from) == shelf_id and int(edge.to) == bottom_id and edge.status == "Verified"), "walking off shelf verifies a real drop to the lower shape")
	shelf.free()
	upper_platform.position.x -= 1000
	var competitor := climb.duplicate() as ClimbableArea2D
	competitor.name = "CompetingLadder"
	competitor.position.x = 149
	competitor.definition = climb.definition.duplicate()
	competitor.definition.requires_interaction = false
	competitor.definition.alignment_tolerance = 100
	competitor.top_marker = competitor.get_node("Top")
	competitor.bottom_marker = competitor.get_node("Bottom")
	root.get_node("Climbables").add_child(competitor)
	competitor.owner = root
	for child in competitor.get_children():
		child.owner = root
	var overlapping := _verify(root, region)
	if not overlapping.is_empty():
		check(overlapping.edges.filter(func(edge: Dictionary) -> bool: return edge.kind.begins_with("CLIMB") and edge.status == "Verified").all(func(edge: Dictionary) -> bool: return edge.climb_path == edge.climb), "every overlapping climb proof identifies the area actually used by MovementComponent")
		check(overlapping.edges.any(func(edge: Dictionary) -> bool: return edge.kind == "CLIMB_UP" and edge.climb.ends_with("/CompetingLadder") and edge.status == "Verified"), "actual overlapping area remains independently verifiable")
	competitor.free()
	var unknown := Node2D.new()
	unknown.name = "UnmodelledBehaviour"
	unknown.set_script(load("res://tests/editor/traversal_unmodelled.gd"))
	root.add_child(unknown)
	unknown.owner = root
	var unsupported := _verify(root, region)
	if not unsupported.is_empty():
		check(unsupported.partial and unsupported.edges.all(func(edge: Dictionary) -> bool: return edge.status != "Verified"), "unmodelled script cannot be stripped and then receive verified edges")
		check(unsupported.routes.all(func(route: Dictionary) -> bool: return route.status == "Not Evaluated"), "unmodelled controller cannot produce verified reachability")
	unknown.free()
	var before := Analysis.fingerprint(root, region)
	floor.position.x += 32
	check(before != Analysis.fingerprint(root, region), "geometry edit invalidates fingerprint")
	floor.position.x -= 32
	var slot := root.get_node("PlayerSpawnPoint1") as PlayerSpawnPoint
	slot.spawn_index = 0
	var invalid := Analysis.extract(root, region)
	check(invalid.starts.any(func(start: Dictionary) -> bool: return not start.get("invalid_reason", "").is_empty()), "duplicate slot is invalid independent of geometric proximity")
	slot.spawn_index = 1
	climb.bottom_marker = null
	check(Analysis.extract(root, region).issues.any(func(issue: Dictionary) -> bool: return issue.reason.contains("Missing climb")), "missing climb marker not silently connected")
	climb.bottom_marker = climb.get_node("Bottom")
	var polygon := CollisionPolygon2D.new()
	polygon.polygon = PackedVector2Array([Vector2.ZERO, Vector2(50, 0), Vector2(0, 50)])
	floor.add_child(polygon)
	check(Analysis.extract(root, region).issues.any(func(issue: Dictionary) -> bool: return issue.reason.contains("Polygon/tile")), "unsupported polygon remains not evaluated")
	polygon.free()
	for index in Analysis.SURFACE_LIMIT + 1:
		_platform(root, "Limit%d" % index, Vector2(index * 100, 1500), Vector2(64, 20))
	var limited := Analysis.extract(root, region)
	check(limited.partial and limited.surfaces.size() == Analysis.SURFACE_LIMIT and limited.edges.size() <= Analysis.EDGE_LIMIT, "large scene reports partial analysis and bounded candidates")
	root.free()
