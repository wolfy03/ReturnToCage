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
	_test_pending_loot_transaction(t, start)
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
	snapshot.pending_loot = [ItemStack.new(&"berry", 2)]
	var parsed := SettlementStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry)
	t.assert_true(parsed.error_message.is_empty(), "valid settlement snapshot round-trips")
	t.assert_equal(parsed.storage.size(), 1, "settlement snapshot contains the canonical storage stack")
	t.assert_equal(parsed.storage[0].item_id, &"mushroom_stew", "settlement snapshot preserves stable item IDs")
	t.assert_equal(parsed.pending_loot[0].quantity, 2, "settlement snapshot preserves pending loot")
	var mirror := SettlementState.new(Callable(ContentRegistry, "get_item"), Callable(self, "_deny_mutation"))
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition
	mirror.reset(start, ContentRegistry)
	mirror.revision = -1
	t.assert_true(mirror.apply_network_mirror(parsed), "new settlement mirror revision applies")
	t.assert_equal(mirror.storage.count(&"mushroom_stew"), 1, "client storage mirror matches authoritative snapshot")
	t.assert_equal(mirror.pending_loot[0].quantity, 2, "client pending loot mirror matches authoritative snapshot")
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
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = null
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "pending loot must be an array")
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = [{"item_id": "missing_item", "quantity": 1, "instance_id": "", "durability": -1}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "unknown pending loot item is rejected")
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = [{"item_id": "berry", "quantity": -1, "instance_id": "", "durability": -1}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "negative pending loot quantity is rejected")
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = [{"item_id": "berry", "quantity": 11, "instance_id": "", "durability": -1}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "oversized pending loot stack is rejected")
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = [{"item_id": "leaf_vest", "quantity": 1, "instance_id": "bad_durability", "durability": 46}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "invalid pending loot durability is rejected")
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = [{"item_id": "leaf_vest", "quantity": 2, "instance_id": "bad_quantity", "durability": 45}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "instance pending loot quantity must be one")
	malformed = snapshot.to_payload()
	malformed["pending_loot"] = [
		{"item_id": "leaf_vest", "quantity": 1, "instance_id": "duplicate_pending", "durability": 45},
		{"item_id": "leaf_vest", "quantity": 1, "instance_id": "duplicate_pending", "durability": 45},
	]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "duplicate instance within pending loot is rejected")
	malformed = snapshot.to_payload()
	malformed["storage"] = [{"item_id": "leaf_vest", "quantity": 1, "instance_id": "cross_container", "durability": 45}]
	malformed["pending_loot"] = [{"item_id": "leaf_vest", "quantity": 1, "instance_id": "cross_container", "durability": 45}]
	t.assert_true(not SettlementStateSnapshot.from_payload(malformed, ContentRegistry).error_message.is_empty(), "storage and pending loot cannot share an instance ID")

func _test_pending_loot_transaction(t: Node, start: GameStartDefinition) -> void:
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	settlement.reset(start, ContentRegistry)
	settlement.storage.capacity = 1
	settlement.storage.add_item(&"berry", 10)
	var before_failure := settlement.revision
	var invalid := settlement.secure_loot([ItemStack.new(&"berry", 11)])
	t.assert_true(not invalid.success, "invalid overflow stack is rejected before pending mutation")
	t.assert_equal(settlement.revision, before_failure, "invalid overflow stack creates no revision")
	var secured := settlement.secure_loot([ItemStack.new(&"water_drop", 1)])
	t.assert_true(not secured.success, "storage-full secure operation moves loot to pending")
	t.assert_equal(settlement.pending_loot.size(), 1, "failed secure retains canonical pending loot")
	t.assert_equal(settlement.revision, before_failure + 1, "secure failure bumps settlement revision once")

	var failed_claim_revision := settlement.revision
	var failed_claim_state := settlement.to_save_dict()
	t.assert_true(not settlement.claim_pending_loot().success, "pending claim fails while storage remains full")
	t.assert_equal(settlement.revision, failed_claim_revision, "failed pending claim does not bump revision")
	t.assert_equal(settlement.to_save_dict(), failed_claim_state, "failed pending claim changes neither container")

	settlement.storage.capacity = 2
	var before_claim := settlement.revision
	t.assert_true(settlement.claim_pending_loot().success, "pending claim succeeds after capacity is available")
	t.assert_true(settlement.pending_loot.is_empty(), "successful claim clears pending loot")
	t.assert_equal(settlement.storage.count(&"water_drop"), 1, "successful claim transfers pending loot into storage")
	t.assert_equal(settlement.revision, before_claim + 1, "storage addition and pending removal share one revision")
	var after_claim := settlement.revision
	t.assert_true(settlement.claim_pending_loot().success, "empty pending claim keeps compatibility success semantics")
	t.assert_equal(settlement.revision, after_claim, "empty pending claim creates no revision")

	settlement.storage.capacity = 2
	var before_nested := settlement.revision
	settlement.begin_update()
	settlement.secure_loot([ItemStack.new(&"moss_fiber", 1)])
	settlement.end_update()
	t.assert_equal(settlement.revision, before_nested + 1, "nested secure batching commits one revision")

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
	var snapshot := SettlementStateSnapshot.from_state(authoritative)
	snapshot.pending_loot = [ItemStack.new(&"berry", 2)]
	t.assert_true(mirror.apply_network_mirror(snapshot), "validated snapshot bypasses only the mirror mutation guard")
	var exposed := mirror.pending_loot
	exposed.clear()
	var exposed_stack := mirror.pending_loot[0]
	exposed_stack.quantity = 999
	t.assert_equal(mirror.pending_loot.size(), 1, "client clearing a pending loot copy does not mutate the mirror")
	t.assert_equal(mirror.pending_loot[0].quantity, 2, "client pending loot ItemStacks are deep copied")
	t.assert_true(not mirror.secure_loot([ItemStack.new(&"berry", 1)]).success, "client cannot mutate pending loot through secure API")

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
	GameSession.settlement.storage.capacity = 1
	GameSession.settlement.storage.add_item(&"berry", 10)
	var context := AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", &"normal", GameSession.session_id)
	GameSession.adventure.active_session = AdventureSession.new(context, Callable(ContentRegistry, "get_item"))
	var peer_id := GameSession.get_local_peer_id()
	GameSession.adventure.active_session.register_player(peer_id, Callable(ContentRegistry, "get_item"))
	GameSession.adventure.active_session.get_player_adventure(peer_id).unsecured_loot.add_item(&"water_drop", 1)
	var revision_before := GameSession.settlement.revision
	GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_equal(GameSession.settlement.storage.count(&"water_drop"), 0, "storage-full adventure finish does not partially secure loot")
	t.assert_equal(GameSession.settlement.pending_loot[0].item_id, &"water_drop", "storage-full adventure finish retains loot in pending")
	t.assert_equal(GameSession.settlement.revision, revision_before + 1, "adventure finish pending mutation bumps settlement revision")

func _record_event(event: GameplayEvent) -> void:
	_events.append(event)

func _deny_mutation() -> bool:
	return false

func _cleanup() -> void:
	for id in _test_ids:
		ContentRegistry._definitions.erase(id)
	_test_ids.clear()
	_events.clear()
