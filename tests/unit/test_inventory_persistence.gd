extends RefCounted

func run(t: Node) -> void:
	t.assert_equal(SaveManager.CURRENT_VERSION, 5, "indexed inventories use Save v5")
	t.assert_equal(NetworkProtocol.VERSION, 17, "indexed owner snapshots use protocol v17")
	if not GameSession.player.inventory.has_method("to_slot_dict"):
		t.assert_true(false, "inventory exposes indexed serialization")
		return
	GameSession.start_new_game()
	var owner := GameSession.get_local_player_id()
	var inventory := GameSession.player.inventory
	inventory.expand_capacity(6)
	inventory.move_slot(0, 17)
	var gear := ItemStack.new(&"leaf_vest", 1)
	gear.instance_id = "v5-protected-vest"
	gear.durability = 33
	GameSession.player.protected_inventory.add_stack(gear)
	GameSession.player.protected_inventory.move_slot(0, 5)
	var equipped := gear.duplicate_stack()
	equipped.instance_id = "v5-equipped-vest"
	equipped.durability = 38
	GameSession.player.equipment.equip(equipped)
	GameSession.settlement.storage.expand_capacity(4)
	GameSession.settlement.storage.add_item(&"rusty_scrap", 3)
	GameSession.settlement.storage.move_slot(0, 51)
	var before := GameSession.export_persistent_state()
	var path := "user://inventory_v5_roundtrip.json"
	t.assert_true(SaveManager.save_game(path), "v5 writes sparse inventories")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	t.assert_equal(saved.format_version, 5.0, "writer emits v5")
	var hash_before := FileAccess.get_file_as_string(path).sha256_text()
	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path), "v5 file reloads")
	t.assert_equal(GameSession.export_persistent_state(), before, "v5 round trip preserves capacities, holes, quantities and gear identities")
	t.assert_equal(FileAccess.get_file_as_string(path).sha256_text(), hash_before, "load never rewrites the input file")
	t.assert_equal(GameSession.get_local_player_id(), owner, "slot persistence preserves Profile v1 identity")
	var payload := PlayerItemStateSnapshot.from_state(owner, GameSession.player).to_payload()
	var parsed := PlayerItemStateSnapshot.from_payload(payload, ContentRegistry, owner)
	var mirror := PlayerState.new(Callable(ContentRegistry, "get_item"), func() -> bool: return false)
	mirror.reset(GameSession.get_start_definition(), ContentRegistry)
	mirror.prepare_network_item_mirror()
	t.assert_true(parsed.error_message.is_empty() and mirror.apply_item_network_mirror(parsed), "owner-private indexed snapshot applies to read-only mirror")
	t.assert_equal(mirror.inventory.call("to_slot_dict"), GameSession.player.inventory.call("to_slot_dict"), "owner snapshot preserves exact main slots")
	t.assert_equal(mirror.protected_inventory.call("to_slot_dict"), GameSession.player.protected_inventory.call("to_slot_dict"), "owner snapshot preserves exact protected slots")
	t.assert_equal(mirror.equipment.to_dict(), GameSession.player.equipment.to_dict(), "owner snapshot preserves equipped instance metadata")
	var mirror_before := mirror.to_save_dict(true)
	var forged := payload.duplicate(true)
	forged.revision += 1
	forged.inventory[0].index = float(forged.inventory[0].index)
	var invalid := PlayerItemStateSnapshot.from_payload(forged, ContentRegistry, owner)
	t.assert_true(not invalid.error_message.is_empty() and not mirror.apply_item_network_mirror(invalid), "v17 rejects floating slot indices at the native wire boundary")
	t.assert_equal(mirror.to_save_dict(true), mirror_before, "rejected snapshot does not partially apply another private model")
	var dense_payload := payload.duplicate(true)
	dense_payload.inventory = GameSession.player.inventory.to_array()
	t.assert_true(not PlayerItemStateSnapshot.from_payload(dense_payload, ContentRegistry, owner).error_message.is_empty(), "v17 does not accept a v16 dense item body")
	_test_rejection(t, saved, path)
	var legacy := saved.duplicate(true)
	legacy.format_version = 4
	for record in legacy.players.values():
		for key in ["player_inventory", "protected_inventory"]:
			record.player_state[key] = _dense(record.player_state[key])
	legacy.shared.settlement.settlement_storage = _dense(legacy.shared.settlement.settlement_storage)
	var original := legacy.duplicate(true)
	var migrated := SaveManager.migrate(legacy)
	t.assert_equal(legacy, original, "v4 migration does not mutate caller data")
	t.assert_equal(migrated.format_version, 5, "v4 migration reaches v5")
	var cells: Array = migrated.players[String(owner)].player_state.player_inventory.slots
	for index in cells.size():
		t.assert_equal(cells[index].index, index, "v4 items migrate to contiguous front indices")
		t.assert_equal(cells[index].stack, legacy.players[String(owner)].player_state.player_inventory[index], "migration preserves raw quantity and instance metadata")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(legacy))
	file.close()
	var original_bytes := FileAccess.get_file_as_string(path)
	t.assert_true(SaveManager.load_game(path), "actual v4 file loads through v5 migration")
	t.assert_equal(JSON.parse_string(JSON.stringify(GameSession.player.inventory.to_slot_dict())), JSON.parse_string(JSON.stringify(migrated.players[String(owner)].player_state.player_inventory)), "v4 load uses the migrated contiguous layout")
	t.assert_equal(GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY).instance_id, equipped.instance_id, "v4 migration preserves equipped instance ID")
	t.assert_equal(FileAccess.get_file_as_string(path), original_bytes, "v4 migration leaves original file bytes intact")
	_cleanup(path)
	GameSession.start_new_game()

func _dense(layout: Dictionary) -> Array:
	var result: Array = []
	for cell in layout.slots:
		result.append(cell.stack.duplicate(true))
	return result

func _test_rejection(t: Node, saved: Dictionary, path: String) -> void:
	var owner := String(GameSession.get_local_player_id())
	var valid := GameSession.export_persistent_state()
	for kind in ["duplicate_index", "negative_index", "large_index", "fractional_index", "duplicate_instance", "invalid_quantity", "max_stack", "unknown_item", "equipment_conflict", "shared_conflict", "cross_owner", "capacity", "overfill", "dense_v5"]:
		var invalid := saved.duplicate(true)
		var layout: Dictionary = invalid.players[owner].player_state.player_inventory
		match kind:
			"duplicate_index": layout.slots.append(layout.slots[0].duplicate(true))
			"negative_index": layout.slots[0].index = -1
			"large_index": layout.slots[0].index = layout.capacity
			"fractional_index": layout.slots[0].index = 1.5
			"duplicate_instance": layout.slots[0].stack = invalid.players[owner].player_state.protected_inventory.slots[0].stack.duplicate(true)
			"invalid_quantity": layout.slots[0].stack.quantity = 0
			"max_stack": layout.slots[0].stack.quantity = 999
			"unknown_item": layout.slots[0].stack.item_id = "not-an-item"
			"equipment_conflict":
				var stack: Dictionary = invalid.players[owner].player_state.protected_inventory.slots[0].stack.duplicate(true)
				invalid.players[owner].player_state.equipment["1"] = stack
			"shared_conflict":
				invalid.shared.settlement.settlement_storage.slots[0].stack = invalid.players[owner].player_state.protected_inventory.slots[0].stack.duplicate(true)
			"cross_owner":
				var other := "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" if owner != "player_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else "player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
				invalid.players[other] = invalid.players[owner].duplicate(true)
			"capacity": layout.capacity = 1025
			"overfill": layout.capacity = 1
			"dense_v5": invalid.players[owner].player_state.player_inventory = []
		var file := FileAccess.open(path, FileAccess.WRITE)
		file.store_string(JSON.stringify(invalid))
		file.close()
		var bytes := FileAccess.get_file_as_string(path)
		t.assert_true(not SaveManager.load_game(path), "malformed v5 rejected: " + kind)
		t.assert_equal(GameSession.export_persistent_state(), valid, "failed v5 staging preserves canonical state: " + kind)
		t.assert_equal(FileAccess.get_file_as_string(path), bytes, "rejected Save file is preserved: " + kind)

func _cleanup(path: String) -> void:
	for suffix in ["", ".bak", ".tmp"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
