extends Node

var _playtest_results: Array[Dictionary] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() == 2 and args[0] == "--region":
		_finish(await _playtest_region(StringName(args[1])))
		return
	GameSession.start_new_game()
	var context := GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	var packed := load("res://tests/field_editor_probe_scene.tscn") as PackedScene
	if context == null or packed == null:
		_finish(false)
		return
	var presentation := packed.instantiate()
	presentation.configure(context)
	add_child(presentation)
	var valid: bool = presentation.get_node("EnemySpawnManager")._enemies.size() == 2
	valid = valid and presentation._gather_targets.has(&"rusty_scrap_gather_1")
	var decorations := presentation.get_node("Decorations")
	valid = valid and decorations.get_child_count() >= 6
	for decoration in decorations.get_children():
		valid = valid and decoration.get_child_count(true) == 1
	presentation.queue_free()
	await get_tree().process_frame

	var authority := packed.instantiate()
	authority.configure_server_runtime(&"adventure:sewer_region", &"sewer_region")
	add_child(authority)
	valid = valid and authority.get_node("EnemySpawnManager")._enemies.size() == 2
	valid = valid and authority._gather_targets.has(&"rusty_scrap_gather_1")
	var rectangle: FieldPlatform
	for platform in authority.get_node("Terrain").get_children():
		if platform is FieldPlatform and platform.size == Vector2(64, 32):
			var collision := platform.get_node("CollisionShape2D") as CollisionShape2D
			if collision.shape.size == platform.size and not collision.disabled and platform.visible:
				rectangle = platform
		await get_tree().physics_frame
	await get_tree().physics_frame
	var hits_rectangle := false
	if rectangle != null:
		var query := PhysicsPointQueryParameters2D.new()
		query.position = rectangle.global_position
		query.collision_mask = 1
		for hit in rectangle.get_world_2d().direct_space_state.intersect_point(query):
			if hit.get("collider") == rectangle:
				hits_rectangle = true
	valid = valid and hits_rectangle
	for marker in authority.get_node("Decorations").get_children():
		valid = valid and marker.get_child_count(true) == 0
	authority.queue_free()
	await get_tree().process_frame
	_finish(valid and await _generated_region())

func _generated_region() -> bool:
	GameSession.start_new_game()
	var region := ContentRegistry.get_definition(&"step5_flat") as RegionDefinition
	if region == null or not ContentRegistry.get_definition(&"step5_empty") is RegionDefinition or not ContentRegistry.get_definition(&"step5_platform") is RegionDefinition:
		return false
	var exit := SettlementExitDefinition.new()
	exit.id = &"step5_test_exit"
	exit.connected_region_ids = [region.id]
	exit.entry_point_id = region.entry_point_ids[0]
	ContentRegistry._definitions[exit.id] = exit
	GameSession.progression.unlocked_regions.append(region.id)
	GameSession.progression.unlocked_exits.append(exit.id)
	var context := GameSession.begin_adventure(exit.id, region.id, exit.entry_point_id)
	var packed := load(region.scene_path) as PackedScene
	if context == null or packed == null:
		return false
	var layer := Node2D.new()
	add_child(layer)
	SceneRouter.register_world_layer(layer)
	if not SceneRouter.go_to_adventure(context):
		SceneRouter.register_world_layer(null)
		layer.queue_free()
		return false
	var presentation := layer.get_child(0)
	var valid: bool = SceneRouter.current_world_id() == PlayerWorldState.adventure_world_id(region.id)
	valid = valid and presentation.get_node("Decorations").get_child_count() == 2
	for decoration in presentation.get_node("Decorations").get_children():
		valid = valid and decoration.get_child_count(true) == 1
	SceneRouter.clear_presented_world()
	SceneRouter.register_world_layer(null)
	layer.queue_free()
	await get_tree().process_frame
	var authority := packed.instantiate()
	authority.configure_server_runtime(PlayerWorldState.adventure_world_id(region.id), region.id)
	add_child(authority)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var peer := GameSession.get_local_peer_id()
	var manager := authority.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var actor := manager.get_actor(peer)
	valid = valid and actor != null and actor.global_position.x >= 150 and actor.global_position.x <= 294
	valid = valid and authority.get_node("EnemySpawnManager")._enemies.size() == 2 and authority._gather_targets.size() == 2
	if actor != null and not authority._gather_targets.is_empty():
		var id: StringName = authority._gather_targets.keys()[0]
		actor.global_position = authority._gather_targets[id].global_position
		valid = authority._try_gather(peer, id) and not authority._try_gather(peer, id) and valid
	for decoration in authority.get_node("Decorations").get_children():
		valid = valid and decoration.get_child_count(true) == 0
	var climbs := authority.get_node("Climbables").get_children()
	valid = valid and climbs.size() == 2
	for node in climbs:
		var climb := node as ClimbableArea2D
		var shape := climb.get_node_or_null("CollisionShape2D") as CollisionShape2D
		valid = valid and climb.top_marker.global_position.y < climb.bottom_marker.global_position.y and shape.shape is RectangleShape2D and not shape.disabled

	var query := PhysicsPointQueryParameters2D.new()
	query.position = Vector2(600, 565)
	query.collision_mask = 1
	valid = valid and not authority.get_world_2d().direct_space_state.intersect_point(query).is_empty()
	authority.queue_free()
	await get_tree().process_frame
	print("GENERATED REGION RUNTIME ", "PASS" if valid else "FAIL")
	return valid

func _playtest_region(id: StringName) -> bool:
	var region := ContentRegistry.get_definition(id) as RegionDefinition
	var definition_errors := region.validate_definition(ContentRegistry) if region != null else PackedStringArray(["RegionDefinition missing"])
	if region == null or region.entry_point_ids.is_empty() or not definition_errors.is_empty():
		_result("RegionDefinition", "FAIL", "%s | %s" % [id, definition_errors])
		return _print_results(id)
	_result("RegionDefinition", "PASS", String(id))
	var context := _create_context(region)
	if context == null:
		_result("ENTRY Reference", "FAIL", GameSession.last_message)
		return _print_results(id)
	_result("ENTRY Reference", "PASS", String(context.entry_point_id))
	var layer := Node2D.new()
	add_child(layer)
	SceneRouter.register_world_layer(layer)
	var loaded := SceneRouter.go_to_adventure(context)
	var world_id := PlayerWorldState.adventure_world_id(id)
	var valid := loaded and SceneRouter.current_world_id() == world_id
	if valid:
		valid = layer.get_child(0).get_node_or_null("EnvironmentPresenter") is EnvironmentPresenter
	_result("SceneRouter", "PASS" if loaded else "FAIL", String(world_id))
	var presentation_environment := valid
	print("PLAYTEST: SceneRouter ", "PASS" if valid else "FAIL", " | ENTRY ", context.entry_point_id)
	SceneRouter.clear_presented_world()
	SceneRouter.register_world_layer(null)
	layer.queue_free()
	await get_tree().process_frame
	var packed := load(region.scene_path) as PackedScene
	var authority := packed.instantiate()
	var manager := authority.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var markers: Array[RegionPoint] = []
	RegionPoint.collect(authority, markers)
	var anchor: RegionPoint
	for marker in markers:
		if marker.kind == RegionPoint.Kind.ENTRY and marker.point_id == context.entry_point_id:
			anchor = marker
	var preflight := {"issue": "NO_ENTRY", "candidates": [], "clearance": "NOT_EVALUATED", "support": "NOT_EVALUATED"}
	if anchor != null:
		preflight = PlayerSpawnManager.analyze_authored_spawn(authority, authority.to_local(anchor.global_position), manager.clearance_radius, manager.support_distance, manager.spawn_validation_collision_mask)
	_result("ENTRY Physical Anchor", "PASS" if preflight.issue.is_empty() else "FAIL", _diagnostic_text(preflight))
	var slots: Array[PlayerSpawnPoint] = []
	for node in authority.get_children():
		if node is PlayerSpawnPoint:
			slots.append(node)
	for slot in slots:
		var check := PlayerSpawnManager.analyze_authored_spawn(authority, slot.position, manager.clearance_radius, manager.support_distance, manager.spawn_validation_collision_mask)
		_result("Player Spawn Slot %d" % slot.spawn_index, "PASS" if check.issue.is_empty() else "FAIL", "%s | %s" % [authority.get_path_to(slot), _diagnostic_text(check)])
	var player_template := PlayerSpawnManager.PLAYER_SCENE.instantiate()
	var collision := player_template.get_node("CollisionShape2D") as CollisionShape2D
	var body_shape := collision.shape
	var body_offset := collision.transform
	player_template.free()
	for slot in slots:
		var detail := PlayerSpawnManager.analyze_authored_spawn(authority, slot.position, manager.clearance_radius,
			manager.support_distance, manager.spawn_validation_collision_mask, [], body_shape, body_offset)
		var sources := PackedStringArray()
		for candidate in detail.candidates:
			if candidate.overlap:
				sources.append(candidate.shape_path)
		for other in slots:
			if other != slot and body_shape.collide(Transform2D(0, slot.global_position) * body_offset, body_shape, Transform2D(0, other.global_position) * body_offset):
				sources.append(String(authority.get_path_to(other)))
		_result("Player Body Clearance / slot %d" % slot.spawn_index, "WARN" if not sources.is_empty() else "PASS",
			"Nominal capsule | preflight radius=%s | overlap sources=%s" % [manager.clearance_radius, sources])
	_result("Spawn Capacity", "PASS" if slots.size() >= NetworkManager.MAX_PLAYERS else "WARN", "%d/%d authored slots; actual assignment checked separately" % [slots.size(), NetworkManager.MAX_PLAYERS])
	var observed_assignments: Array[PlayerSpawnAssignment] = []
	manager.authoritative_spawn_created.connect(func(peer_id: int, assignment: PlayerSpawnAssignment) -> void:
		if peer_id == GameSession.get_local_peer_id():
			observed_assignments.append(assignment))
	authority.configure_server_runtime(world_id, id)
	add_child(authority)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var peer := GameSession.get_local_peer_id()
	var actor := manager.get_actor(peer)
	var has_actor := actor != null
	var expected_gather := 0
	for node in authority.find_children("*", "Marker2D", true, false):
		if node is FieldGatherPoint and node.enabled:
			expected_gather += 1
	var escape_targets := 0
	for node in authority.get_children():
		if node is EscapePoint2D:
			escape_targets += 1
	# Reproduce the former post-attachment scan, then explicitly exclude the actor.
	if anchor != null and actor != null:
		var raw := PlayerSpawnManager.analyze_authored_spawn(authority, authority.to_local(anchor.global_position), manager.clearance_radius, manager.support_distance, manager.spawn_validation_collision_mask)
		for candidate in raw.candidates:
			if candidate.overlap:
				print("SPAWN TRACE after attachment | ", _candidate_text(candidate))
		var excluding: Array[RID] = [actor.get_rid()]
		var filtered := PlayerSpawnManager.analyze_authored_spawn(authority, authority.to_local(anchor.global_position), manager.clearance_radius, manager.support_distance, manager.spawn_validation_collision_mask, excluding)
		_result("ENTRY Clearance excluding local actor", "PASS" if filtered.issue.is_empty() else "WARN", _diagnostic_text(filtered))
		var live_issue := manager._position_issue(authority.to_local(anchor.global_position), false, excluding)
		_result("ENTRY Live Physics", "PASS" if live_issue.is_empty() else "WARN", "local PlayerActor RID excluded | issue=" + live_issue)
		var assignment: PlayerSpawnAssignment = observed_assignments[0] if not observed_assignments.is_empty() else null
		_result("Player Spawn Assignment", "PASS" if assignment != null and assignment.error_message.is_empty() else "FAIL",
			"%s | position=%s | reason=%s" % [assignment.error_message, assignment.position, assignment.reason] if assignment != null else "No assignment")
	else:
		_result("Player Spawn Assignment", "FAIL", "No ENTRY or no actual actor")
	_result("Player Actor", "PASS" if has_actor else "FAIL", str(actor.global_position) if has_actor else "No authoritative PlayerActor")
	var ground := false
	var terrain_hit := false
	var ground_detail := "No actor available for the live support query"
	if has_actor:
		var ray := PhysicsRayQueryParameters2D.create(actor.global_position, actor.global_position + Vector2.DOWN * manager.support_distance, manager.spawn_validation_collision_mask, [actor.get_rid()])
		var hit := actor.get_world_2d().direct_space_state.intersect_ray(ray)
		ground = not hit.is_empty()
		var source: Node = hit.get("collider")
		terrain_hit = source is StaticBody2D or source is TileMapLayer
		ground_detail = "query=%s mask=%s support=%s source=%s | local actor excluded" % [actor.global_position,
			manager.spawn_validation_collision_mask, hit.get("position", "none"),
			String(authority.get_path_to(source)) if source != null and authority.is_ancestor_of(source) else str(source)]
	var enemies: int = authority.get_node("EnemySpawnManager")._enemies.size()
	var expected_enemies := 0
	for node in authority.find_children("*", "Marker2D", true, false):
		if node is FieldEnemySpawnPoint and node.enabled:
			expected_enemies += 1
	print("PLAYTEST: spawn=", has_actor, " terrain=", ground, " authored=", preflight.issue, " enemies=", enemies, "/", expected_enemies,
		" gather=", authority._gather_targets.size(), "/", expected_gather, " escapes=", escape_targets)
	_result("Ground Support", "PASS" if ground else "FAIL", ground_detail)
	_result("Terrain Physics", "PASS" if terrain_hit else "FAIL", "Expected authored terrain collider | " + ground_detail)
	_result("Enemy Spawn", "PASS" if enemies == expected_enemies else "FAIL", "%d/%d" % [enemies, expected_enemies])
	_result("GatherPoint Configuration", "PASS" if authority._gather_targets.size() == expected_gather else "FAIL", "%d/%d" % [authority._gather_targets.size(), expected_gather])
	_result("EscapePoint", "PASS" if escape_targets == region.escape_point_ids.size() else "FAIL", "%d/%d" % [escape_targets, region.escape_point_ids.size()])
	_result("Environment Separation", "PASS" if presentation_environment and authority.get_node_or_null("EnvironmentPresenter") == null else "FAIL", "Presenter in visible world only")
	valid = valid and has_actor and ground and enemies == expected_enemies and authority._gather_targets.size() == expected_gather and escape_targets == region.escape_point_ids.size()
	valid = valid and authority.get_node_or_null("EnvironmentPresenter") == null
	if has_actor and not authority._gather_targets.is_empty():
		var gather_id: StringName = authority._gather_targets.keys()[0]
		actor.global_position = authority._gather_targets[gather_id].global_position
		var gathered: bool = authority._try_gather(peer, gather_id) and not authority._try_gather(peer, gather_id)
		print("PLAYTEST: authoritative gather ", "PASS" if gathered else "FAIL")
		_result("GatherPoint Request", "PASS" if gathered else "FAIL", "First server request succeeds and repeated request is rejected")
		valid = valid and gathered
	else:
		_result("GatherPoint Request", "NOT_EVALUATED", "No enabled gather point or actor")
	authority.queue_free()
	await get_tree().process_frame
	var settlement_return := await _playtest_escape(context)
	print("PLAYTEST: escape interaction ", "PASS" if settlement_return else "FAIL")
	_result("Settlement Return", "PASS" if settlement_return else "FAIL", "EscapePoint interaction through existing NetworkManager")
	GameSession.start_new_game()
	_result("Runtime Flow", "PASS" if valid and settlement_return else "FAIL", String(id))
	return _print_results(id)

func _playtest_escape(context: AdventureContext) -> bool:
	var layer := Node2D.new()
	add_child(layer)
	SceneRouter.register_world_layer(layer)
	var escaped := false
	if SceneRouter.go_to_adventure(context):
		await get_tree().physics_frame
		var scene := layer.get_child(0)
		var manager := scene.get_node("PlayerSpawnManager") as PlayerSpawnManager
		var actor := manager.get_actor(GameSession.get_local_peer_id())
		if actor != null:
			for node in scene.get_children():
				if node is EscapePoint2D:
					actor.global_position = node.global_position
					escaped = node.interact(actor) and not GameSession.is_local_player_in_adventure()
					if escaped:
						break
	SceneRouter.clear_presented_world()
	SceneRouter.register_world_layer(null)
	layer.queue_free()
	await get_tree().process_frame
	return escaped

func _create_context(region: RegionDefinition) -> AdventureContext:
	var id := region.id
	GameSession.start_new_game()
	var context: AdventureContext
	for definition in ContentRegistry.all_definitions():
		if definition is SettlementExitDefinition and id in definition.connected_region_ids and GameSession.can_use_exit(definition.id, id).success:
			context = GameSession.request_adventure_from_exit(definition.id, id)
			break
	if context == null:
		var exit := SettlementExitDefinition.new()
		exit.id = &"rtc_editor_playtest_exit"
		if ContentRegistry.has_id(exit.id):
			return null
		exit.connected_region_ids = [id]
		exit.entry_point_id = region.entry_point_ids[0]
		ContentRegistry._definitions[exit.id] = exit
		if not id in GameSession.progression.unlocked_regions:
			GameSession.progression.unlocked_regions.append(id)
		GameSession.progression.unlocked_exits.append(exit.id)
		context = GameSession.request_adventure_from_exit(exit.id, id)
		ContentRegistry._definitions.erase(exit.id)
		GameSession.progression.unlocked_exits.erase(exit.id)
		print("PLAYTEST: isolated temporary exit")
	return context

func _result(stage: String, status: String, detail: String) -> void:
	_playtest_results.append({"stage": stage, "status": status, "detail": detail})

func _print_results(id: StringName) -> bool:
	var overall := "PASS"
	print("REGION PLAYTEST RESULT | ", id)
	for item in _playtest_results:
		print(item.stage, " | ", item.status, " | ", item.detail)
		if item.status == "FAIL":
			overall = "FAIL"
		elif overall != "FAIL" and item.status in ["WARN", "NOT_EVALUATED"]:
			overall = "PASS_WITH_WARNINGS"
	print("Overall | ", overall)
	print("REGION_PLAYTEST_JSON ", JSON.stringify({"region": id, "overall": overall, "results": _playtest_results}))
	return overall != "FAIL"

func _candidate_text(candidate: Dictionary) -> String:
	return "body=%s type=%s shape=%s type=%s layer=%s mask=%s transform=%s query=%s radius=%s overlap=%s support=%s one_way=%s" % [
		candidate.body_path, candidate.body_type, candidate.shape_path, candidate.shape_type, candidate.layer, candidate.mask,
		candidate.transform, candidate.position, candidate.radius, candidate.overlap, candidate.support, candidate.one_way]

func _diagnostic_text(detail: Dictionary) -> String:
	var message := "clearance=%s support=%s issue=%s | query=%s radius=%s mask=%s" % [detail.clearance, detail.support, detail.issue, detail.get("position", "unavailable"), detail.get("radius", "unavailable"), detail.get("mask", "unavailable")]
	for candidate in detail.candidates:
		if candidate.overlap:
			message += " | " + _candidate_text(candidate)
	return message

func _finish(valid: bool) -> void:
	print("AUTHORED FIELD RUNTIME ", "PASS" if valid else "FAIL")
	get_tree().quit(0 if valid else 1)
