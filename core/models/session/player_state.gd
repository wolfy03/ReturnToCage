class_name PlayerState
extends RefCounted

signal vitals_changed
signal item_state_changed(revision: int)

var effects: EffectRuntimeModel
var _gear_sources: Array[StringName] = []

var stats: StatBlock = StatBlock.new()
var inventory: InventoryModel
var equipment: EquipmentModel
var protected_inventory: InventoryModel
var survival: SurvivalState = SurvivalState.new()
var health: float = 0.0
var last_safe_position: Vector2 = Vector2.ZERO
var _item_state_revision: int = 0
var item_state_revision: int:
	get:
		return _item_state_revision
var _item_update_depth: int = 0
var _item_change_pending: bool = false
var _applying_item_snapshot: bool = false
var _item_mutation_guard: Callable

func _init(resolver: Callable, mutation_guard: Callable = Callable()) -> void:
	_item_mutation_guard = mutation_guard
	inventory = InventoryModel.new(0, resolver, Callable(self, "_can_mutate_items"))
	equipment = EquipmentModel.new(resolver, Callable(self, "_can_mutate_items"))
	inventory.changed.connect(_on_item_model_changed)
	equipment.changed.connect(_on_equipment_changed)
	_reset_effects()
	protected_inventory = InventoryModel.new(0, resolver, Callable(self, "_can_mutate_items"))
	protected_inventory.changed.connect(_on_item_model_changed)

func set_item_mutation_guard(guard: Callable) -> void:
	_item_mutation_guard = guard

func reset(start: GameStartDefinition, registry: Node) -> void:
	_applying_item_snapshot = true
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
	_item_state_revision = 0
	_item_update_depth = 0
	_item_change_pending = false
	_applying_item_snapshot = false

func to_save_dict() -> Dictionary:
	return {
		"player_stats": stats.to_dict(), "player_inventory": inventory.to_array(),
		"equipment": equipment.to_dict(), "protected_inventory": protected_inventory.to_array(),
		"active_effects": effects.to_array(), "survival_state": survival.to_dict(), "player_health": health,
		"last_safe_position": [last_safe_position.x, last_safe_position.y]
	}

func restore(data: Dictionary, start: GameStartDefinition, instances: Dictionary[String, String] = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	_applying_item_snapshot = true
	stats = StatBlock.new()
	stats.base_values = start.player_stats.duplicate()
	_reset_effects()
	errors.append_array(stats.restore(SaveData.dictionary(data, "player_stats", errors)))
	if stats.value(&"max_health") <= 0.0:
		stats.set_base(&"max_health", start.player_stats[&"max_health"])
		errors.append("invalid max_health restored to start value")
	inventory.capacity = start.inventory_capacity
	protected_inventory.capacity = start.protected_capacity
	errors.append_array(inventory.restore(SaveData.array(data, "player_inventory", errors), instances, "player_inventory"))
	errors.append_array(equipment.restore(SaveData.dictionary(data, "equipment", errors), instances))
	errors.append_array(protected_inventory.restore(SaveData.array(data, "protected_inventory", errors), instances, "protected_inventory"))
	survival = SurvivalState.new()
	survival.reset(start)
	errors.append_array(survival.restore(SaveData.dictionary(data, "survival_state", errors)))
	last_safe_position = SaveData.position(data, "last_safe_position", start.last_safe_position, errors)
	errors.append_array(effects.restore(SaveData.array(data, "active_effects", errors), Callable(ContentRegistry, "get_definition")))
	sync_equipment()
	set_health(SaveData.clamped_number(data, "player_health", stats.value(&"max_health"), 0.0, maxf(1.0, stats.value(&"max_health")), errors))
	_item_state_revision = 0
	_item_update_depth = 0
	_item_change_pending = false
	_applying_item_snapshot = false
	return errors

func begin_item_update() -> void:
	_item_update_depth += 1
	inventory.begin_update()
	protected_inventory.begin_update()
	equipment.begin_update()

func end_item_update() -> void:
	if _item_update_depth <= 0:
		return
	equipment.end_update()
	protected_inventory.end_update()
	inventory.end_update()
	_item_update_depth -= 1
	if _item_update_depth == 0 and _item_change_pending:
		_item_change_pending = false
		_commit_item_change()

func prepare_network_item_mirror() -> void:
	_applying_item_snapshot = true
	inventory.initialize([])
	protected_inventory.initialize([])
	equipment.initialize({})
	_item_state_revision = -1
	_item_change_pending = false
	_applying_item_snapshot = false

func apply_item_network_mirror(snapshot: PlayerItemStateSnapshot) -> bool:
	if snapshot == null or not snapshot.error_message.is_empty() or snapshot.revision <= item_state_revision:
		return false
	_applying_item_snapshot = true
	inventory.begin_update()
	protected_inventory.begin_update()
	equipment.begin_update()
	inventory.capacity = snapshot.inventory_capacity
	protected_inventory.capacity = snapshot.protected_capacity
	var inventory_result := inventory.initialize(snapshot.inventory)
	var protected_result := protected_inventory.initialize(snapshot.protected_inventory)
	var equipment_result := equipment.initialize(snapshot.equipment)
	equipment.end_update()
	protected_inventory.end_update()
	inventory.end_update()
	if not inventory_result.success or not protected_result.success or not equipment_result.success:
		_applying_item_snapshot = false
		return false
	_item_state_revision = snapshot.revision
	_item_change_pending = false
	_applying_item_snapshot = false
	item_state_changed.emit(item_state_revision)
	return true

func _on_equipment_changed() -> void:
	sync_equipment()
	_on_item_model_changed()

func _on_item_model_changed() -> void:
	if _applying_item_snapshot:
		return
	if _item_update_depth > 0:
		_item_change_pending = true
	else:
		_commit_item_change()

func _commit_item_change() -> void:
	_item_state_revision += 1
	item_state_changed.emit(_item_state_revision)

func _can_mutate_items() -> bool:
	return _applying_item_snapshot or not _item_mutation_guard.is_valid() or bool(_item_mutation_guard.call())

func _reset_effects() -> void:
	# A scene/test may retain the retired model. Disconnect before dropping it;
	# RefCounted lifetime alone does not protect this PlayerState from callbacks.
	if effects != null:
		effects.paused = true
		if effects.periodic.is_connected(_on_periodic):
			effects.periodic.disconnect(_on_periodic)
		if effects.stats != null and effects.stats.stat_changed.is_connected(_on_persistent_stat_changed):
			effects.stats.stat_changed.disconnect(_on_persistent_stat_changed)
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
	if not is_finite(value):
		return
	var next: float = clampf(value, 0.0, maxf(1.0, stats.value(&"max_health")))
	if not is_equal_approx(health, next):
		health = next
		vitals_changed.emit()

# Client-only network mirrors may use a server max-health value that is not yet
# represented by local stats. This updates health only; stats and their modifier,
# equipment, and effect ownership remain untouched.
func apply_replicated_health(value: float, authoritative_max_health: float) -> bool:
	if not is_finite(value) or not is_finite(authoritative_max_health) or authoritative_max_health <= 0.0:
		return false
	var next := clampf(value, 0.0, authoritative_max_health)
	if not is_equal_approx(health, next):
		health = next
		vitals_changed.emit()
	return true

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
