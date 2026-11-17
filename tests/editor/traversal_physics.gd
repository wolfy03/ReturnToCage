extends Node

const Analysis := preload("res://addons/rtc_field_editor/traversal_analysis.gd")
const ACTOR := preload("res://gameplay/actors/player/player.tscn")
const WALL_BUDGET_MS := 20000
const TRIAL_LIMIT := 768
# Explicit static-profile adapters. Unmodelled behaviour must not silently
# disappear while its remaining geometry receives a verified result.
const PROFILE_SCRIPTS := [
	"res://world/adventure/adventure_region.gd", "res://world/adventure/field_platform.gd",
	"res://world/adventure/field_decoration.gd", "res://world/adventure/field_enemy_spawn_point.gd",
	"res://world/adventure/field_gather_point.gd", "res://world/region_point.gd",
	"res://world/multiplayer/player_spawn_point.gd", "res://world/multiplayer/player_spawn_manager.gd",
	"res://world/multiplayer/enemy_spawn_manager.gd", "res://world/multiplayer/loot_spawn_manager.gd",
	"res://world/multiplayer/network_entity_registry.gd", "res://gameplay/components/climbable_area_2d.gd",
	"res://gameplay/components/interaction_target.gd", "res://world/adventure/escape_point_2d.gd",
]

var automatically_run := true
var exit_when_finished := true
var report: Dictionary
var world: Node2D
var actor: PlayerActor
var targets: Array[EscapePoint2D] = []
var interactions: Array[InteractionTarget] = []
var started: int
var ticks := 0
var attempts := 0
var budget_hit := false
var root_scene: Node2D
var spawn_support: float
var spawn_radius: float
var spawn_mask: int
var _request_folder := ""

func _ready() -> void:
	if automatically_run:
		call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not args[0].begins_with("res://.godot/rtc_traversal/") or args[0] != args[0].simplify_path():
		get_tree().quit(1)
		return
	await verify_snapshot(args[0])

func verify_snapshot(request_path: String) -> void:
	var request: Variant = JSON.parse_string(FileAccess.get_file_as_string(request_path))
	if not request is Dictionary or not request.get("scene") is String or not request.get("output") is String or not request.get("token") is String:
		get_tree().quit(1)
		return
	var folder := request_path.get_base_dir()
	_request_folder = folder
	if request.scene != folder.path_join("scene.tscn") or request.output != folder.path_join("result.json"):
		get_tree().quit(1)
		return
	if FileAccess.file_exists(folder.path_join("cancel")):
		print("TRAVERSAL PHYSICS CANCELLED before world initialization")
		get_tree().quit()
		return
	var definition := ContentRegistry.get_definition(StringName(request.region)) as RegionDefinition
	var packed := ResourceLoader.load(request.scene, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	if packed == null or definition == null:
		get_tree().quit(1)
		return
	root_scene = packed.instantiate() as Node2D
	var spawn_manager := root_scene.get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	if spawn_manager == null or definition.entry_point_ids.is_empty():
		get_tree().quit(1)
		return
	spawn_support = spawn_manager.support_distance
	spawn_radius = spawn_manager.clearance_radius
	spawn_mask = spawn_manager.spawn_validation_collision_mask
	report = Analysis.extract(root_scene, definition)
	if report.fingerprint != request.fingerprint:
		print("TRAVERSAL snapshot fingerprint mismatch ", report.fingerprint, " expected ", request.fingerprint)
		root_scene.free()
		get_tree().quit(1)
		return
	report.token = request.token
	for authored_node in [root_scene] + root_scene.find_children("*", "", true, false):
		var behaviour := authored_node.get_script() as Script
		if behaviour != null and not behaviour.resource_path in PROFILE_SCRIPTS:
			report.issues.append({"path": String(root_scene.get_path_to(authored_node)), "status": "Not Evaluated", "reason": "Unmodelled behaviour script: " + behaviour.resource_path})
			budget_hit = true
	started = Time.get_ticks_msec()
	GameSession.start_new_game()
	GameSession.set_process(false)
	root_scene.configure(AdventureContext.new(definition.id, &"", definition.entry_point_ids[0], GameSession.difficulty.id, GameSession.session_id))
	root_scene._create_escape_points()
	var gather_ids: Dictionary = {}
	for marker in root_scene.find_children("*", "Marker2D", true, false):
		if marker is FieldGatherPoint and marker.enabled:
			if ContentRegistry.get_item(marker.item_id) == null or marker.amount <= 0 or marker.interaction_id.is_empty() or gather_ids.has(marker.interaction_id):
				report.issues.append({"path": String(root_scene.get_path_to(marker)), "status": "Not Evaluated", "reason": "Invalid gather interaction prerequisite"})
				budget_hit = true
			else:
				gather_ids[marker.interaction_id] = true
				root_scene._create_gather(marker)
	for child in root_scene.get_children():
		if child is InteractionTarget:
			# Keep the real targeting/priority/shape rules, but never execute loot
			# or travel commands. Release closures while their source script is
			# still attached, before stripping the region's gameplay lifecycle.
			for connection in child.activated.get_connections():
				child.activated.disconnect(connection.callable)
			interactions.append(child)
		if child is EscapePoint2D:
			targets.append(child)
	root_scene.set_script(null)
	_sanitize(root_scene)
	world = Node2D.new()
	add_child(world)
	world.add_child(root_scene)
	for target in targets:
		target.set_process(false)
	actor = ACTOR.instantiate()
	actor.setup_player(GameSession.get_local_peer_id(), true, false)
	world.add_child(actor)
	actor.input.configure_input(true, true)
	actor.survival.set_process(false)
	actor.effects.set_process(false)
	report.model.speed = actor.movement.speed
	report.limits.wall_ms = WALL_BUDGET_MS
	report.limits.trials = TRIAL_LIMIT
	if not root_scene.transform.x.is_equal_approx(Vector2.RIGHT) or not root_scene.transform.y.is_equal_approx(Vector2.DOWN):
		report.issues.append({"path": ".", "status": "Not Evaluated", "reason": "Transformed region root is not supported by this fresh-player verifier"})
		budget_hit = true
	for surface in report.surfaces:
		surface.left += float(report.model.body[0]) * 0.25
		surface.right -= float(report.model.body[0]) * 0.25
		if _limited():
			break
		var left := Vector2(surface.left, surface.y)
		var right := Vector2(surface.right, surface.y)
		var settled := await _reset(left, int(surface.id))
		var trace: Array = []
		var inputs: Array = []
		var walked := settled and await _walk(right.x, int(surface.id), trace, inputs)
		var returned := walked and await _walk(left.x, int(surface.id), trace, inputs)
		surface.status = "Verified" if returned else "Not Evaluated"
		surface.trace = trace
		surface.inputs = inputs
	await _movement_evidence()
	for edge in report.edges:
		if _limited():
			break
		var source: Dictionary = report.surfaces[int(edge.from)]
		var target: Dictionary = report.surfaces[int(edge.to)]
		if source.status != "Verified" or target.status != "Verified":
			edge.reason = "Source or destination lacks a continuous verified standing interval"
			edge.status = "Not Evaluated"
			continue
		if edge.kind == "WALK":
			edge.status = "Verified"
			edge.trace = source.trace
			edge.inputs = source.inputs
			edge.reason = "Actual input walked the full interval in both directions"
			continue
		var success := false
		var evaluated := true
		for fraction in [0.05, 0.5, 0.95]:
			if _limited():
				break
			var start := Vector2(lerpf(source.left, source.right, fraction), source.y)
			if not await _reset(start, int(source.id)):
				continue
			edge.start = Analysis.point(actor.global_position)
			var evidence := await _execute(edge)
			if not evidence.get("evaluated", true):
				evaluated = false
				edge.prerequisite = evidence.reason
			edge.trace = evidence.trace
			edge.inputs = evidence.inputs
			edge.jump_tick = evidence.jump_tick
			edge.interaction_requested = evidence.interaction_requested
			edge.interaction_tick = evidence.interaction_tick
			edge.contacts = evidence.contacts
			edge.climb_path = evidence.get("climb_path", "")
			if evidence.success:
				edge.erase("prerequisite")
				edge.reason = "Actual PlayerActor input reached the target collider and held a stable floor after release"
				edge.status = "Verified"
				success = true
				break
		if not success:
			edge.status = "Not Evaluated" if _limited() or not evaluated else "Unreachable Within Tested Inputs"
			edge.reason = edge.get("prerequisite", "Bounded three-start feedback/input strategies did not produce a stable target landing. Contacts: %s" % [edge.get("contacts", [])])
	for start in report.starts:
		if _limited():
			break
		await _routes(start)
	# Budget exhaustion never omits a slot silently or converts it to unreachable.
	for start in report.starts:
		for escape in report.escapes:
			if not report.routes.any(func(route: Dictionary) -> bool: return route.start == start and route.escape == escape.id):
				report.routes.append({"start": start, "escape": escape.id, "path": escape.path, "status": "Not Evaluated", "edges": [], "trace": []})
	var approached: Array[int] = []
	for route in report.routes:
		for id in Analysis.reachable(report, int(route.get("source_surface", -1))):
			if not id in approached:
				approached.append(id)
	for surface in report.surfaces:
		surface.access = "Candidate Reachable" if int(surface.id) in approached else "Not Evaluated"
		if surface.access == "Not Evaluated":
			report.issues.append({"path": surface.body_path, "status": "Not Evaluated", "reason": "No verified graph approach from the tested assignments; other inputs remain untested"})
	for edge in report.edges:
		if edge.kind == "DROP" and edge.status == "Verified" and not int(edge.from) in Analysis.reachable(report, int(edge.to)):
			report.issues.append({"path": report.surfaces[int(edge.to)].body_path, "status": "Warning", "reason": "Verified drop has no verified return in the bounded graph. This does not prove every return input impossible."})
	if _limited():
		report.partial = true
	report.status = "Physics Verified (bounded)" if not report.partial else "Partial Physics Verification"
	report.metrics = {"wall_ms": Time.get_ticks_msec() - started, "physics_ticks": ticks, "attempts": attempts,
		"surfaces": report.surfaces.size(), "edges": report.edges.size(),
		"verified_edges": report.edges.filter(func(edge: Dictionary) -> bool: return edge.status == "Verified").size()}
	_release()
	actor.movement.exit_climb()
	actor.queue_free()
	await get_tree().process_frame
	actor = null
	interactions.clear()
	targets.clear()
	world.queue_free()
	await get_tree().physics_frame
	await get_tree().process_frame
	world = null
	root_scene = null
	if FileAccess.file_exists(_request_folder.path_join("cancel")):
		print("TRAVERSAL PHYSICS CANCELLED after world cleanup")
		get_tree().quit()
		return
	var file := FileAccess.open(request.output + ".tmp", FileAccess.WRITE)
	if file == null:
		push_error("Cannot write traversal result: " + request.output)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(report))
	file.close()
	if DirAccess.rename_absolute(request.output + ".tmp", request.output) != OK:
		get_tree().quit(1)
		return
	print("TRAVERSAL PHYSICS PASS ", JSON.stringify(report.metrics))
	if exit_when_finished:
		get_tree().quit()

func _sanitize(node: Node) -> void:
	for child in node.get_children():
		if child is FieldDecoration or child is FieldEnemySpawnPoint or child is FieldGatherPoint:
			child.free()
		elif child is StaticBody2D:
			if child.get_script() != null and not child is FieldPlatform:
				report.issues.append({"path": String(root_scene.get_path_to(child)), "status": "Not Evaluated", "reason": "Custom body script changes physics"})
				budget_hit = true
				child.set_script(null)
		elif child is PhysicsBody2D:
			report.issues.append({"path": String(root_scene.get_path_to(child)), "status": "Not Evaluated", "reason": "Dynamic body physics is outside static traversal profile"})
			budget_hit = true
			child.free()
		elif child is ClimbableArea2D or child is InteractionTarget or child is RegionPoint or child is PlayerSpawnPoint:
			continue
		elif child is Node2D and child.get_script() == null:
			_sanitize(child)
		else:
			child.free()

func _limited() -> bool:
	budget_hit = budget_hit or attempts >= TRIAL_LIMIT or Time.get_ticks_msec() - started >= WALL_BUDGET_MS or FileAccess.file_exists(_request_folder.path_join("cancel"))
	return budget_hit

func _release() -> void:
	for action in ["move_left", "move_right", "move_up", "move_down"]:
		Input.action_release(action)

func _axis(horizontal: float, vertical := 0.0) -> void:
	_release()
	if absf(horizontal) > 0.1:
		Input.action_press("move_right" if horizontal > 0 else "move_left")
	if absf(vertical) > 0.1:
		Input.action_press("move_down" if vertical > 0 else "move_up")

func _event(action: StringName) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	Input.parse_input_event(event)
	event = InputEventAction.new()
	event.action = action
	Input.parse_input_event(event)

func _tick(trace: Array, inputs: Array = [], horizontal := 0.0, vertical := 0.0) -> void:
	await get_tree().physics_frame
	ticks += 1
	trace.append(Analysis.point(actor.global_position))
	inputs.append([horizontal, vertical])

func _standing(surface: int) -> bool:
	if not actor.is_on_floor() or absf(actor.global_position.y - float(report.surfaces[surface].y)) > actor.floor_snap_length + actor.safe_margin * 4.0:
		return false
	for index in actor.get_slide_collision_count():
		var collision := actor.get_slide_collision(index)
		var collider := collision.get_collider() as Node
		if collision.get_normal().dot(actor.up_direction) >= cos(actor.floor_max_angle) and collider != null:
			var collider_shape := collision.get_collider_shape() as Node
			if collider_shape != null and root_scene.is_ancestor_of(collider_shape) and String(root_scene.get_path_to(collider_shape)) == report.surfaces[surface].path and String(root_scene.get_path_to(collider)) == report.surfaces[surface].body_path:
				var at := actor.global_position
				return at.x >= report.surfaces[surface].left - actor.safe_margin and at.x <= report.surfaces[surface].right + actor.safe_margin
	# Floor snapping can set is_on_floor without adding a slide collision. Resolve
	# its actual supporting body through the same physics space, never by proximity.
	var foot := actor.global_position + Vector2.DOWN * (float(report.model.body[1]) * 0.5 + actor.floor_snap_length + actor.safe_margin * 4.0)
	var query := PhysicsRayQueryParameters2D.create(actor.global_position, foot, actor.collision_mask, [actor.get_rid()])
	var hit := actor.get_world_2d().direct_space_state.intersect_ray(query)
	if not hit.is_empty() and hit.collider is CollisionObject2D and hit.normal.dot(actor.up_direction) >= cos(actor.floor_max_angle):
		var collision_body := hit.collider as CollisionObject2D
		var support_shape := collision_body.shape_owner_get_owner(collision_body.shape_find_owner(hit.shape)) as Node
		return support_shape != null and root_scene.is_ancestor_of(support_shape) and String(root_scene.get_path_to(support_shape)) == report.surfaces[surface].path and String(root_scene.get_path_to(collision_body)) == report.surfaces[surface].body_path and actor.global_position.x >= report.surfaces[surface].left and actor.global_position.x <= report.surfaces[surface].right
	return false

func _surface_at() -> int:
	for surface in report.surfaces:
		if _standing(int(surface.id)):
			return int(surface.id)
	return -1

func _reset(position: Vector2, surface := -1) -> bool:
	attempts += 1
	_release()
	await get_tree().process_frame
	actor.movement.exit_climb()
	actor.movement._needs_release = false
	actor.movement._interaction_granted = false
	actor.global_position = position
	actor.velocity = Vector2.ZERO
	var trace: Array = []
	var settle_ticks := ceili(sqrt(2.0 * spawn_support / actor.movement.gravity) * float(report.model.physics_fps)) + 6
	for step in settle_ticks:
		await _tick(trace)
		if step > 2 and actor.is_on_floor():
			return _standing(surface) if surface >= 0 else true
	return false

func _walk(x: float, surface: int, trace: Array, inputs: Array = []) -> bool:
	var tolerance: float = float(report.model.body[0]) * 0.15
	var distance := absf(actor.global_position.x - x)
	var seconds: float = distance / maxf(actor.movement.speed, 1.0) + 1.0
	var limit := ceili(seconds * float(report.model.physics_fps))
	for step in limit:
		if _limited():
			return false
		var remaining := x - actor.global_position.x
		var braking := actor.velocity.x * actor.velocity.x / (2.0 * actor.movement.deceleration)
		var axis := signf(remaining) if absf(remaining) > maxf(tolerance, braking + absf(actor.velocity.x) * 2.0 / float(report.model.physics_fps)) else 0.0
		_axis(axis)
		await _tick(trace, inputs, axis)
		if not actor.is_on_floor() or not _standing(surface):
			return false
		if absf(remaining) <= tolerance and absf(actor.velocity.x) < 1.0:
			_release()
			return true
	return false

func _execute(edge: Dictionary) -> Dictionary:
	var trace: Array = []
	var inputs: Array = []
	var target: Dictionary = report.surfaces[int(edge.to)]
	var goal: float = (target.left + target.right) * 0.5
	var duration: float = (absf(actor.movement.jump_velocity) / actor.movement.gravity * 2.0
		+ sqrt(2.0 * absf(target.y - actor.global_position.y) / actor.movement.gravity)
		+ absf(goal - actor.global_position.x) / maxf(actor.movement.speed, 1.0) + 1.0)
	var limit := ceili(duration * float(report.model.physics_fps))
	if edge.kind == "JUMP":
		_event(&"jump")
	var climb := root_scene.get_node_or_null(NodePath(edge.climb)) as ClimbableArea2D if not edge.climb.is_empty() else null
	if climb != null:
		duration = absf(actor.global_position.x - climb.global_position.x) / maxf(actor.movement.speed, 1.0) + absf(climb.top().y - climb.bottom().y) / maxf(actor.movement.speed * climb.definition.speed_multiplier, 1.0) + 2.0
		limit = ceili(duration * float(report.model.physics_fps))
	var was_air := false
	var was_climb := false
	var entered_climb_path := ""
	var interacted := false
	var interaction_tick := -1
	var contacts: Array = []
	for step in limit:
		if _limited():
			break
		var horizontal := signf(goal - actor.global_position.x)
		var braking := actor.velocity.x * actor.velocity.x / (2.0 * actor.movement.deceleration)
		if absf(goal - actor.global_position.x) <= maxf(float(report.model.body[0]) * 0.15, braking):
			horizontal = 0.0
		var vertical := 0.0
		if climb != null and not (was_climb and actor.movement.mode != MovementComponent.Mode.CLIMB):
			goal = climb.global_position.x
			vertical = -1.0 if edge.kind == "CLIMB_UP" else 1.0
			if climb.definition.requires_interaction and not interacted and actor.movement.mode != MovementComponent.Mode.CLIMB and actor.movement.climb_candidate() == climb:
				if interactions.any(func(target_area: InteractionTarget) -> bool: return target_area.can_interact(actor) and target_area.is_in_range(actor)) or actor.interaction.current_target != null and actor.interaction.current_target.can_interact(actor):
					return {"success": false, "trace": trace, "inputs": inputs, "jump_tick": -1, "interaction_requested": false, "interaction_tick": -1, "contacts": contacts, "evaluated": false, "reason": "Another authored interaction takes E; consuming/removing that target is not simulated"}
				_event(&"interact")
				interacted = true
				interaction_tick = step
			if actor.movement.mode == MovementComponent.Mode.CLIMB:
				if is_instance_valid(actor.movement.climb_area):
					entered_climb_path = String(root_scene.get_path_to(actor.movement.climb_area))
				if actor.movement.climb_area != climb:
					_release()
					return {"success": false, "trace": trace, "inputs": inputs, "jump_tick": -1, "interaction_requested": interacted, "interaction_tick": interaction_tick, "contacts": contacts, "evaluated": false, "reason": "Runtime selected a different overlapping climb area"}
				horizontal = 0
				was_climb = true
		elif climb != null:
			goal = (target.left + target.right) * 0.5
		if edge.kind == "DROP" and not was_air:
			var source: Dictionary = report.surfaces[int(edge.from)]
			horizontal = -1.0 if goal < (source.left + source.right) * 0.5 else 1.0
		_axis(horizontal, vertical)
		await _tick(trace, inputs, horizontal, vertical)
		for collision_index in actor.get_slide_collision_count():
			var collision := actor.get_slide_collision(collision_index)
			var body := collision.get_collider() as Node
			if body != null and root_scene.is_ancestor_of(body) and collision.get_normal().dot(actor.up_direction) < cos(actor.floor_max_angle):
				var path := String(root_scene.get_path_to(body))
				if not contacts.has(path):
					contacts.append(path)
		was_air = was_air or not actor.is_on_floor()
		if _standing(int(edge.to)) and (was_air or was_climb) and (climb == null or was_climb and actor.movement.mode != MovementComponent.Mode.CLIMB):
			_release()
			var hold: Array = []
			for frame in 10:
				await _tick(hold, inputs)
			trace.append_array(hold)
			return {"success": _standing(int(edge.to)) and absf(actor.velocity.x) < 1.0, "trace": trace, "inputs": inputs, "jump_tick": 0 if edge.kind == "JUMP" else -1, "interaction_requested": interacted, "interaction_tick": interaction_tick, "contacts": contacts, "climb_path": entered_climb_path}
		if actor.global_position.y > maxf(target.y, report.surfaces[int(edge.from)].y) + actor.movement.speed * duration:
			break
	_release()
	return {"success": false, "trace": trace, "inputs": inputs, "jump_tick": 0 if edge.kind == "JUMP" else -1, "interaction_requested": interacted, "interaction_tick": interaction_tick, "contacts": contacts, "climb_path": entered_climb_path}

func _movement_evidence() -> void:
	var wide: Array = report.surfaces.filter(func(surface: Dictionary) -> bool: return surface.status == "Verified")
	wide.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.right - a.left > b.right - b.left)
	var evidence := {"jump": false, "air_reverse": false, "landing": false}
	if wide.is_empty() or _limited():
		report.model.input_checks = evidence
		return
	var surface: Dictionary = wide[0]
	if await _reset(Vector2((surface.left + surface.right) * 0.5, surface.y), int(surface.id)):
		var trace: Array = []
		_event(&"jump")
		_axis(-1)
		var moved_left := false
		for frame in 14:
			await _tick(trace)
			evidence.jump = evidence.jump or actor.velocity.y < 0 and not actor.is_on_floor()
			moved_left = moved_left or actor.velocity.x < 0 and not actor.is_on_floor()
		_axis(1)
		for frame in 14:
			await _tick(trace)
			evidence.air_reverse = evidence.air_reverse or moved_left and actor.velocity.x > 0 and not actor.is_on_floor()
		_release()
		for frame in int(report.model.physics_fps) * 2:
			await _tick(trace)
			if _standing(int(surface.id)):
				evidence.landing = true
				break
		evidence.trace = trace
	report.model.input_checks = evidence
	print("TRAVERSAL INPUT EVIDENCE jump=", evidence.jump, " air_reverse=", evidence.air_reverse, " landing=", evidence.landing)

func _routes(start: Dictionary) -> void:
	var positions: Array[Vector2] = [root_scene.to_local(Analysis.vector(start.position))]
	var assignment := PlayerSpawnPolicy.decide(GameSession.session_id, GameSession.get_local_player_id(), false, Vector2.INF, positions, positions,
		func(position: Vector2) -> String:
			return PlayerSpawnManager.analyze_authored_spawn(root_scene, position, spawn_radius, spawn_support, spawn_mask, [actor.get_rid()]).issue)
	for escape in report.escapes:
		var route := {"start": start, "escape": escape.id, "path": escape.path, "status": "Invalid Spawn", "edges": [], "trace": []}
		if not escape.valid:
			route.status = "Invalid Destination"
			report.routes.append(route)
			continue
		if assignment.error_message.is_empty() and start.get("invalid_reason", "").is_empty() and await _reset(root_scene.to_global(assignment.position)):
			var source := _surface_at()
			route.source_surface = source
			route.assignment_position = Analysis.point(actor.global_position)
			var search := _find_path(source, escape.id)
			route.status = "Not Evaluated"
			if source >= 0 and search.found:
				var continuous: Array = []
				var input_trace: Array = []
				var events: Array = []
				var replayed := true
				for index in search.edges:
					var edge: Dictionary = report.edges[index]
					if not await _walk(Analysis.vector(edge.start).x, int(edge.from), continuous, input_trace):
						replayed = false
						break
					var frame_offset := continuous.size()
					var evidence := await _execute(edge)
					input_trace.append_array(evidence.inputs)
					events.append({"frame": frame_offset, "jump": evidence.jump_tick, "interaction": evidence.interaction_tick})
					continuous.append_array(evidence.trace)
					if not evidence.success:
						replayed = false
						break
				var target := _escape_target(escape.id)
				if replayed and target != null:
					var finish_surface := _surface_at()
					if finish_surface < 0:
						replayed = false
						finish_surface = int(source)
					var target_x := clampf(target.global_position.x, report.surfaces[finish_surface].left, report.surfaces[finish_surface].right)
					replayed = replayed and await _walk(target_x, finish_surface, continuous, input_trace)
					replayed = replayed and target.can_interact(actor) and target.is_in_range(actor)
				route.status = "Verified Reachable" if replayed else "Candidate Reachable"
				route.edges = search.edges
				route.trace = continuous
				route.inputs = input_trace
				route.events = events
		report.routes.append(route)

func _escape_target(id: String) -> EscapePoint2D:
	for target in targets:
		if String(target.interaction_id) == id:
			return target
	return null

func _find_path(source: int, escape: String) -> Dictionary:
	if source < 0:
		return {"found": false, "edges": []}
	var target := _escape_target(escape)
	if target == null:
		return {"found": false, "edges": []}
	var queue: Array[int] = [source]
	var parent := {source: -1}
	while not queue.is_empty():
		var at: int = queue.pop_front()
		var surface: Dictionary = report.surfaces[at]
		var x := clampf(target.global_position.x, surface.left, surface.right)
		var point := Vector2(x, surface.y)
		var capsule := actor.get_node("Interaction/CollisionShape2D") as CollisionShape2D
		var target_collision := target.get_child(0) as CollisionShape2D
		if capsule.shape.collide(Transform2D(0, point), target_collision.shape, target_collision.global_transform):
			var path: Array[int] = []
			while parent[at] != -1:
				var edge_id: int = parent[at]
				path.push_front(edge_id)
				at = int(report.edges[edge_id].from)
			return {"found": true, "edges": path}
		for index in report.edges.size():
			var edge: Dictionary = report.edges[index]
			if int(edge.from) == at and edge.status == "Verified" and int(edge.to) != at and not parent.has(int(edge.to)):
				parent[int(edge.to)] = index
				queue.append(int(edge.to))
	return {"found": false, "edges": []}
