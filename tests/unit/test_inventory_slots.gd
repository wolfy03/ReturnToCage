extends RefCounted

func run(t: Node) -> void:
	var model := InventoryModel.new(6, Callable(ContentRegistry, "get_item"))
	var available := true
	for method in [&"get_slot", &"slots", &"move_slot", &"swap_slots", &"merge_slots", &"split_stack", &"sort_slots", &"resize_capacity", &"expand_capacity", &"transfer_to"]:
		var exists := model.has_method(method)
		t.assert_true(exists, "fixed-slot API exists: %s" % method)
		available = available and exists
	if not available:
		return
	_test_layout(t, model)
	_test_merging(t)
	_test_instances(t)
	_test_capacity(t)
	_test_transactions(t)
	_test_guards(t)
	_test_legacy_boundaries(t)
	_test_invalid_content(t)
	_test_death_layout(t)
	_test_save_and_wire_limits(t)
	_test_conservation(t)

func _model(capacity: int) -> InventoryModel:
	return InventoryModel.new(capacity, Callable(ContentRegistry, "get_item"))

func _layout(model: InventoryModel) -> Array:
	var result: Array = []
	for index in model.capacity:
		var stack: ItemStack = model.call("get_slot", index)
		result.append(stack.to_dict() if stack != null else null)
	return result

func _test_layout(t: Node, model: InventoryModel) -> void:
	t.assert_equal(model.call("slots").size(), 6, "capacity includes every empty slot")
	t.assert_true(model.stacks().is_empty(), "legacy stacks stays dense and excludes empty cells")
	t.assert_true(model.call("get_slot", -1) == null and model.call("get_slot", 6) == null, "out-of-range queries are safe")
	model.add_item(&"berry", 6)
	model.add_item(&"water_drop", 2)
	var signals := [0]
	model.changed.connect(func() -> void: signals[0] += 1)
	t.assert_true(model.call("move_slot", 0, 4).success, "move to empty cell succeeds")
	t.assert_true(model.call("get_slot", 0) == null and model.call("get_slot", 4).quantity == 6, "move leaves a stable hole")
	t.assert_equal(signals[0], 1, "slot mutation emits once")
	model.add_item(&"rusty_scrap", 1)
	t.assert_equal(model.call("get_slot", 0).item_id, &"rusty_scrap", "new item finds lowest empty slot")
	t.assert_equal(model.call("get_slot", 1).item_id, &"water_drop", "addition does not slide later items")
	t.assert_true(model.call("move_slot", 4, 1).success, "move onto a different item swaps")
	t.assert_equal(model.call("get_slot", 4).item_id, &"water_drop", "swapped destination lands at source index")
	model.remove_item(&"rusty_scrap", 1)
	t.assert_true(model.call("get_slot", 0) == null and model.call("get_slot", 1).item_id == &"berry", "remove leaves indices intact")
	var before := _layout(model)
	var exposed: Array = model.call("slots")
	exposed[1].quantity = 999
	exposed[1].item_id = &"missing"
	exposed.clear()
	var copy: ItemStack = model.call("get_slot", 1)
	copy.quantity = 999
	var dense := model.stacks()
	dense[0].quantity = 999
	t.assert_equal(_layout(model), before, "all public stack getters are isolated snapshots")
	for pair in [[-1, 1], [1, -1], [6, 0], [0, 6], [2, 3]]:
		var count_before: int = signals[0]
		t.assert_true(not model.call("move_slot", pair[0], pair[1]).success, "invalid or empty-source move fails")
		t.assert_equal(_layout(model), before, "failed move preserves exact holes and data")
		t.assert_equal(signals[0], count_before, "failed move emits nothing")

func _test_merging(t: Node) -> void:
	var model := _model(4)
	model.initialize([ItemStack.new(&"berry", 8), ItemStack.new(&"berry", 5), ItemStack.new(&"water_drop", 1)])
	t.assert_true(model.call("merge_slots", 1, 0).success, "merge fills destination up to max_stack")
	t.assert_equal(model.call("get_slot", 0).quantity, 10, "merge never exceeds max_stack")
	t.assert_equal(model.call("get_slot", 1).quantity, 3, "overflow remains at original source index")
	var before := _layout(model)
	for args in [[1, 0], [1, 2], [1, 1], [-1, 0], [1, 4], [3, 1]]:
		t.assert_true(not model.call("merge_slots", args[0], args[1]).success, "invalid/full/incompatible merge fails")
		t.assert_equal(_layout(model), before, "merge failure is atomic")
	t.assert_true(model.call("split_stack", 0, 3, 4).success, "split into explicit empty slot succeeds")
	t.assert_equal(model.call("get_slot", 0).quantity, 6, "split subtracts exact amount")
	t.assert_equal(model.call("get_slot", 3).quantity, 4, "split installs exact amount at target index")
	before = _layout(model)
	for args in [[0, 1, 1], [0, 3, 1], [0, 0, 1], [0, 4, 1], [0, -1, 1], [0, 1, 0], [0, 1, -1], [0, 1, 7], [0, 1, 6]]:
		t.assert_true(not model.call("split_stack", args[0], args[1], args[2]).success, "full/invalid/oversized split fails")
		t.assert_equal(_layout(model), before, "failed split never consumes or moves items")
	model.clear()
	model.add_item(&"berry", 5)
	t.assert_true(not model.call("split_stack", 0, 1, 5).success, "whole stack uses move instead of split")
	t.assert_true(not model.call("split_stack", 0, 1, 6).success, "split rejects more than available even with empty target")
	var distinct := ItemStack.new(&"berry", 1)
	distinct.durability = 0
	model.add_stack(distinct)
	t.assert_true(not model.call("merge_slots", 0, 1).success, "different metadata cannot merge")
	model.clear()
	model.initialize([ItemStack.new(&"berry", 2), ItemStack.new(&"berry", 3)])
	t.assert_true(model.call("move_slot", 1, 0).success, "move onto compatible stack merges")
	t.assert_true(model.call("get_slot", 1) == null and model.call("get_slot", 0).quantity == 5, "complete merge empties source without compaction")

func _instance(id: String, item_id: StringName = &"twig_sword") -> ItemStack:
	var stack := ItemStack.new(item_id, 1)
	stack.instance_id = id
	stack.durability = 30
	return stack

func _test_instances(t: Node) -> void:
	var model := _model(5)
	var gear := _instance("sword-a")
	model.add_stack(gear)
	model.add_stack(_instance("sword-b"))
	t.assert_true(model.call("swap_slots", 0, 3).success, "explicit swap supports empty cells")
	t.assert_true(model.call("move_slot", 3, 1).success, "equipment instances may exchange positions")
	t.assert_equal(model.call("get_slot", 1).to_dict(), gear.to_dict(), "move preserves equipment identity and durability")
	var before := _layout(model)
	t.assert_true(not model.call("merge_slots", 1, 3).success, "different equipment instance IDs never merge")
	t.assert_true(not model.call("split_stack", 1, 4, 1).success, "equipment instance cannot split")
	t.assert_true(not model.add_stack(gear).success, "duplicate instance cannot be added through a hole")
	var invalid := gear.duplicate_stack()
	invalid.quantity = 2
	t.assert_true(not model.add_stack(invalid).success, "multi-quantity instance is rejected")
	t.assert_true(not model.initialize([gear, gear]).success, "duplicate identity initialization is rejected")
	t.assert_true(not model.initialize([ItemStack.new(&"missing", 1)]).success, "invalid item initialization fails")
	t.assert_true(not model.initialize([ItemStack.new(&"twig_sword", 2)]).success, "equipment slot quantity must be exactly one")
	t.assert_equal(_layout(model), before, "failed instance commands preserve every occupied and empty slot")
	model.clear()
	# Legacy bulk adds remain quantity requests, never multi-quantity equipment cells.
	model.add_item(&"twig_sword", 2)
	for stack in model.stacks():
		t.assert_equal(stack.quantity, 1, "legacy equipment batch occupies separate quantity-one slots")
	t.assert_true(not model.call("merge_slots", 0, 1).success, "anonymous legacy equipment cannot merge")

func _test_capacity(t: Node) -> void:
	var model := _model(4)
	model.add_item(&"berry", 1)
	model.call("move_slot", 0, 3)
	var before := _layout(model)
	t.assert_true(not model.call("resize_capacity", 3).success, "shrink rejects occupied truncated tail")
	model.capacity = 1
	t.assert_equal(model.capacity, 4, "legacy capacity setter cannot truncate items")
	t.assert_equal(_layout(model), before, "rejected shrink keeps indices and contents")
	for invalid in [-1, -2147483648]:
		t.assert_true(not model.call("resize_capacity", invalid).success, "negative capacity is rejected")
	t.assert_true(not model.call("expand_capacity", 0).success and not model.call("expand_capacity", -1).success, "expansion requires a positive increment")
	t.assert_true(not model.call("expand_capacity", 2147483647).success and not model.call("resize_capacity", 2147483647).success, "oversized capacity requests fail before allocation")
	t.assert_true(model.call("expand_capacity", 3).success, "expansion appends empty cells")
	t.assert_equal(model.capacity, 7, "expansion increases total cell count")
	t.assert_equal(model.call("get_slot", 3).quantity, 1, "expansion preserves original index")
	t.assert_true(model.call("swap_slots", 3, 0).success, "move into retained region before shrink")
	t.assert_true(model.call("resize_capacity", 1).success, "empty tail may shrink")
	t.assert_equal(model.capacity, 1, "safe shrink updates slot count")
	t.assert_true(not model.call("resize_capacity", 0).success, "nonempty inventory cannot shrink to zero")
	model.clear()
	t.assert_equal(model.call("slots").size(), 1, "clear retains capacity and empty slots")
	t.assert_true(model.call("resize_capacity", 0).success, "empty inventory may have zero capacity")
	t.assert_true(not model.add_item(&"berry", 1).success, "zero capacity rejects addition")

func _test_transactions(t: Node) -> void:
	var model := _model(4)
	model.initialize([ItemStack.new(&"berry", 10), ItemStack.new(&"water_drop", 1)])
	model.call("move_slot", 1, 3)
	var before := _layout(model)
	t.assert_true(model.preview_exchange([ItemStack.new(&"berry", 10)], [ItemStack.new(&"rusty_scrap", 2)]).success, "craft preview accounts for real free cells")
	t.assert_equal(_layout(model), before, "preview preserves exact positions")
	t.assert_true(not model.exchange([ItemStack.new(&"berry", 10)], [ItemStack.new(&"missing", 1)]).success, "invalid output rejects exchange")
	t.assert_equal(_layout(model), before, "failed exchange restores holes, quantities and indices")
	t.assert_true(model.exchange([ItemStack.new(&"berry", 10)], [ItemStack.new(&"rusty_scrap", 2)]).success, "craft-style exchange reuses a freed input cell")
	t.assert_true(model.call("get_slot", 3).item_id == &"water_drop" and model.call("get_slot", 1) == null, "successful exchange preserves untouched positions")
	var destination := _model(1)
	destination.add_item(&"berry", 10)
	before = _layout(model)
	var other_before := _layout(destination)
	t.assert_true(not model.transfer_to(destination, [ItemStack.new(&"rusty_scrap", 1)], [ItemStack.new(&"rusty_scrap", 1)]).success, "full destination rejects both-owner transaction")
	t.assert_equal(_layout(model), before, "transfer failure preserves source positions")
	t.assert_equal(_layout(destination), other_before, "transfer failure preserves destination")
	destination.clear()
	var observed: Array = []
	model.changed.connect(func() -> void: observed.append(destination.count(&"rusty_scrap")))
	t.assert_true(model.transfer_to(destination, [ItemStack.new(&"rusty_scrap", 1)], [ItemStack.new(&"rusty_scrap", 1)]).success, "paired transfer commits both owners")
	t.assert_equal(observed, [1], "source observers see destination already committed")
	t.assert_equal(model.count(&"rusty_scrap") + destination.count(&"rusty_scrap"), 2, "transfer conserves quantity")
	var start := GameSession.get_start_definition()
	var player := PlayerState.new(Callable(ContentRegistry, "get_item"))
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	player.reset(start, ContentRegistry)
	settlement.reset(start, ContentRegistry)
	player.inventory.call("move_slot", 0, 7)
	var service := PlayerItemCommandService.new(ContentRegistry)
	t.assert_true(service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.DEPOSIT, &"berry", "", 1).success, "storage deposit works with a sparse source")
	t.assert_equal(player.inventory.call("get_slot", 7).quantity, 1, "deposit leaves partial stack at same cell")
	t.assert_true(service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"berry", "", 1).success, "storage withdrawal merges into sparse destination")
	t.assert_equal(player.inventory.call("get_slot", 7).quantity, 2, "withdraw does not compact inventory")
	settlement.storage.initialize([ItemStack.new(&"berry", 1), ItemStack.new(&"moss_fiber", 4), ItemStack.new(&"rusty_scrap", 1)])
	settlement.storage.move_slot(0, 6)
	settlement.storage.move_slot(1, 4)
	settlement.storage.move_slot(2, 7)
	settlement.set_facility_level(&"workbench", 1)
	var recipe := ContentRegistry.get_definition(&"vest_recipe") as RecipeDefinition
	t.assert_true(CraftingService.craft(recipe, settlement, ProgressionState.new()).success, "real crafting service consumes sparse storage materials")
	t.assert_equal(settlement.storage.get_slot(0).item_id, &"leaf_vest", "crafted output uses first available cell")
	t.assert_true(settlement.storage.get_slot(4) == null and settlement.storage.get_slot(7) == null, "craft inputs leave holes at their original cells")
	t.assert_equal(settlement.storage.get_slot(6).item_id, &"berry", "craft does not slide unrelated storage items")
	var crafted := settlement.storage.get_slot(0)
	t.assert_true(not crafted.instance_id.is_empty(), "craft issues equipment identity before publishing shared storage")
	t.assert_true(service.try_transfer(player, settlement, PlayerItemCommandService.TransferDirection.WITHDRAW, &"leaf_vest", crafted.instance_id, 1).success, "crafted equipment transfers out of sparse storage by instance")
	var vest := player.inventory.get_slot(0)
	t.assert_true(vest != null and vest.to_dict() == crafted.to_dict(), "transfer preserves the crafted equipment identity and durability")
	t.assert_true(service.try_equip(player, vest.instance_id).success, "equip resolves an instance in sparse inventory")
	t.assert_equal(player.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY).instance_id, vest.instance_id, "equip preserves transferred identity")
	t.assert_true(player.inventory.get_slot(0) == null and player.inventory.get_slot(7).quantity == 2, "equip preserves empty and unrelated cells")
	t.assert_true(service.try_unequip(player, EquipmentDefinition.EquipmentSlot.BODY).success, "unequip uses a free sparse inventory cell")
	t.assert_equal(player.inventory.get_slot(0).instance_id, vest.instance_id, "unequip preserves identity and uses first hole")
	player.inventory.call("expand_capacity", 4)
	player.inventory.call("move_slot", 0, player.inventory.capacity - 1)
	player.reset(start, ContentRegistry)
	t.assert_equal(player.inventory.capacity, start.inventory_capacity, "New Game resets expanded capacity with replacement data")
	t.assert_equal(player.inventory.call("get_slot", 0).item_id, &"berry", "New Game initializes contiguous legacy items")

func _test_guards(t: Node) -> void:
	var allowed := [true]
	var model := InventoryModel.new(3, Callable(ContentRegistry, "get_item"), func() -> bool: return allowed[0])
	model.add_item(&"berry", 4)
	var before := _layout(model)
	allowed[0] = false
	for command in [[&"move_slot", 0, 2], [&"swap_slots", 0, 2], [&"merge_slots", 0, 2], [&"split_stack", 0, 2, 1], [&"sort_slots"], [&"resize_capacity", 6], [&"expand_capacity", 1]]:
		var method: StringName = command[0]
		var arguments: Array = command.slice(1)
		t.assert_true(not model.callv(method, arguments).success, "client mirror rejects " + String(method))
		t.assert_equal(_layout(model), before, "denied slot command preserves mirror")
	var source := _model(3)
	source.add_item(&"berry", 1)
	var source_before := _layout(source)
	t.assert_true(not source.transfer_to(model, [ItemStack.new(&"berry", 1)], [ItemStack.new(&"berry", 1)]).success, "destination guard denies paired transfer before source commit")
	t.assert_equal(_layout(source), source_before, "denied destination cannot consume source")
	var guard_calls := [0]
	var late_denied := InventoryModel.new(3, Callable(ContentRegistry, "get_item"), func() -> bool:
		guard_calls[0] += 1
		return guard_calls[0] == 1
	)
	t.assert_true(not source.transfer_to(late_denied, [ItemStack.new(&"berry", 1)], [ItemStack.new(&"berry", 1)]).success, "late guard failure rejects before either commit")
	t.assert_equal(_layout(source), source_before, "late transfer failure preserves sparse source")
	t.assert_equal(late_denied.count(&"berry"), 0, "late transfer failure preserves destination")

func _test_legacy_boundaries(t: Node) -> void:
	var model := _model(4)
	model.initialize([ItemStack.new(&"water_drop", 1), _instance("unique"), ItemStack.new(&"berry", 3), ItemStack.new(&"berry", 2)])
	model.call("swap_slots", 0, 3)
	var before := _totals(model)
	t.assert_true(model.call("sort_slots").success, "explicit sorting succeeds")
	t.assert_equal(_totals(model), before, "sort conserves all identities and quantities")
	var sorted := _layout(model)
	model.call("sort_slots")
	t.assert_equal(_layout(model), sorted, "sort is deterministic and idempotent")
	model.call("expand_capacity", 2)
	model.call("move_slot", 0, 5)
	var wire := model.to_array()
	for record in wire:
		t.assert_true(record is Dictionary and record.keys().size() == 4 and not record.has("slot"), "legacy Save/wire stack record shape is unchanged")
	var restored := _model(model.capacity)
	t.assert_true(restored.restore(wire).is_empty(), "legacy records restore without schema migration")
	t.assert_equal(_totals(restored), _totals(model), "legacy round trip preserves quantities and identity")
	t.assert_true(_layout(restored) != _layout(model), "legacy dense view intentionally does not preserve holes")

func _totals(model: InventoryModel) -> Dictionary:
	var result: Dictionary = {}
	for stack in model.stacks():
		var key := "%s:%s:%d" % [stack.item_id, stack.instance_id, stack.durability]
		result[key] = result.get(key, 0) + stack.quantity
	return result

func _test_invalid_content(t: Node) -> void:
	var item := ContentRegistry.get_item(&"berry").duplicate() as ItemDefinition
	var model := InventoryModel.new(3, func(_id: StringName) -> ItemDefinition: return item)
	model.add_item(&"berry", 6)
	var before := _layout(model)
	item.max_stack = 2
	for command in [[&"move_slot", 0, 1], [&"swap_slots", 0, 1], [&"merge_slots", 0, 1], [&"split_stack", 0, 1, 1], [&"sort_slots"], [&"resize_capacity", 6]]:
		t.assert_true(not model.callv(command[0], command.slice(1)).success, "invalid stored quantity is rejected before mutation")
		t.assert_equal(_layout(model), before, "invalid content never causes partial slot changes")
	item.max_stack = 10
	var duplicate_layout: Array[ItemStack] = [_instance("dup"), null, _instance("dup")]
	var inventory := _model(3)
	inventory.add_item(&"berry", 1)
	before = _layout(inventory)
	t.assert_true(not inventory.initialize_slots(duplicate_layout).success, "sparse initialization rejects duplicate instance IDs")
	t.assert_equal(_layout(inventory), before, "failed sparse initialization is atomic")
	var sparse: Array[ItemStack] = [null, ItemStack.new(&"berry", 1)]
	t.assert_true(inventory.initialize_slots(sparse).success, "sparse domain initialization accepts explicit holes")
	t.assert_true(inventory.get_slot(0) == null and inventory.get_slot(1).quantity == 1, "sparse initialization keeps specified index")
	sparse[1].quantity = 999
	t.assert_equal(inventory.get_slot(1).quantity, 1, "sparse initialization copies external stack inputs")

func _test_death_layout(t: Node) -> void:
	var resolver := Callable(ContentRegistry, "get_item")
	var start := GameSession.get_start_definition()
	var player := PlayerState.new(resolver)
	player.reset(start, ContentRegistry)
	player.inventory.initialize([ItemStack.new(&"berry", 8), ItemStack.new(&"water_drop", 2), ItemStack.new(&"return_seed", 1)])
	player.inventory.move_slot(0, 7)
	player.inventory.move_slot(1, 9)
	player.inventory.move_slot(2, 11)
	var settlement := SettlementState.new(resolver)
	settlement.reset(start, ContentRegistry)
	var adventure := AdventureState.new()
	var context := AdventureContext.new()
	context.region_id = &"sewer_region"
	adventure.active_session = AdventureSession.new(context, resolver)
	var rules := GameSession.current_difficulty().duplicate() as DifficultyDefinition
	rules.inventory_loss = DifficultyDefinition.InventoryLoss.HALF
	var resolved := DeathResolutionService.resolve(player, settlement, adventure, rules, Vector2(100, 100), RespawnPolicy.new(), SurvivalConfig.new(), "slot-test", resolver)
	t.assert_true(resolved.in_adventure, "death layout fixture resolves an Adventure loss")
	t.assert_true(player.inventory.get_slot(0) == null and player.inventory.get_slot(1) == null, "death does not compact existing holes")
	t.assert_equal(player.inventory.get_slot(7).quantity, 4, "HALF loss changes quantity in original berry slot")
	t.assert_equal(player.inventory.get_slot(9).quantity, 1, "HALF loss changes quantity in original water slot")
	t.assert_equal(player.inventory.get_slot(11).quantity, 1, "protected item keeps its original slot")

func _test_save_and_wire_limits(t: Node) -> void:
	GameSession.start_new_game()
	var owner := GameSession.get_local_player_id()
	var inventory := GameSession.player.inventory
	inventory.clear()
	inventory.expand_capacity(1)
	for index in inventory.capacity:
		inventory.add_stack(_instance("expanded-%d" % index))
	var saved := GameSession.export_persistent_state()
	var state: Dictionary = saved["players"][String(owner)]["player_state"]
	t.assert_true(state.player_inventory is Dictionary and state.player_inventory.capacity == inventory.capacity, "Save v5 stores indexed capacity")
	var restored := GameSession.prepare_persistent_restore(saved)
	t.assert_true(restored.fatal_error.is_empty(), "expanded memory inventory remains readable as Save v5")
	t.assert_equal(restored.player.inventory.capacity, inventory.capacity, "Save v5 restores expanded capacity")
	t.assert_equal(restored.player.inventory.to_slot_dict(), inventory.to_slot_dict(), "expanded slot layout retains all items without overflow")
	GameSession.start_new_game()
	GameSession.player.inventory.move_slot(0, 7)
	var writable := [true]
	var mirror := PlayerState.new(Callable(ContentRegistry, "get_item"), func() -> bool: return writable[0])
	mirror.reset(GameSession.get_start_definition(), ContentRegistry)
	mirror.inventory.expand_capacity(12)
	mirror.inventory.move_slot(0, 23)
	writable[0] = false
	var payload := PlayerItemStateSnapshot.from_state(owner, GameSession.player).to_payload()
	payload["revision"] = mirror.item_state_revision + 1
	var expected_keys := ["equipment", "inventory", "inventory_capacity", "owner_player_id", "protected_capacity", "protected_inventory", "revision"]
	var keys := payload.keys()
	keys.sort()
	t.assert_equal(keys, expected_keys, "Protocol v19 retains the owner snapshot envelope")
	var parsed := PlayerItemStateSnapshot.from_payload(payload, ContentRegistry, owner)
	t.assert_true(parsed.error_message.is_empty() and mirror.apply_item_network_mirror(parsed), "existing owner snapshot atomically replaces a larger sparse mirror")
	t.assert_equal(mirror.inventory.capacity, GameSession.player.inventory.capacity, "mirror capacity replaces occupied old tail safely")
	t.assert_true(mirror.inventory.to_slot_dict() == GameSession.player.inventory.to_slot_dict(), "v19 replicates exact source coordinates")
	t.assert_equal(_totals(mirror.inventory), _totals(GameSession.player.inventory), "wire limitation does not lose or duplicate quantities")
	t.assert_equal(SaveManager.CURRENT_VERSION, 5, "Save uses v5")
	t.assert_equal(NetworkProtocol.VERSION, 19, "Protocol uses v19")
	t.assert_equal(LocalPlayerProfile.PROFILE_VERSION, 1, "Profile remains v1")
	GameSession.start_new_game()

func _test_conservation(t: Node) -> void:
	var model := _model(10)
	model.initialize([ItemStack.new(&"berry", 9), ItemStack.new(&"berry", 7), ItemStack.new(&"water_drop", 3), _instance("fuzz-1"), _instance("fuzz-2")])
	var totals := _totals(model)
	var random := RandomNumberGenerator.new()
	random.seed = 47202
	for iteration in 200:
		var before := _layout(model)
		var a := random.randi_range(-1, model.capacity)
		var b := random.randi_range(-1, model.capacity)
		var command: CommandResult
		match random.randi_range(0, 4):
			0: command = model.call("move_slot", a, b)
			1: command = model.call("swap_slots", a, b)
			2: command = model.call("merge_slots", a, b)
			3: command = model.call("split_stack", a, b, random.randi_range(-1, 12))
			4: command = model.call("sort_slots")
		t.assert_equal(_totals(model), totals, "mixed slot operations conserve items and instance metadata")
		t.assert_equal(model.call("slots").size(), model.capacity, "mixed operations preserve fixed slot array size")
		if not command.success:
			t.assert_equal(_layout(model), before, "failed mixed operation leaves exact original layout")
