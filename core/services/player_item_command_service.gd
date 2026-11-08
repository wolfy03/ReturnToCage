class_name PlayerItemCommandService
extends RefCounted

enum TransferDirection { DEPOSIT, WITHDRAW }
enum SlotAction { MOVE, SWAP, MERGE, SPLIT, SORT, DROP }
enum SlotInventory { MAIN, PROTECTED }

var registry: Node

func _init(p_registry: Node) -> void:
	registry = p_registry

func try_equip(player: PlayerState, instance_id: String) -> CommandResult:
	if player == null or instance_id.is_empty():
		return CommandResult.make(false, "Equip requires an equipment instance")
	var target := _find_instance(player.inventory.stacks(), instance_id)
	var definition := registry.get_item(target.item_id) as EquipmentDefinition if target != null else null
	if target == null or definition == null or target.quantity != 1:
		return CommandResult.make(false, "Equipment instance is unavailable")
	for equipped in player.equipment.all_equipped():
		if equipped.instance_id == instance_id:
			return CommandResult.make(false, "Equipment instance is already equipped")
	var previous := player.equipment.equipped(definition.equipment_slot)
	if _bag_contains_instance(player.protected_inventory, target.instance_id) \
			or (previous != null and _bag_contains_instance(player.protected_inventory, previous.instance_id)):
		return CommandResult.make(false, "Duplicate equipment instance in the protected bag")
	var outputs: Array[ItemStack] = []
	if previous != null:
		if previous.instance_id.is_empty():
			previous.instance_id = ItemStack.new_instance_id(previous.item_id)
		outputs.append(previous)
	var inputs: Array[ItemStack] = [target]
	var preview := player.inventory.preview_exchange(inputs, outputs)
	if not preview.success:
		return preview
	player.begin_item_update()
	var inventory_result := player.inventory.exchange(inputs, outputs)
	if inventory_result.success:
		player.equipment.equip(target)
	player.end_item_update()
	return CommandResult.make(inventory_result.success, "Equipped %s" % target.item_id if inventory_result.success else inventory_result.message)

func try_unequip(player: PlayerState, slot: int) -> CommandResult:
	if player == null or slot not in EquipmentDefinition.EquipmentSlot.values():
		return CommandResult.make(false, "Invalid equipment slot")
	var equipped := player.equipment.equipped(slot)
	if equipped == null:
		return CommandResult.make(false, "Equipment slot is empty")
	if _bag_contains_instance(player.protected_inventory, equipped.instance_id):
		return CommandResult.make(false, "Duplicate equipment instance in the protected bag")
	if equipped.instance_id.is_empty():
		equipped.instance_id = ItemStack.new_instance_id(equipped.item_id)
	var output: Array[ItemStack] = [equipped]
	var preview := player.inventory.preview_exchange([], output)
	if not preview.success:
		return preview
	player.begin_item_update()
	var inventory_result := player.inventory.exchange([], output)
	if inventory_result.success:
		player.equipment.unequip(slot)
	player.end_item_update()
	return CommandResult.make(inventory_result.success, "Equipment removed" if inventory_result.success else inventory_result.message)

func try_use_item(
	player: PlayerState,
	survival: SurvivalComponent,
	effects: EffectController,
	item_id: StringName
) -> CommandResult:
	if player == null or item_id.is_empty():
		return CommandResult.make(false, "Item use requires a known item owner")
	var definition := registry.get_item(item_id) as ItemDefinition
	if definition == null or definition is EquipmentDefinition or definition.category == ItemDefinition.ItemCategory.RETURN_ITEM \
			or not definition.is_consumable() or player.inventory.count(item_id) <= 0:
		return CommandResult.make(false, "Item cannot be used")
	for stack in player.inventory.stacks():
		if stack.item_id == item_id and not stack.instance_id.is_empty():
			return CommandResult.make(false, "Items with individual identities cannot be used by item type")
	player.begin_item_update()
	var used := ItemUseService.use_item(player.inventory, survival, effects, item_id, Callable(registry, "get_item"))
	player.end_item_update()
	return CommandResult.make(used, "Used %s" % item_id if used else "Item use failed")

func try_transfer(
	player: PlayerState,
	settlement: SettlementState,
	direction: int,
	item_id: StringName,
	instance_id: String,
	amount: int
) -> CommandResult:
	if player == null or settlement == null or direction not in TransferDirection.values() or amount <= 0:
		return CommandResult.make(false, "Invalid inventory transfer")
	var source: InventoryModel = player.inventory if direction == TransferDirection.DEPOSIT else settlement.storage
	var destination: InventoryModel = settlement.storage if direction == TransferDirection.DEPOSIT else player.inventory
	var source_item: ItemStack
	var destination_item: ItemStack
	if not instance_id.is_empty():
		source_item = _find_instance(source.stacks(), instance_id)
		if source_item == null or amount != 1 or (not item_id.is_empty() and source_item.item_id != item_id):
			return CommandResult.make(false, "Transfer instance is unavailable")
		destination_item = source_item.duplicate_stack()
	else:
		var definition := registry.get_item(item_id) as ItemDefinition
		if definition == null or source.count(item_id) < amount:
			return CommandResult.make(false, "Transfer item is unavailable")
		if definition is EquipmentDefinition:
			if amount != 1:
				return CommandResult.make(false, "Equipment transfer amount must be one")
			source_item = _find_legacy_equipment(source.stacks(), item_id)
			if source_item == null:
				return CommandResult.make(false, "Equipment transfer requires an instance identity")
			destination_item = source_item.duplicate_stack()
			destination_item.instance_id = ItemStack.new_instance_id(item_id)
		else:
			source_item = ItemStack.new(item_id, amount)
			destination_item = source_item.duplicate_stack()
	if _instance_conflicts(player, settlement, destination_item.instance_id):
		return CommandResult.make(false, "Duplicate item instance across player and settlement")
	var inputs: Array[ItemStack] = [source_item]
	var outputs: Array[ItemStack] = [destination_item]
	player.begin_item_update()
	settlement.begin_update()
	var transferred := source.transfer_to(destination, inputs, outputs)
	settlement.end_update()
	player.end_item_update()
	if not transferred.success:
		return transferred
	return CommandResult.make(true, "Deposited item" if direction == TransferDirection.DEPOSIT else "Withdrew item")

func _bag_contains_instance(inventory: InventoryModel, instance_id: String) -> bool:
	return not instance_id.is_empty() and _find_instance(inventory.stacks(), instance_id) != null

func _find_instance(stacks: Array[ItemStack], instance_id: String) -> ItemStack:
	for stack in stacks:
		if stack.instance_id == instance_id:
			return stack
	return null

func _find_legacy_equipment(stacks: Array[ItemStack], item_id: StringName) -> ItemStack:
	for stack in stacks:
		if stack.item_id == item_id and stack.instance_id.is_empty():
			return stack
	return null

func _instance_conflicts(player: PlayerState, settlement: SettlementState, instance_id: String) -> bool:
	if instance_id.is_empty():
		return false
	# The staged destination checks its own bag. Also check containers that
	# are not participating in the transfer on either side.
	return _bag_contains_instance(player.protected_inventory, instance_id) \
		or _find_instance(player.equipment.all_equipped(), instance_id) != null \
		or _find_instance(settlement.pending_loot, instance_id) != null

static func slot_inventory(player: PlayerState, kind: int) -> InventoryModel:
	if player == null:
		return null
	match kind:
		SlotInventory.MAIN: return player.inventory
		SlotInventory.PROTECTED: return player.protected_inventory
	return null

static func slot_fingerprint(stack: ItemStack) -> Dictionary:
	return stack.to_dict() if stack != null else {}

static func valid_slot_command(command: Dictionary) -> bool:
	if command.size() != 13:
		return false
	for key in ["owner_player_id", "session_id", "world_id"]:
		if not SaveData.is_text(command.get(key)) or String(command[key]).is_empty():
			return false
	for key in ["world_revision", "revision", "sequence", "action", "inventory", "from", "to", "amount"]:
		if not command.get(key) is int:
			return false
	if command.revision < 0 or command.world_revision < 1 or command.sequence < 1 or command.sequence > 0x7fffffff or command.action not in SlotAction.values() or command.inventory not in SlotInventory.values():
		return false
	for key in ["source", "target"]:
		var fingerprint: Variant = command.get(key)
		if not fingerprint is Dictionary:
			return false
		if not fingerprint.is_empty() and (fingerprint.size() != 4 or not fingerprint.get("quantity") is int or not fingerprint.get("durability") is int or not fingerprint.has("instance_id") or not SaveData.valid_stack(fingerprint, PackedStringArray())):
			return false
	return true

func try_slot_command(
	player: PlayerState,
	command: Dictionary,
	loot_manager: LootSpawnManager = null,
	drop_position: Vector2 = Vector2.INF
) -> CommandResult:
	if player == null or not valid_slot_command(command):
		return CommandResult.make(false, "Malformed inventory slot command")
	if command.revision != player.item_state_revision:
		return CommandResult.make(false, "Stale inventory revision")
	var inventory := slot_inventory(player, command.inventory)
	if command.action == SlotAction.DROP:
		return _try_drop_slot(inventory, command, loot_manager, drop_position)
	if command.action == SlotAction.SORT:
		if command.from != -1 or command.to != -1 or command.amount != 0 or not command.source.is_empty() or not command.target.is_empty():
			return CommandResult.make(false, "Invalid inventory sort")
		return inventory.sort_slots()
	var from: int = command.from
	var to: int = command.to
	if from < 0 or to < 0 or from >= inventory.capacity or to >= inventory.capacity:
		return CommandResult.make(false, "Inventory slot index out of range")
	if command.source != slot_fingerprint(inventory.get_slot(from)) or command.target != slot_fingerprint(inventory.get_slot(to)):
		return CommandResult.make(false, "Inventory slot contents changed")
	if (command.action == SlotAction.SPLIT and command.amount <= 0) or (command.action != SlotAction.SPLIT and command.amount != 0):
		return CommandResult.make(false, "Invalid inventory slot amount")
	match command.action:
		SlotAction.MOVE: return inventory.move_slot(from, to)
		SlotAction.SWAP: return inventory.swap_slots(from, to)
		SlotAction.MERGE: return inventory.merge_slots(from, to)
		SlotAction.SPLIT: return inventory.split_stack(from, to, command.amount)
	return CommandResult.make(false, "Unknown inventory slot action")

func _try_drop_slot(inventory: InventoryModel, command: Dictionary, loot_manager: LootSpawnManager, position: Vector2) -> CommandResult:
	if command.inventory != SlotInventory.MAIN:
		return CommandResult.make(false, "Only the main inventory can drop items")
	if command.from < 0 or command.from >= inventory.capacity or command.to != -1 or not command.target.is_empty():
		return CommandResult.make(false, "Invalid drop slot")
	var source := inventory.get_slot(command.from)
	if source == null or command.source != slot_fingerprint(source):
		return CommandResult.make(false, "Inventory slot contents changed")
	if command.amount <= 0 or command.amount > source.quantity:
		return CommandResult.make(false, "Invalid drop amount")
	var definition := ContentRegistry.get_item(source.item_id)
	if definition == null or not definition.discardable or definition.quest_protected:
		return CommandResult.make(false, "This item cannot be dropped")
	if loot_manager == null:
		return CommandResult.make(false, "Item drops require an active field")

	var dropped := source.duplicate_stack()
	dropped.quantity = command.amount
	inventory.begin_update()
	var entity_id := loot_manager.spawn_loot(dropped, position, func() -> bool:
		return inventory.remove_from_slot(command.from, source, command.amount).success
	)
	inventory.end_update()
	if entity_id <= 0:
		return CommandResult.make(false, "Could not drop item")
	return CommandResult.make(true, "Dropped item")
