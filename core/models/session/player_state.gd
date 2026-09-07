class_name PlayerState
extends RefCounted

signal vitals_changed

var effects: EffectRuntimeModel
var _gear_sources: Array[StringName] = []

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
	equipment.changed.connect(sync_equipment)
	_reset_effects()
	protected_inventory = InventoryModel.new(0, resolver)

func reset(start: GameStartDefinition, registry: Node) -> void:
	stats = StatBlock.new()
	stats.base_values = start.player_stats.duplicate()
	_reset_effects()
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
		"active_effects": effects.to_array(), "survival_state": survival.to_dict(), "player_health": health,
		"last_safe_position": [last_safe_position.x, last_safe_position.y]
	}

func restore(data: Dictionary, start: GameStartDefinition) -> PackedStringArray:
	var errors := PackedStringArray()
	stats = StatBlock.new()
	stats.base_values = start.player_stats.duplicate()
	_reset_effects()
	errors.append_array(stats.restore(SaveData.dictionary(data, "player_stats", errors)))
	if stats.value(&"max_health") <= 0.0:
		stats.set_base(&"max_health", start.player_stats[&"max_health"])
		errors.append("invalid max_health restored to start value")
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
	errors.append_array(effects.restore(SaveData.array(data, "active_effects", errors), Callable(ContentRegistry, "get_definition")))
	sync_equipment()
	return errors

func _reset_effects() -> void:
	effects = EffectRuntimeModel.new(stats)
	effects.periodic.connect(_on_periodic)
	_gear_sources.clear()
	stats.stat_changed.connect(_on_persistent_stat_changed)

func _on_persistent_stat_changed(stat_id: StringName, _value: float) -> void:
	if stat_id == &"max_health":
		set_health(health)

func _on_periodic(amount: float, damage: bool) -> void:
	set_health(health - amount if damage else health + amount)

func set_health(value: float) -> void:
	var next: float = clampf(value, 0.0, maxf(1.0, stats.value(&"max_health")))
	if not is_equal_approx(health, next):
		health = next
		vitals_changed.emit()

func sync_equipment() -> void:
	stats.begin_update()
	for source in _gear_sources:
		stats.remove_source(source)
		effects.remove_source(source)
	_gear_sources.clear()
	for stack in equipment.all_equipped():
		if stack.durability == 0:
			continue
		var definition: EquipmentDefinition = equipment.definition_resolver.call(stack.item_id) as EquipmentDefinition
		if definition == null:
			continue
		var source := StringName("equipment:%d" % definition.equipment_slot)
		_gear_sources.append(source)
		for stat_id in definition.stat_modifiers:
			stats.add_modifier(StatModifier.new(source, stat_id, definition.stat_modifiers[stat_id], 1.0))
		for effect in definition.equip_effects:
			effects.apply_effect(effect, ItemDefinition.FoodSlot.NONE, source, true)
	stats.end_update()
