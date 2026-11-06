extends RefCounted

const PLAYER_B: StringName = &"player_00000000000000000000000000000042"

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.activate_offline_local_identity()
	var app := (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	t.add_child(app)
	app._host_game(26000 + randi_range(0, 5000))
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	var presentation := app.world_layer.get_child(0).get_node("PlayerSpawnManager") as PlayerSpawnManager
	NetworkManager._set_identity(42, PLAYER_B)
	NetworkManager.players[42] = NetworkPlayerInfo.new(42, PLAYER_B, "Roster fixture", true)
	GameSession.attach_player(42, PLAYER_B)
	await t.get_tree().process_frame
	var assignment := NetworkManager.world_assignment_for_peer(42)
	var spawn := NetworkManager.spawn_assignment_for_peer(42)
	t.assert_true(presentation.get_actor(42) != null, "fresh registration creates same-world Host presentation")
	var runtime := (app.get_node("ServerWorldRoot") as ServerWorldRoot).runtime(&"settlement").player_manager()
	t.assert_true(runtime.get_actor(42) != presentation.get_actor(42), "runtime and presentation own distinct actors")

	# Real world changes must retire presentation nodes, not keep hidden/stopped
	# actors that a later roster treats as already initialized.
	GameSession.move_player_to_world(42, PlayerWorldState.WorldKind.ADVENTURE, &"adventure:sewer_region", &"sewer_region", &"sewer_entrance")
	t.assert_true(presentation.get_actor(42) == null, "departure immediately removes old-world presentation")
	GameSession.move_player_to_world(42, PlayerWorldState.WorldKind.SETTLEMENT, &"settlement")
	assignment = NetworkManager.world_assignment_for_peer(42)
	NetworkManager.register_authoritative_spawn_assignment(42, spawn)
	NetworkManager._broadcast_world_arrival(42)
	t.assert_true(presentation.get_actor(42) != null and presentation.get_actor(42).visible \
		and presentation.get_actor(42).process_mode != Node.PROCESS_MODE_DISABLED, "Host receives validated world arrival and restores presentation")

	# The signal consumer is also defensive: malformed identity/session/revision,
	# nonfinite placement, and cross-world payloads cannot create an absent actor.
	for variant in ["session", "identity", "revision", "world", "position"]:
		presentation._despawn_local(42)
		var invalid := PlayerWorldAssignment.from_payload(assignment.to_payload())
		var position := spawn.position
		match variant:
			"session": invalid.session_id = "retired-session"
			"identity": invalid.player_id = GameSession.get_local_player_id()
			"revision": invalid.revision -= 1
			"world": invalid.world_id = &"adventure:sewer_region"
			"position": position = Vector2.INF
		presentation._on_world_roster_player_received(42, invalid, position)
		t.assert_true(presentation.get_actor(42) == null, "invalid %s roster cannot create a presentation actor" % variant)
	presentation._despawn_local(42)
	for field in ["session", "identity", "position"]:
		var invalid := PlayerSpawnAssignment.create(GameSession.session_id, PLAYER_B, PlayerSpawnAssignment.SpawnKind.FRESH_SLOT, spawn.position)
		match field:
			"session": invalid.session_id = "retired-session"
			"identity": invalid.player_id = GameSession.get_local_player_id()
			"position": invalid.position = Vector2.INF
		NetworkManager._spawn_assignments[42] = invalid
		t.assert_true(not NetworkManager.apply_local_world_roster_player(42) and presentation.get_actor(42) == null, "Host roster rejects invalid spawn %s" % field)
	NetworkManager._spawn_assignments[42] = spawn
	presentation._on_world_roster_player_received(42, assignment, spawn.position)
	var actor := presentation.get_actor(42)
	t.assert_true(actor != null, "valid roster creates a presentation actor")
	if actor != null:
		actor.visible = false
		actor.process_mode = Node.PROCESS_MODE_DISABLED
		presentation._on_world_roster_player_received(42, assignment, spawn.position)
		t.assert_true(presentation.get_actor(42) == actor and actor.visible \
			and actor.process_mode == Node.PROCESS_MODE_INHERIT, "idempotent roster restores visibility without creating duplicates")
		t.assert_true(not actor.is_simulation_authority() and not actor.simulation_enabled, "restored Host presentation never simulates gameplay")
		actor.position += Vector2(20, 0)
		var current_position := actor.position
		presentation._on_world_roster_player_received(42, assignment, spawn.position)
		t.assert_equal(actor.position, current_position, "duplicate active roster does not teleport a moving presentation")
	# Exercise the RPC receiver's client mirror guard independently of transport.
	# A late departure from the previous visit must not remove the returned actor.
	var old_world := PlayerWorldAssignment.from_payload(assignment.to_payload())
	old_world.revision -= 1
	old_world.world_kind = PlayerWorldState.WorldKind.ADVENTURE
	old_world.world_id = &"adventure:sewer_region"
	old_world.region_id = &"sewer_region"
	old_world.entry_point_id = &"sewer_entrance"
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	NetworkManager._receive_world_roster_remove(42, old_world.to_payload())
	t.assert_true(presentation.get_actor(42) == actor, "stale client departure cannot remove the returned actor")
	NetworkManager._receive_world_roster_player(42, old_world.to_payload(), [200.0, 520.0])
	t.assert_equal(GameSession.get_peer_world(42).revision, assignment.revision, "stale roster cannot regress the client world mirror")
	NetworkManager.state = NetworkManager.ConnectionState.HOSTING
	var authoritative := runtime.get_actor(42)
	runtime._on_world_roster_player_removed(42)
	t.assert_true(runtime.get_actor(42) == authoritative, "presentation roster removal never removes an authoritative actor")
	var local := presentation.get_actor(1)
	local.network._local_sequence = 2500
	local.network._process(0.01)
	var sent := local.network._local_sequence
	presentation._replace_actor_local(1, local.position)
	local = presentation.get_actor(1)
	local.network._process(0.01)
	t.assert_true(local.network._local_sequence > sent, "replacement presentation continues movement sequence after an old actor's in-flight input")
	var simulated := runtime.get_actor(1)
	simulated.network._snapshot_sequence = 2500
	simulated.network.server_snapshot_tick(0.1)
	var published := simulated.network._snapshot_sequence
	runtime._replace_actor_local(1, simulated.position)
	t.assert_true(runtime.get_actor(1).network._snapshot_sequence >= published, "replacement runtime keeps transform order so respawn/reentry cannot freeze presentation")
	app._leave_game()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	app.get_parent().remove_child(app)
	app.queue_free()
	SceneRouter.register_world_layer(null)
	await t.get_tree().process_frame
