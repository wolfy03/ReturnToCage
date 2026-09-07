class_name PlayerState
extends RefCounted

var stats: StatBlock = StatBlock.new()
var inventory: InventoryModel
var equipment: EquipmentModel
var protected_inventory: InventoryModel
var survival: SurvivalState = SurvivalState.new()
var health: float = 0.0
var last_safe_position: Vector2 = Vector2.ZERO

func _init(resolver: Callable) -> void:
	inventory = InventoryModel.new(0, resolver)
	equipment = EquipmentModel.new(resolver)
	protected_inventory = InventoryModel.new(0, resolver)

func reset(start: GameStartDefinition, registry: Node) -> void:
	stats = StatBlock.new()
	stats.base_values = start.player_stats.duplicate()
	survival = SurvivalState.new()
	survival.reset(start)
	health = start.player_health
	last_safe_position = start.last_safe_position
	inventory.capacity = start.inventory_capacity
	protected_inventory.capacity = start.protected_capacity
	inventory.initialize(start.create_stacks(start.inventory_items, registry))
	protected_inventory.initialize(start.create_stacks(start.protected_items, registry))
	equipment.restore({})
	for entry in start.equipment_items:
		equipment.equip(entry.create_stack())

func to_save_dict() -> Dictionary:
	return {
		"player_stats": stats.to_dict(), "player_inventory": inventory.to_array(),
		"equipment": equipment.to_dict(), "protected_inventory": protected_inventory.to_array(),
		"survival_state": survival.to_dict(), "player_health": health,
		"last_safe_position": [last_safe_position.x, last_safe_position.y]
	}

func restore(data: Dictionary, start: GameStartDefinition) -> PackedStringArray:
	var errors := PackedStringArray()
	stats = StatBlock.new()
	stats.base_values = start.player_stats.duplicate()
	errors.append_array(stats.restore(SaveData.dictionary(data, "player_stats", errors)))
	inventory.capacity = start.inventory_capacity
	protected_inventory.capacity = start.protected_capacity
	errors.append_array(inventory.restore(SaveData.array(data, "player_inventory", errors)))
	errors.append_array(equipment.restore(SaveData.dictionary(data, "equipment", errors)))
	errors.append_array(protected_inventory.restore(SaveData.array(data, "protected_inventory", errors)))
	survival = SurvivalState.new()
	survival.reset(start)
	errors.append_array(survival.restore(SaveData.dictionary(data, "survival_state", errors)))
	health = SaveData.number(data, "player_health", stats.value(&"max_health"), errors)
	last_safe_position = start.last_safe_position
	if data.has("last_safe_position"):
		var position: Variant = data["last_safe_position"]
		if position is Array and position.size() == 2 and SaveData.is_number(position[0]) and SaveData.is_number(position[1]):
			last_safe_position = Vector2(float(position[0]), float(position[1]))
		else:
			errors.append("invalid last_safe_position in save")
	return errors
