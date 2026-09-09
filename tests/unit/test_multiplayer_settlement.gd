extends RefCounted

var _events: Array[GameplayEvent] = []
var _test_ids: Array[StringName] = []

func run(t: Node) -> void:
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	var progression := ProgressionState.new()
	settlement.reset(start, ContentRegistry)
	progression.reset(start)
	var service := SettlementCommandService.new(
		settlement,
		progression,
		ContentRegistry,
		Callable(self, "_record_event")
	)

	_test_upgrade_transaction(t, settlement, progression, service)
	_test_craft_transaction(t, settlement, progression, service)
	_test_settlement_snapshot(t, settlement)
	_test_shared_progression_snapshot(t, progression)
	_test_read_only_mirror(t, start, settlement)
	_test_shared_reward_revision(t, start)
	_test_adventure_finish_revision(t)
	_test_command_boundary(t)
	_cleanup()

func _test_upgrade_transaction(
	t: Node,
	settlement: SettlementState,
	progression: ProgressionState,
	service: SettlementCommandService
) -> void:
	settlement.storage.add_item(&"rusty_scrap", 3)
	var before_revision := settlement.revision
	var first := service.try_upgrade_facility(&"workbench", &"player_b")
	var second := service.try_upgrade_facility(&"workbench", &"player_a")
	var unknown := service.try_upgrade_facility(&"missing_facility", &"player_a")
	t.assert_true(first.success, "server settlement command upgrades a valid facility")
	t.assert_true(not second.success, "simultaneous same-level facility upgrade cannot commit twice")
	t.assert_true(not unknown.success, "unknown facility intent is rejected")
	t.assert_equal(settlement.facility_levels.get(&"workbench", 0), 1, "facility commits exactly one next level")
	t.assert_equal(settlement.storage.count(&"rusty_scrap"), 0, "facility cost is consumed exactly once")
	t.assert_equal(settlement.revision, before_revision + 1, "cost and facility level produce one settlement revision")
	t.assert_equal(progression.shared_revision, 1, "facility unlock produces one shared progression revision")
	t.assert_true(progression.unlocked_flags.has(&"basic_crafting"), "facility unlock is committed server-side")
	t.assert_equal(_events.size(), 1, "successful facility command reports one quest event")
	t.assert_equal(_events[0].actor_player_id, &"player_b", "facility quest event preserves server-resolved initiator")

func _test_craft_transaction(
	t: Node,
	settlement: SettlementState,
	progression: ProgressionState,
	service: SettlementCommandService
) -> void:
	settlement.storage.add_item(&"berry", 2)
	settlement.storage.add_item(&"moss_fiber", 1)
	var before_revision := settlement.revision
	var first := service.try_craft(&"stew_recipe", &"player_a")
	var second := service.try_craft(&"stew_recipe", &"player_b")
	var unknown := service.try_craft(&"missing_recipe", &"player_b")
	t.assert_true(first.success, "first concurrent craft transaction succeeds")
	t.assert_true(not second.success, "second concurrent craft transaction fails after resources are consumed")
	t.assert_true(not unknown.success, "unknown recipe intent is rejected")
	t.assert_equal(settlement.storage.count(&"berry"), 0, "craft input is not double-consumed")
	t.assert_equal(settlement.storage.count(&"moss_fiber"), 0, "all craft inputs commit atomically")
	t.assert_equal(settlement.storage.count(&"mushroom_stew"), 1, "craft output is not duplicated")
	t.assert_equal(settlement.revision, before_revision + 1, "successful craft bumps settlement revision once")

func _test_settlement_snapshot(t: Node, settlement: SettlementState) -> void:
	var snapshot := SettlementStateSnapshot.from_state(settlement)
	var parsed := SettlementStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry)
	t.assert_true(parsed.error_message.is_empty(), "valid settlement snapshot round-trips")
	t.assert_equal(parsed.storage.size(), 1, "settlement snapshot contains the canonical storage stack")
	t.assert_equal(parsed.storage[0].item_id, &"mushroom_stew", "settlement snapshot preserves stable item IDs")
	var mirror := SettlementState.new(Callable(ContentRegistry, "get_item"), Callable(self, "_deny_mutation"))
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition
	mirror.reset(start, ContentRegistry)
	mirror.revision = -1
	t.assert_true(mirror.apply_network_mirror(parsed), "new settlement mirror revision applies")
	t.assert_equal(mirror.storage.count(&"mushroom_stew"), 1, "client storage mirror matches authoritative snapshot")
	t.assert_true(not mirror.apply_network_mirror(parsed), "equal settlement revision is rejected as stale")

	var malformed := snapshot.to_payload()
	malformed["storage"] = [{"item_id": "missing_item", "quantity": 1, "instance_id": "", "durability": 0}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "unknown storage item is rejected")
	malformed = snapshot.to_payload()
	malformed["facility_levels"] = [
		{"facility_id": "workbench", "level": 1},
		{"facility_id": "workbench", "level": 1},
	]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "duplicate facility snapshot record is rejected")
	malformed = snapshot.to_payload()
	malformed["facility_levels"] = [{"facility_id": "workbench", "level": 999}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "facility level above definition maximum is rejected")
	malformed = snapshot.to_payload()
	malformed["storage"] = [{"item_id": "berry", "quantity": -1, "instance_id": "", "durability": -1}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "negative storage quantity is rejected")
	malformed = snapshot.to_payload()
	malformed["storage"] = [
		{"item_id": "leaf_vest", "quantity": 1, "instance_id": "duplicate", "durability": 100},
		{"item_id": "leaf_vest", "quantity": 1, "instance_id": "duplicate", "durability": 100},
	]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "duplicate storage instance ID is rejected")

func _test_shared_progression_snapshot(t: Node, progression: ProgressionState) -> void:
	var snapshot := SharedProgressionSnapshot.from_state(progression)
	var parsed := SharedProgressionSnapshot.from_payload(snapshot.to_payload(), ContentRegistry)
	t.assert_true(parsed.error_message.is_empty(), "valid shared progression snapshot round-trips")
	var mirror := ProgressionState.new()
	mirror.set_mutation_guard(Callable(self, "_deny_mutation"))
	mirror.reset(ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition)
	mirror.shared_revision = -1
	t.assert_true(mirror.apply_shared_network_mirror(parsed), "new shared progression mirror revision applies")
	t.assert_true(not mirror.apply_shared_network_mirror(parsed), "equal shared progression revision is rejected")
	mirror.unlocked_flags.append(&"client_forgery")
	t.assert_true(not mirror.unlocked_flags.has(&"client_forgery"), "client shared progression arrays expose read-only copies")
	var malformed := snapshot.to_payload()
	malformed["unlocked_regions"] = ["missing_region"]
	t.assert_true(not SharedProgressionSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "unknown shared progression region is rejected")
	malformed = snapshot.to_payload()
	malformed["unlocked_flags"] = ["basic_crafting", "basic_crafting"]
	t.assert_true(not SharedProgressionSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "duplicate shared progression identity is rejected")

func _test_read_only_mirror(t: Node, start: GameStartDefinition, authoritative: SettlementState) -> void:
	var mirror := SettlementState.new(Callable(ContentRegistry, "get_item"), Callable(self, "_deny_mutation"))
	mirror.reset(start, ContentRegistry)
	var denied := mirror.storage.add_item(&"berry", 1)
	t.assert_true(not denied.success and mirror.storage.count(&"berry") == 0, "client shared storage rejects direct mutation")
	mirror.facility_levels[&"workbench"] = 1
	t.assert_equal(mirror.facility_levels.get(&"workbench", 0), 0, "client facility dictionary exposes a read-only copy")
	mirror.revision = -1
	t.assert_true(mirror.apply_network_mirror(SettlementStateSnapshot.from_state(authoritative)), "validated snapshot bypasses only the mirror mutation guard")

func _test_shared_reward_revision(t: Node, start: GameStartDefinition) -> void:
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	var progression := ProgressionState.new()
	settlement.reset(start, ContentRegistry)
	progression.reset(start)
	var objective := QuestObjectiveDefinition.new()
	objective.type = QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM
	objective.target_id = &"berry"
	objective.required_amount = 1
	var quest := QuestDefinition.new()
	quest.id = &"_test_settlement_reward"
	quest.title = "Settlement reward"
	quest.scope = QuestDefinition.Scope.PARTY
	quest.objectives = [objective]
	quest.reward_item_ids = [&"berry"]
	quest.reward_amounts = [1]
	ContentRegistry._definitions[quest.id] = quest
	_test_ids.append(quest.id)
	var system := QuestSystem.new(progression, settlement, ContentRegistry, Callable())
	t.assert_true(system.start_quest(quest.id, &"player_a").success, "shared reward fixture quest starts")
	system.report(GameplayEvent.collect_item(&"player_a", &"berry", 1))
	var before_revision := settlement.revision
	t.assert_true(system.claim_reward(quest.id, &"player_a").success, "PARTY reward commits to shared storage")
	t.assert_equal(settlement.revision, before_revision + 1, "PARTY reward storage mutation bumps settlement revision")

func _test_command_boundary(t: Node) -> void:
	var replication := SettlementReplicationService.new()
	var test_peer := 987654321
	SettlementReplicationService._last_command_sequences.erase(test_peer)
	t.assert_true(replication._accept_sequence(test_peer, 1), "first settlement command sequence is accepted")
	t.assert_true(not replication._accept_sequence(test_peer, 1), "duplicate settlement command sequence is rejected")
	t.assert_true(not replication._accept_sequence(test_peer, 0), "malformed settlement command sequence is rejected")
	t.assert_true(replication._accept_sequence(test_peer, 2), "newer settlement command sequence is accepted")
	SettlementReplicationService._last_command_sequences.erase(test_peer)
	replication.free()

	GameSession.start_new_game()
	GameSession._phase = GameSession.Phase.ADVENTURE
	var before_revision := GameSession.settlement.revision
	var result := GameSession.execute_craft_command(&"stew_recipe", GameSession.get_local_player_id())
	t.assert_true(not result.success, "craft command is rejected during adventure")
	t.assert_equal(GameSession.settlement.revision, before_revision, "rejected adventure craft leaves revision unchanged")
	GameSession._phase = GameSession.Phase.SETTLEMENT

func _test_adventure_finish_revision(t: Node) -> void:
	GameSession.start_new_game()
	var context := AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", &"normal", GameSession.session_id)
	GameSession.adventure.active_session = AdventureSession.new(context, Callable(ContentRegistry, "get_item"))
	var peer_id := GameSession.get_local_peer_id()
	GameSession.adventure.active_session.register_player(peer_id, Callable(ContentRegistry, "get_item"))
	GameSession.adventure.active_session.get_player_adventure(peer_id).unsecured_loot.add_item(&"berry", 1)
	var storage_before := GameSession.settlement.storage.count(&"berry")
	var revision_before := GameSession.settlement.revision
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_equal(GameSession.settlement.storage.count(&"berry"), storage_before + 1, "party adventure finish secures personal loot into shared storage")
	t.assert_equal(GameSession.settlement.revision, revision_before + 1, "adventure finish storage mutation bumps settlement revision")

func _record_event(event: GameplayEvent) -> void:
	_events.append(event)

func _deny_mutation() -> bool:
	return false

func _cleanup() -> void:
	for id in _test_ids:
		ContentRegistry._definitions.erase(id)
	_test_ids.clear()
	_events.clear()
