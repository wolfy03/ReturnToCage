extends RefCounted

func run(t: Node) -> void:
	var start := ContentRegistry.get_definition(GameSession.DEFAULT_START_ID) as GameStartDefinition
	_test_pending_encapsulation(t, start)
	_test_item_transactions(t, start)
	_test_snapshot_boundary(t, start)
	_test_transfer_transactions(t, start)

func _test_pending_encapsulation(t: Node, start: GameStartDefinition) -> void:
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	settlement.reset(start, ContentRegistry)
	settlement.storage.capacity = 0
	settlement.secure_loot([ItemStack.new(&"berry", 2)])
	var exposed := settlement.pending_loot
	exposed[0].quantity = 999
	exposed.clear()
	t.assert_equal(settlement.pending_loot.size(), 1, "authoritative pending getter never exposes its backing array")
	t.assert_equal(settlement.pending_loot[0].quantity, 2, "authoritative pending getter deep copies ItemStacks")

func _test_item_transactions(t: Node, start: GameStartDefinition) -> void:
	var service := PlayerItemCommandService.new(ContentRegistry)
	var legacy := PlayerState.new(Callable(ContentRegistry, "get_item"))
	legacy.reset(start, ContentRegistry)
	t.assert_true(service.try_unequip(legacy, EquipmentDefinition.EquipmentSlot.MAIN_HAND).success, "legacy Save v3 equipment can be unequipped")
	t.assert_true(not legacy.inventory.stacks()[3].instance_id.is_empty(), "unequip assigns stable identity at the command boundary")
	var player := PlayerState.new(Callable(ContentRegistry, "get_item"))
	player.reset(start, ContentRegistry)
	var protected_revision := player.item_state_revision
	t.assert_true(player.protected_inventory.add_item(&"berry", 1).success, "protected inventory accepts authoritative mutation")
	t.assert_equal(player.item_state_revision, protected_revision + 1, "protected inventory participates in the private item revision")
	player.inventory.capacity = 2
	player.inventory.initialize([_instance(&"leaf_vest", "vest_a", 45), _instance(&"leaf_vest", "vest_b", 45)])
	player.equipment.restore({})
	var revision := player.item_state_revision
	t.assert_true(service.try_equip(player, "vest_a").success, "instance equipment equips from canonical inventory")
	t.assert_equal(player.item_state_revision, revision + 1, "equip inventory/equipment transaction bumps one revision")
	t.assert_equal(player.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY).instance_id, "vest_a", "equip resolves slot from server definition")
	t.assert_equal(player.inventory.stacks().size(), 1, "equipped instance leaves inventory")
	revision = player.item_state_revision
	t.assert_true(service.try_equip(player, "vest_b").success, "equipment replacement succeeds atomically")
	t.assert_equal(player.item_state_revision, revision + 1, "replacement produces one item revision")
	t.assert_equal(player.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY).instance_id, "vest_b", "replacement installs requested instance")
	t.assert_equal(player.inventory.stacks()[0].instance_id, "vest_a", "replacement returns old equipment to inventory")

	player.inventory.capacity = 1
	revision = player.item_state_revision
	var before_inventory := player.inventory.to_array()
	var before_equipment := player.equipment.to_dict()
	t.assert_true(not service.try_unequip(player, EquipmentDefinition.EquipmentSlot.BODY).success, "unequip fails when inventory has no slot")
	t.assert_equal(player.inventory.to_array(), before_inventory, "failed unequip leaves inventory unchanged")
	t.assert_equal(player.equipment.to_dict(), before_equipment, "failed unequip leaves equipment unchanged")
	t.assert_equal(player.item_state_revision, revision, "failed unequip creates no revision")
	player.inventory.capacity = 2
	t.assert_true(service.try_unequip(player, EquipmentDefinition.EquipmentSlot.BODY).success, "unequip succeeds when inventory has capacity")
	t.assert_equal(player.item_state_revision, revision + 1, "successful unequip bumps one revision")

	player.inventory.capacity = 2
	player.inventory.initialize([ItemStack.new(&"berry", 2)])
	revision = player.item_state_revision
	t.assert_true(service.try_use_item(player, null, null, &"berry").success, "server item-use service consumes a canonical item")
	t.assert_equal(player.inventory.count(&"berry"), 1, "item use consumes exactly one item")
	t.assert_equal(player.item_state_revision, revision + 1, "item use bumps one item revision")
	revision = player.item_state_revision
	t.assert_true(not service.try_use_item(player, null, null, &"missing_item").success, "forged unknown item use is rejected")
	t.assert_equal(player.item_state_revision, revision, "failed item use creates no revision")

func _test_snapshot_boundary(t: Node, start: GameStartDefinition) -> void:
	var source := PlayerState.new(Callable(ContentRegistry, "get_item"))
	source.reset(start, ContentRegistry)
	source.inventory.capacity = 3
	source.inventory.initialize([ItemStack.new(&"berry", 2), _instance(&"leaf_vest", "inventory_vest", 45)])
	source.protected_inventory.initialize([_instance(&"leaf_vest", "protected_vest", 45)])
	source.equipment.restore({})
	var equipped := _instance(&"twig_sword", "equipped_sword", 60)
	source.equipment.equip(equipped)
	var snapshot := PlayerItemStateSnapshot.from_state(&"player_b", source)
	var parsed := PlayerItemStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry, &"player_b")
	t.assert_true(parsed.error_message.is_empty(), "valid player item snapshot round-trips")
	t.assert_equal(parsed.inventory.size(), 2, "item snapshot contains private inventory")
	t.assert_equal(parsed.protected_inventory[0].instance_id, "protected_vest", "item snapshot contains protected inventory")
	t.assert_equal(parsed.equipment[EquipmentDefinition.EquipmentSlot.MAIN_HAND].instance_id, "equipped_sword", "item snapshot contains equipment identity")
	t.assert_true(not PlayerItemStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry, &"player_a").error_message.is_empty(), "owner-spoofed item snapshot is rejected")

	var mirror := PlayerState.new(Callable(ContentRegistry, "get_item"), Callable(self, "_deny_mutation"))
	mirror.reset(start, ContentRegistry)
	mirror.prepare_network_item_mirror()
	t.assert_equal(mirror.item_state_revision, -1, "uninitialized client item mirror accepts the initial revision-zero snapshot")
	t.assert_true(mirror.inventory.stacks().is_empty(), "client placeholder inventory is cleared before its owner snapshot")
	t.assert_true(mirror.protected_inventory.stacks().is_empty(), "client placeholder protected inventory is not exposed")
	t.assert_true(mirror.equipment.all_equipped().is_empty(), "client placeholder equipment is cleared before its owner snapshot")
	t.assert_true(mirror.apply_item_network_mirror(parsed), "new owner item snapshot applies to a client mirror")
	t.assert_true(not mirror.apply_item_network_mirror(parsed), "equal item revision is rejected as stale")
	var stale := PlayerItemStateSnapshot.from_payload(snapshot.to_payload(), ContentRegistry, &"player_b")
	stale.revision = mirror.item_state_revision - 1
	t.assert_true(not mirror.apply_item_network_mirror(stale), "older item revision is rejected")
	var old_inventory := mirror.inventory.to_array()
	var old_protected := mirror.protected_inventory.to_array()
	var old_equipment := mirror.equipment.to_dict()
	var old_capacity := mirror.inventory.capacity
	mirror.inventory.capacity = old_capacity + 10
	t.assert_true(not mirror.inventory.add_item(&"berry", 1).success, "client inventory mirror rejects direct add")
	t.assert_true(not mirror.inventory.remove_item(&"berry", 1).success, "client inventory mirror rejects direct remove")
	t.assert_true(not mirror.inventory.exchange([], [ItemStack.new(&"berry", 1)]).success, "client inventory mirror rejects exchange")
	mirror.equipment.equip(_instance(&"leaf_vest", "forged", 45))
	mirror.equipment.unequip(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	mirror.protected_inventory.add_item(&"berry", 1)
	mirror.protected_inventory.remove_item(&"leaf_vest", 1)
	t.assert_equal(mirror.inventory.to_array(), old_inventory, "client inventory remains unchanged after direct mutation attempts")
	t.assert_equal(mirror.inventory.capacity, old_capacity, "client inventory capacity is read-only")
	t.assert_equal(mirror.equipment.to_dict(), old_equipment, "client equipment remains unchanged after direct mutation attempts")
	t.assert_equal(mirror.protected_inventory.to_array(), old_protected, "client protected inventory remains read-only")
	var newer_payload := snapshot.to_payload()
	newer_payload["revision"] = mirror.item_state_revision + 1
	var newer := PlayerItemStateSnapshot.from_payload(newer_payload, ContentRegistry, &"player_b")
	t.assert_true(mirror.apply_item_network_mirror(newer), "newer item revision is accepted")

	var malformed := snapshot.to_payload()
	malformed["inventory_capacity"] = 0
	_assert_invalid(t, malformed, "invalid inventory capacity is rejected")
	malformed = snapshot.to_payload()
	malformed["protected_capacity"] = -1
	_assert_invalid(t, malformed, "negative protected capacity is rejected")
	malformed = snapshot.to_payload()
	malformed["protected_inventory"] = [_instance(&"leaf_vest", "inventory_vest", 45).to_dict()]
	_assert_invalid(t, malformed, "inventory and protected inventory cannot share an instance")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [{"item_id": "missing", "quantity": 1, "instance_id": "", "durability": -1}]
	_assert_invalid(t, malformed, "unknown inventory item is rejected")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [{"item_id": "berry", "quantity": 11, "instance_id": "", "durability": -1}]
	_assert_invalid(t, malformed, "inventory quantity above max stack is rejected")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [{"item_id": "berry", "quantity": 0, "instance_id": "", "durability": -1}]
	_assert_invalid(t, malformed, "non-positive inventory quantity is rejected")
	malformed = snapshot.to_payload()
	malformed["inventory_capacity"] = 1
	malformed["inventory"] = [ItemStack.new(&"berry", 1).to_dict(), ItemStack.new(&"water_drop", 1).to_dict()]
	_assert_invalid(t, malformed, "inventory stack count above capacity is rejected")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [{"item_id": "leaf_vest", "quantity": 1, "instance_id": "bad_durability", "durability": 46}]
	_assert_invalid(t, malformed, "invalid inventory durability is rejected")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [{"item_id": "leaf_vest", "quantity": 2, "instance_id": "bad_quantity", "durability": 45}]
	_assert_invalid(t, malformed, "instance inventory quantity must be one")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [
		{"item_id": "leaf_vest", "quantity": 1, "instance_id": "dup", "durability": 45},
		{"item_id": "leaf_vest", "quantity": 1, "instance_id": "dup", "durability": 45},
	]
	_assert_invalid(t, malformed, "duplicate inventory instance is rejected")
	malformed = snapshot.to_payload()
	malformed["equipment"] = [{"slot": 99, "stack": equipped.to_dict()}]
	_assert_invalid(t, malformed, "invalid equipment slot is rejected")
	malformed = snapshot.to_payload()
	malformed["equipment"] = [{"slot": EquipmentDefinition.EquipmentSlot.BODY, "stack": ItemStack.new(&"berry", 1).to_dict()}]
	_assert_invalid(t, malformed, "non-equipment item in equipment is rejected")
	malformed = snapshot.to_payload()
	malformed["equipment"] = [{"slot": EquipmentDefinition.EquipmentSlot.MAIN_HAND, "stack": _instance(&"leaf_vest", "wrong_slot", 45).to_dict()}]
	_assert_invalid(t, malformed, "equipment definition must match its slot")
	malformed = snapshot.to_payload()
	malformed["equipment"] = [
		{"slot": EquipmentDefinition.EquipmentSlot.BODY, "stack": _instance(&"leaf_vest", "dup_slot_a", 45).to_dict()},
		{"slot": EquipmentDefinition.EquipmentSlot.BODY, "stack": _instance(&"leaf_vest", "dup_slot_b", 45).to_dict()},
	]
	_assert_invalid(t, malformed, "duplicate equipment slot is rejected")
	malformed = snapshot.to_payload()
	malformed["inventory"] = [_instance(&"twig_sword", "cross", 60).to_dict()]
	malformed["equipment"] = [{"slot": EquipmentDefinition.EquipmentSlot.MAIN_HAND, "stack": _instance(&"twig_sword", "cross", 60).to_dict()}]
	_assert_invalid(t, malformed, "inventory and equipment cannot share an instance")

	var replication := PlayerItemReplicationService.new()
	var test_peer := 987654320
	PlayerItemReplicationService._last_command_sequences.erase(test_peer)
	t.assert_true(replication._accept_sequence(test_peer, 1), "first player item command sequence is accepted")
	t.assert_true(not replication._accept_sequence(test_peer, 1), "duplicate player item command sequence is rejected")
	t.assert_true(not replication._accept_sequence(test_peer, 0), "malformed player item command sequence is rejected")
	t.assert_true(replication._accept_sequence(test_peer, 2), "newer player item command sequence is accepted")
	PlayerItemReplicationService._last_command_sequences.erase(test_peer)
	replication.free()

func _test_transfer_transactions(t: Node, start: GameStartDefinition) -> void:
	var player := PlayerState.new(Callable(ContentRegistry, "get_item"))
	player.reset(start, ContentRegistry)
	player.inventory.initialize([ItemStack.new(&"rusty_scrap", 5)])
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	settlement.reset(start, ContentRegistry)
	var service := PlayerItemCommandService.new(ContentRegistry)
	var player_revision := player.item_state_revision
	var settlement_revision := settlement.revision
	t.assert_true(service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.DEPOSIT, &"rusty_scrap", "", 3).success, "stackable deposit succeeds")
	t.assert_equal(player.inventory.count(&"rusty_scrap"), 2, "deposit removes only requested player quantity")
	t.assert_equal(settlement.storage.count(&"rusty_scrap"), 3, "deposit adds requested shared quantity")
	t.assert_equal(player.item_state_revision, player_revision + 1, "deposit bumps player revision once")
	t.assert_equal(settlement.revision, settlement_revision + 1, "deposit bumps settlement revision once")
	player_revision = player.item_state_revision
	settlement_revision = settlement.revision
	t.assert_true(service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"rusty_scrap", "", 2).success, "stackable withdraw succeeds")
	t.assert_equal(player.inventory.count(&"rusty_scrap"), 4, "withdraw adds requested player quantity")
	t.assert_equal(settlement.storage.count(&"rusty_scrap"), 1, "withdraw removes requested shared quantity")
	t.assert_equal(player.item_state_revision, player_revision + 1, "withdraw bumps player revision once")
	t.assert_equal(settlement.revision, settlement_revision + 1, "withdraw bumps settlement revision once")
	player_revision = player.item_state_revision
	settlement_revision = settlement.revision
	var player_before := player.inventory.to_array()
	var storage_before := settlement.storage.to_array()
	t.assert_true(not service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"rusty_scrap", "", 4).success, "insufficient concurrent-style withdraw is rejected")
	t.assert_equal(player.inventory.to_array(), player_before, "failed withdraw leaves player inventory unchanged")
	t.assert_equal(settlement.storage.to_array(), storage_before, "failed withdraw leaves settlement storage unchanged")
	t.assert_equal(player.item_state_revision, player_revision, "failed withdraw leaves player revision unchanged")
	t.assert_equal(settlement.revision, settlement_revision, "failed withdraw leaves settlement revision unchanged")
	var legacy_player := PlayerState.new(Callable(ContentRegistry, "get_item"))
	legacy_player.reset(start, ContentRegistry)
	legacy_player.inventory.initialize([])
	var legacy_settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	legacy_settlement.reset(start, ContentRegistry)
	legacy_settlement.storage.initialize([ItemStack.new(&"leaf_vest", 1)])
	t.assert_true(service.try_transfer(legacy_player, legacy_settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"leaf_vest", "", 1).success, "legacy storage equipment can be withdrawn by item intent")
	t.assert_true(not legacy_player.inventory.stacks()[0].instance_id.is_empty(), "legacy equipment receives identity when crossing into player ownership")

	player.inventory.initialize([_instance(&"leaf_vest", "shared_instance", 45)])
	settlement.storage.initialize([_instance(&"leaf_vest", "shared_instance", 45)])
	player_revision = player.item_state_revision
	settlement_revision = settlement.revision
	t.assert_true(not service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.DEPOSIT, &"leaf_vest", "shared_instance", 1).success, "cross-container duplicate instance deposit is rejected")
	t.assert_equal(player.item_state_revision, player_revision, "duplicate instance rejection leaves player revision unchanged")
	t.assert_equal(settlement.revision, settlement_revision, "duplicate instance rejection leaves settlement revision unchanged")

	var race_settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	race_settlement.reset(start, ContentRegistry)
	race_settlement.storage.initialize([_instance(&"leaf_vest", "race_vest", 45)])
	var racer_a := PlayerState.new(Callable(ContentRegistry, "get_item"))
	var racer_b := PlayerState.new(Callable(ContentRegistry, "get_item"))
	racer_a.reset(start, ContentRegistry)
	racer_b.reset(start, ContentRegistry)
	racer_a.inventory.initialize([])
	racer_b.inventory.initialize([])
	t.assert_true(service.try_transfer(racer_a, race_settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"leaf_vest", "race_vest", 1).success, "first equipment instance claimant succeeds")
	t.assert_true(not service.try_transfer(racer_b, race_settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"leaf_vest", "race_vest", 1).success, "second equipment instance claimant loses the race")
	t.assert_equal(racer_a.inventory.stacks()[0].instance_id, "race_vest", "equipment instance has exactly one player owner")
	t.assert_true(racer_b.inventory.stacks().is_empty() and race_settlement.storage.stacks().is_empty(), "equipment claim race conserves one canonical instance")

func _assert_invalid(t: Node, payload: Dictionary, message: String) -> void:
	t.assert_true(not PlayerItemStateSnapshot.from_payload(payload, ContentRegistry, &"player_b").error_message.is_empty(), message)

func _instance(item_id: StringName, instance_id: String, durability: int) -> ItemStack:
	var stack := ItemStack.new(item_id, 1)
	stack.instance_id = instance_id
	stack.durability = durability
	return stack

func _deny_mutation() -> bool:
	return false
