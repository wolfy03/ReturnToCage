extends RefCounted

const PLAYER_A := &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const PLAYER_B := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLAYER_C := &"player_cccccccccccccccccccccccccccccccc"

func run(t: Node) -> void:
	_test_authored_diagnostics(t)
	_test_assignment_validation(t)
	_test_policy_decisions(t)
	_test_attach_rollback(t)
	await _test_initialization_retry(t)
	await _test_settlement_runtime_validation(t)
	_test_safe_position_authority(t)

func _test_assignment_validation(t: Node) -> void:
	var valid := PlayerSpawnAssignment.create(
		"spawn-session", PLAYER_A, PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION,
		Vector2(240, 500)
	)
	var parsed := PlayerSpawnAssignment.from_payload(valid.to_payload(), "spawn-session", PLAYER_A)
	t.assert_true(parsed.error_message.is_empty() and parsed.position == Vector2(240, 500), "spawn assignment validates its session, owner and finite position")
	t.assert_true(not PlayerSpawnAssignment.from_payload(valid.to_payload(), "other-session", PLAYER_A).error_message.is_empty(), "stale-session spawn assignment is rejected")
	t.assert_true(not PlayerSpawnAssignment.from_payload(valid.to_payload(), "spawn-session", PLAYER_B).error_message.is_empty(), "other-owner spawn assignment is rejected")
	var invalid := valid.to_payload()
	invalid["position"] = [INF, 500.0]
	t.assert_true(not PlayerSpawnAssignment.from_payload(invalid, "spawn-session", PLAYER_A).error_message.is_empty(), "non-finite spawn assignment is rejected")

func _test_policy_decisions(t: Node) -> void:
	var issues := {
		Vector2(900, 500): "OUT_OF_BOUNDS",
		Vector2(300, 500): "BLOCKED",
	}
	var validator := func(position: Vector2) -> String: return issues.get(position, "")
	var returning := PlayerSpawnPolicy.decide(
		"spawn-session", PLAYER_A, true, Vector2(200, 500), [Vector2(100, 500)],
		[Vector2(100, 500)], validator
	)
	t.assert_equal(returning.spawn_kind, PlayerSpawnAssignment.SpawnKind.RETURNING_SAFE_POSITION, "returning player uses a valid safe position")
	t.assert_true(not returning.fallback_used and returning.position == Vector2(200, 500), "valid returning spawn avoids fallback")
	var fallback := PlayerSpawnPolicy.decide(
		"spawn-session", PLAYER_A, true, Vector2(900, 500), [Vector2(100, 500)],
		[Vector2(300, 500), Vector2(100, 500)], validator
	)
	t.assert_equal(fallback.spawn_kind, PlayerSpawnAssignment.SpawnKind.SETTLEMENT_FALLBACK, "world-invalid returning position uses explicit fallback")
	t.assert_true(fallback.fallback_used and fallback.position == Vector2(100, 500) and fallback.reason == "OUT_OF_BOUNDS", "fallback is deterministic and records its reason")
	var fresh := PlayerSpawnPolicy.decide(
		"spawn-session", PLAYER_B, false, Vector2(200, 500),
		[Vector2(300, 500), Vector2(150, 500)], [Vector2(100, 500)], validator
	)
	t.assert_equal(fresh.spawn_kind, PlayerSpawnAssignment.SpawnKind.FRESH_SLOT, "fresh player ignores last-safe position")
	t.assert_equal(fresh.position, Vector2(150, 500), "fresh player takes the first valid configured slot")

func _test_attach_rollback(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	NetworkManager.state = NetworkManager.ConnectionState.HOSTING
	NetworkManager._session_entered = true
	NetworkManager._accepting_handshakes = true
	var returning_state := GameSession.attach_player(42, PLAYER_B)
	GameSession.detach_player(42)
	NetworkManager._set_identity(84, PLAYER_B)
	NetworkManager.players[84] = NetworkPlayerInfo.new(84, PLAYER_B, "B", true)
	NetworkManager._returning_peers[84] = true
	t.assert_true(GameSession.attach_player(84, PLAYER_B) == returning_state, "rollback fixture reattaches returning canonical state")
	NetworkManager._rollback_peer_attachment(84, PLAYER_B, true, false)
	t.assert_true(GameSession.get_player_state_by_player_id(PLAYER_B) == returning_state and not GameSession.has_player(84), "returning preparation failure detaches but retains canonical state")
	t.assert_true(NetworkManager.peer_id_for_player(PLAYER_B) == 0 and NetworkManager.spawn_assignment_for_peer(84) == null, "returning rollback removes identity and spawn caches")

	NetworkManager._set_identity(85, PLAYER_C)
	NetworkManager.players[85] = NetworkPlayerInfo.new(85, PLAYER_C, "C", true)
	NetworkManager._returning_peers[85] = false
	t.assert_true(GameSession.attach_player(85, PLAYER_C) != null, "rollback fixture creates fresh canonical state")
	NetworkManager._rollback_peer_attachment(85, PLAYER_C, false, false)
	t.assert_true(not GameSession.has_persistent_player(PLAYER_C) and not GameSession.has_player(85), "fresh preparation failure removes ghost canonical state")
	t.assert_true(NetworkManager.peer_id_for_player(PLAYER_C) == 0 and NetworkManager.spawn_assignment_for_peer(85) == null, "fresh rollback removes all runtime mappings")
	t.assert_true(NetworkManager.validate_runtime_invariants().is_empty(), "attachment rollback leaves runtime mappings symmetric")
	NetworkManager.leave_game()

func _test_settlement_runtime_validation(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var world := (load("res://world/settlement/settlement.tscn") as PackedScene).instantiate() as Node2D
	t.add_child(world)
	await t.get_tree().physics_frame
	var manager := world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	t.assert_equal(manager._position_issue(Vector2(350, 456)), "", "configured Settlement world accepts a walkable collision-safe position")
	manager.spawn_validation_collision_mask = 0
	t.assert_equal(manager._position_issue(Vector2(350, 456)), "INVALID_COLLISION_MASK", "zero spawn-validation collision mask is an explicit configuration error")
	manager.spawn_validation_collision_mask = 2
	t.assert_equal(manager._position_issue(Vector2(350, 456)), "NO_WALKABLE_SUPPORT", "clearance and support queries honor the configured collision mask")
	manager.spawn_validation_collision_mask = 1
	t.assert_equal(manager._position_issue(Vector2(1600, 520)), "OUT_OF_BOUNDS", "finite out-of-bounds safe position is rejected")
	var blocker := StaticBody2D.new()
	blocker.position = Vector2(400, 500)
	var collision := CollisionShape2D.new()
	var shape := CircleShape2D.new()
	shape.radius = 20.0
	collision.shape = shape
	blocker.add_child(collision)
	world.add_child(blocker)
	await t.get_tree().physics_frame
	t.assert_equal(manager._position_issue(Vector2(400, 500)), "BLOCKED", "collision-blocked safe position is rejected")
	world.queue_free()
	await t.get_tree().process_frame

func _test_initialization_retry(t: Node) -> void:
	NetworkManager.leave_game()
	t.assert_true(GameSession.start_new_game(), "spawn initialization retry fixture starts an offline session")
	var port := 26000 + randi_range(0, 1200)
	t.assert_equal(NetworkManager.begin_host_restore(port, 2), OK, "spawn initialization retry fixture opens a restoring transport")
	var world := (load("res://world/settlement/settlement.tscn") as PackedScene).instantiate() as Node2D
	t.add_child(world)
	await t.get_tree().process_frame
	var manager := world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	manager.initialize_spawns()
	t.assert_true(not manager._initialized and manager.get_actor(1) == null, "restoring host does not permanently commit early spawn initialization")
	NetworkManager.abort_host_restore()
	manager.initialize_spawns()
	await t.get_tree().process_frame
	t.assert_true(manager._initialized and manager.get_actor(1) != null, "spawn initialization succeeds when retried after authority becomes available")
	manager.initialize_spawns()
	t.assert_equal(manager._actors.size(), 1, "successful spawn initialization remains idempotent")
	world.queue_free()
	await t.get_tree().process_frame

func _test_safe_position_authority(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var state := GameSession.player
	t.assert_true(GameSession.update_player_last_safe_position(1, Vector2(222, 500)), "offline authority updates a validated safe position")
	t.assert_equal(state.last_safe_position, Vector2(222, 500), "safe-position update commits to canonical PlayerState")
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	state.last_safe_position = Vector2(999, 999)
	t.assert_equal(state.last_safe_position, Vector2(222, 500), "client-side direct safe-position mutation is blocked")
	NetworkManager.state = NetworkManager.ConnectionState.OFFLINE

func _test_authored_diagnostics(t: Node) -> void:
	var scene := load("res://world/adventure/sewer_region.tscn") as PackedScene
	var root := scene.instantiate() as Node2D
	var at := Vector2(150, 520)
	var clean := PlayerSpawnManager.analyze_authored_spawn(root, at, 8, 100, 1)
	t.assert_true(clean.issue.is_empty() and clean.clearance == "PASS" and clean.support == "PASS",
		"sewer entry clearance passes before actors are attached; floor starts at 535")
	var floor_contact := false
	for candidate in clean.candidates:
		floor_contact = floor_contact or candidate.shape_path == "Terrain/Floor/CollisionShape2D" and candidate.support and not candidate.overlap
	t.assert_true(floor_contact, "detailed support result identifies the sewer floor without inventing an overlap")
	var nominal_body := CapsuleShape2D.new()
	nominal_body.radius = 14
	nominal_body.height = 34
	var nominal := PlayerSpawnManager.analyze_authored_spawn(root, at, 8, 100, 1, [], nominal_body)
	t.assert_true(nominal.clearance == "FAIL" and nominal.candidates.any(func(item: Dictionary) -> bool:
		return item.shape_path == "Terrain/Floor/CollisionShape2D" and item.overlap),
		"nominal full capsule warning identifies floor separately from the passing preflight circle")
	var actor := CharacterBody2D.new()
	actor.name = "DiagnosticPlayer"
	actor.position = at
	actor.collision_layer = 1
	var capsule := CollisionShape2D.new()
	capsule.name = "CollisionShape2D"
	var shape := CapsuleShape2D.new()
	shape.radius = 14
	shape.height = 34
	capsule.shape = shape
	actor.add_child(capsule)
	root.add_child(actor)
	var occupied := PlayerSpawnManager.analyze_authored_spawn(root, at, 8, 100, 1)
	var blocker: Dictionary = {}
	for candidate in occupied.candidates:
		if candidate.overlap:
			blocker = candidate
	t.assert_true(occupied.issue == "BLOCKED" and blocker.get("shape_path") == "DiagnosticPlayer/CollisionShape2D"
		and blocker.get("body_type") == "CharacterBody2D" and blocker.get("mask") == 1 and blocker.get("radius") == 8,
		"post-attachment BLOCKED reports actual player capsule and query parameters")
	var excluded: Array[RID] = [actor.get_rid()]
	t.assert_true(PlayerSpawnManager.analyze_authored_spawn(root, at, 8, 100, 1, excluded).issue.is_empty(),
		"excluding the attached actor restores authored and physics query parity")
	capsule.disabled = true
	t.assert_true(PlayerSpawnManager.authored_spawn_issue(root, at, 8, 100, 1).is_empty(), "disabled source is ignored")
	capsule.disabled = false
	actor.collision_layer = 2
	t.assert_true(PlayerSpawnManager.authored_spawn_issue(root, at, 8, 100, 1).is_empty(), "source outside collision mask is ignored")
	t.assert_true(PlayerSpawnManager.authored_spawn_issue(root, at, 8, 100, 0) == "INVALID_COLLISION_MASK", "zero collision mask rejected")
	t.assert_true(PlayerSpawnManager.authored_spawn_issue(root, Vector2(-200, -200), 8, 100, 1) == "NO_WALKABLE_SUPPORT", "unsupported position reported independently")
	var prefab := load("res://world/adventure/field_platform.tscn") as PackedScene
	var platform := prefab.instantiate() as FieldPlatform
	platform.position = Vector2(-400, 565)
	platform.size = Vector2(1200, 60)
	root.add_child(platform)
	var original_shape: Shape2D = platform.get_node("CollisionShape2D").shape
	t.assert_true(PlayerSpawnManager.analyze_authored_spawn(root, Vector2(-800, 520), 8, 100, 1).support == "PASS"
		and platform.get_node("CollisionShape2D").shape == original_shape,
		"detached FieldPlatform uses authored dimensions without mutating prefab or collision resources")
	root.scale.x = 0
	t.assert_true(PlayerSpawnManager.authored_spawn_issue(root, at, 8, 100, 1) == "NON_FINITE", "singular world transform rejected before inverse")
	root.free()
