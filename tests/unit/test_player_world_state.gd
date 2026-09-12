extends RefCounted

const PLAYER_A: StringName = &"player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
const PLAYER_B: StringName = &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLAYER_C: StringName = &"player_cccccccccccccccccccccccccccccccc"

func run(t: Node) -> void:
	_test_model_and_assignment(t)
	_test_canonical_registry(t)
	_test_individual_adventure_return(t)
	_test_network_revision_guard(t)

func _test_model_and_assignment(t: Node) -> void:
	var settlement := PlayerWorldState.settlement(PLAYER_A)
	t.assert_true(settlement.is_valid(), "Settlement player world state is valid")
	t.assert_equal(settlement.world_id, &"settlement", "Settlement uses the canonical world id")
	var sewer := PlayerWorldState.adventure(PLAYER_B, &"sewer_region", &"sewer_entrance", 3)
	t.assert_true(sewer.is_valid(), "Adventure player world state is valid")
	t.assert_equal(sewer.world_id, &"adventure:sewer_region", "Adventure world id derives from region id")
	var invalid_player := PlayerWorldState.settlement(&"")
	t.assert_true(not invalid_player.is_valid(), "World state rejects an empty player identity")
	var invalid_world := PlayerWorldState.create(PLAYER_A, PlayerWorldState.WorldKind.SETTLEMENT, &"")
	t.assert_true(not invalid_world.is_valid(), "World state rejects an empty world id")
	var invalid_kind := PlayerWorldState.create(PLAYER_A, PlayerWorldState.WorldKind.NONE, &"none")
	t.assert_true(not invalid_kind.is_valid(), "World state rejects NONE as stable participation")
	var assignment := PlayerWorldAssignment.from_world_state("world-session", sewer)
	var parsed := PlayerWorldAssignment.from_payload(assignment.to_payload(), "world-session", PLAYER_B)
	t.assert_true(parsed.error_message.is_empty(), "Player world assignment validates its schema")
	t.assert_equal(parsed.revision, 3, "Player world assignment preserves revision")
	t.assert_true(not PlayerWorldAssignment.from_payload(assignment.to_payload(), "other-session", PLAYER_B).error_message.is_empty(), "World assignment rejects a wrong session")
	t.assert_true(not PlayerWorldAssignment.from_payload(assignment.to_payload(), "world-session", PLAYER_C).error_message.is_empty(), "World assignment rejects a wrong owner")

func _test_canonical_registry(t: Node) -> void:
	NetworkManager.leave_game()
	t.assert_true(GameSession.start_new_game(), "World registry fixture starts")
	var local_id := GameSession.get_local_player_id()
	GameSession.attach_player(42, PLAYER_B)
	GameSession.attach_player(43, PLAYER_C)
	t.assert_equal(GameSession.get_player_world_id(local_id), &"settlement", "Fresh host starts in Settlement")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_B), &"settlement", "Fresh join starts in Settlement")
	var moved := GameSession.move_player_to_world(
		42, PlayerWorldState.WorldKind.ADVENTURE, &"adventure:sewer_region",
		&"sewer_region", &"sewer_entrance"
	)
	t.assert_true(moved.success, "Authoritative player transition succeeds")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_B), &"adventure:sewer_region", "B moves independently to Sewer")
	t.assert_equal(GameSession.get_player_world_id(local_id), &"settlement", "A remains in Settlement when B moves")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_C), &"settlement", "C remains in Settlement when B moves")
	t.assert_true(not SaveManager.can_save().success, "Save v4 remains blocked while any player has runtime Adventure participation")
	t.assert_equal(GameSession.peer_ids_in_world(&"settlement"), [1, 43], "Settlement peer query excludes Sewer B")
	t.assert_equal(GameSession.peer_ids_in_world(&"adventure:sewer_region"), [42], "Sewer peer query contains only B")
	t.assert_true(not GameSession.are_peers_in_same_world(1, 42) and GameSession.are_peers_in_same_world(1, 43), "same-world query follows canonical participation")
	var read_only := GameSession.get_player_world(PLAYER_B)
	read_only.world_id = &"tampered"
	t.assert_equal(GameSession.get_player_world_id(PLAYER_B), &"adventure:sewer_region", "world queries expose a copy, not mutable canonical state")
	var persistent_json := JSON.stringify(GameSession.export_persistent_state())
	t.assert_true(not persistent_json.contains("world_id") and not persistent_json.contains("world_kind"), "runtime world participation is absent from Save v4")
	var before_revision := GameSession.get_player_world(PLAYER_B).revision
	t.assert_equal(before_revision, 2, "successful transition increments B world revision once")
	var invalid := GameSession.move_player_to_world(
		42, PlayerWorldState.WorldKind.ADVENTURE, &"bad-world", &"missing", &"missing"
	)
	t.assert_true(not invalid.success, "Invalid destination is rejected")
	t.assert_equal(GameSession.get_player_world(PLAYER_B).revision, before_revision, "Rejected transition preserves revision")
	t.assert_true(not GameSession.can_peer_use_exit(43, &"sewer_gate", &"missing_region").success, "unknown region cannot mutate player world")
	var c_runtime := GameSession.get_player_runtime(43)
	c_runtime.life_phase = PlayerRuntimeState.LifePhase.DEAD
	t.assert_true(not GameSession.can_peer_use_exit(43, &"sewer_gate", &"sewer_region").success, "dead player cannot request a world transition")
	c_runtime.life_phase = PlayerRuntimeState.LifePhase.ALIVE
	GameSession.move_player_to_world(43, PlayerWorldState.WorldKind.ADVENTURE, &"adventure:sewer_region", &"sewer_region", &"sewer_entrance")
	GameSession.move_player_to_world(42, PlayerWorldState.WorldKind.SETTLEMENT, &"settlement")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_B), &"settlement", "B returns independently to Settlement")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_C), &"adventure:sewer_region", "B return does not end C participation")
	t.assert_true(not SaveManager.can_save().success, "another player's remaining Adventure continues to block safe-boundary save")
	var canonical_b := GameSession.get_player_state_by_player_id(PLAYER_B)
	GameSession.detach_player(42)
	t.assert_true(GameSession.get_player_state_by_player_id(PLAYER_B) == canonical_b, "detach retains B canonical PlayerState")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_B), &"settlement", "detached player returns to safe Settlement participation")
	GameSession.attach_player(84, PLAYER_B)
	t.assert_true(GameSession.get_player(84) == canonical_b, "reconnect reuses canonical PlayerState")
	t.assert_equal(GameSession.get_peer_world_id(84), &"settlement", "reconnect assignment starts in Settlement")
	GameSession.detach_player(84)
	GameSession.detach_player(43)
	GameSession.remove_player_state(PLAYER_B)
	GameSession.remove_player_state(PLAYER_C)

func _test_network_revision_guard(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var local_id := GameSession.get_local_player_id()
	GameSession.session_id = "world-revision-session"
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED
	var current_revision := GameSession.get_player_world(local_id).revision
	var unauthorized := GameSession.move_player_to_world(
		1, PlayerWorldState.WorldKind.ADVENTURE, &"adventure:sewer_region",
		&"sewer_region", &"sewer_entrance"
	)
	t.assert_true(not unauthorized.success, "a client cannot mutate canonical world participation")
	t.assert_equal(GameSession.get_player_world(local_id).revision, current_revision, "unauthorized mutation preserves world revision")
	var sewer := PlayerWorldAssignment.from_world_state(
		GameSession.session_id,
		PlayerWorldState.adventure(local_id, &"sewer_region", &"sewer_entrance", current_revision + 1)
	)
	t.assert_true(GameSession.apply_player_world_assignment(sewer), "client accepts a newer authoritative assignment")
	var stale := PlayerWorldAssignment.from_world_state(
		GameSession.session_id, PlayerWorldState.settlement(local_id, current_revision)
	)
	t.assert_true(not GameSession.apply_player_world_assignment(stale), "client rejects a stale world assignment")
	t.assert_equal(GameSession.get_player_world_id(local_id), &"adventure:sewer_region", "stale assignment cannot overwrite current world")
	t.assert_true(GameSession.apply_player_world_assignment(sewer), "equal world assignment is an idempotent no-op")
	NetworkManager.state = NetworkManager.ConnectionState.OFFLINE
	GameSession.start_new_game()

func _test_individual_adventure_return(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	GameSession.attach_player(42, PLAYER_B)
	GameSession.attach_player(43, PLAYER_C)
	var b_started := GameSession.begin_player_adventure(42, &"sewer_gate", &"sewer_region")
	var c_started := GameSession.begin_player_adventure(43, &"sewer_gate", &"sewer_region")
	t.assert_true(b_started.success and c_started.success, "B and C can independently join the same Adventure world")
	t.assert_equal(GameSession.peer_ids_in_world(&"adventure:sewer_region"), [42, 43], "same-region participation groups B and C")
	var session: AdventureSession = GameSession._adventure_sessions_by_world.get(&"adventure:sewer_region")
	t.assert_true(session != null and session.player_adventures.size() == 2, "shared region session tracks both individual participants")
	var b_returned := GameSession.finish_player_adventure(42, AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(b_returned.success, "B can independently return to Settlement")
	t.assert_equal(GameSession.get_peer_world_id(42), &"settlement", "B return updates only B world state")
	t.assert_equal(GameSession.get_peer_world_id(43), &"adventure:sewer_region", "C remains in Adventure when B returns")
	t.assert_true(session.get_player_adventure(42) == null and session.get_player_adventure(43) != null, "B extraction preserves C adventure participation")
	GameSession.detach_player(42)
	var canonical_c := GameSession.get_player_state_by_player_id(PLAYER_C)
	GameSession.detach_player(43)
	t.assert_true(GameSession.get_player_state_by_player_id(PLAYER_C) == canonical_c, "Adventure disconnect retains C canonical state")
	t.assert_equal(GameSession.get_player_world_id(PLAYER_C), &"settlement", "Adventure disconnect resets C detached world to Settlement")
	t.assert_true(session.get_player_adventure(43) == null, "Adventure disconnect forfeits C runtime participation")
	GameSession.remove_player_state(PLAYER_B)
	GameSession.remove_player_state(PLAYER_C)
	GameSession.start_new_game()
	GameSession.attach_player(43, PLAYER_C)
	var local_peer := GameSession.get_local_peer_id()
	t.assert_true(GameSession.begin_player_adventure(local_peer, &"sewer_gate", &"sewer_region").success, "local compatibility facade follows the local Adventure participant")
	t.assert_true(GameSession.begin_player_adventure(43, &"sewer_gate", &"sewer_region").success, "remote C can share the local region session")
	var shared_session := GameSession.adventure.active_session
	t.assert_true(shared_session != null, "active_session facade represents the local player's Adventure")
	t.assert_true(GameSession.finish_player_adventure(local_peer, AdventureSession.Result.NORMAL_ESCAPE).success, "local player returns while C remains")
	t.assert_true(GameSession.adventure.active_session == null, "active_session facade clears when the local player returns")
	t.assert_equal(GameSession.get_peer_world_id(43), &"adventure:sewer_region", "clearing the local facade does not finish C's Adventure")
	GameSession.detach_player(43)
	GameSession.remove_player_state(PLAYER_C)
	GameSession.start_new_game()
