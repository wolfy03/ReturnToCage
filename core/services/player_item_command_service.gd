class_name PlayerItemCommandService
extends RefCounted

enum TransferDirection { DEPOSIT, WITHDRAW }

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
	var outputs: Array[ItemStack] = []
	if previous != null:
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
	if equipped.instance_id.is_empty():
		equipped.instance_id = _new_instance_id(equipped.item_id)
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
	if definition == null or not definition.is_consumable() or player.inventory.count(item_id) <= 0:
		return CommandResult.make(false, "Item cannot be used")
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
			destination_item.instance_id = _new_instance_id(item_id)
		else:
			source_item = ItemStack.new(item_id, amount)
			destination_item = source_item.duplicate_stack()
	if _instance_conflicts(player, settlement, destination_item, direction):
		return CommandResult.make(false, "Duplicate item instance across player and settlement")
	var inputs: Array[ItemStack] = [source_item]
	var outputs: Array[ItemStack] = [destination_item]
	var source_preview := source.preview_exchange(inputs, [])
	if not source_preview.success:
		return source_preview
	var destination_preview := destination.preview_exchange([], outputs)
	if not destination_preview.success:
		return destination_preview
	player.begin_item_update()
	settlement.begin_update()
	var removed := source.exchange(inputs, [])
	var added := destination.exchange([], outputs) if removed.success else CommandResult.make(false, removed.message)
	settlement.end_update()
	player.end_item_update()
	if not removed.success or not added.success:
		return CommandResult.make(false, added.message if not added.success else removed.message)
	return CommandResult.make(true, "Deposited item" if direction == TransferDirection.DEPOSIT else "Withdrew item")

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

func _new_instance_id(item_id: StringName) -> String:
	return "%s_%s" % [item_id, Crypto.new().generate_random_bytes(16).hex_encode()]

func _instance_conflicts(player: PlayerState, settlement: SettlementState, moving: ItemStack, direction: int) -> bool:
	if moving == null or moving.instance_id.is_empty():
		return false
	if direction == TransferDirection.DEPOSIT:
		for equipped in player.equipment.all_equipped():
			if equipped.instance_id == moving.instance_id:
				return true
		for pending in settlement.pending_loot:
			if pending.instance_id == moving.instance_id:
				return true
	else:
		for stack in player.inventory.stacks() + player.equipment.all_equipped():
			if stack.instance_id == moving.instance_id:
				return true
	return false
