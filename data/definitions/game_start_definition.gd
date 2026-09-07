class_name GameStartDefinition
extends ContentDefinition

@export var inventory_capacity: int = 12
@export var storage_capacity: int = 48
@export var protected_capacity: int = 8
@export var inventory_items: Array[StartingItemDefinition] = []
@export var storage_items: Array[StartingItemDefinition] = []
@export var protected_items: Array[StartingItemDefinition] = []
@export var equipment_items: Array[StartingItemDefinition] = []
@export var player_stats: Dictionary[StringName, float] = {}
@export var facility_levels: Dictionary[StringName, int] = {}
@export var residents: Array[StartingResidentDefinition] = []
@export var unlocked_regions: Array[StringName] = []
@export var unlocked_exits: Array[StringName] = []
@export var unlocked_flags: Array[StringName] = []
@export var discovered_escape_points: Array[StringName] = []
@export var respawn_policy: RespawnPolicy
@export var survival_config: SurvivalConfig
@export var difficulty_id: StringName
@export var player_health: float = 100.0
@export var hunger: float = 100.0
@export var thirst: float = 100.0
@export var progression_reduction: float = 0.0
@export var last_safe_position: Vector2

func validate_definition(registry: Node) -> PackedStringArray:
	var errors: PackedStringArray = super.validate_definition(registry)
	if respawn_policy == null or survival_config == null:
		errors.append("%s: respawn policy and survival config required" % id)
	else:
		errors.append_array(respawn_policy.validate_definition(registry))
		errors.append_array(survival_config.validate_definition(registry))
	var instances: Dictionary[String, String] = {}
	_validate_items(inventory_items, inventory_capacity, registry, errors, instances, "starting inventory")
	_validate_items(equipment_items, EquipmentDefinition.EquipmentSlot.size(), registry, errors, instances, "starting equipment")
	_validate_items(protected_items, protected_capacity, registry, errors, instances, "starting protected inventory")
	_validate_items(storage_items, storage_capacity, registry, errors, instances, "starting storage")
	var slots: Array[int] = []
	for entry in equipment_items:
		if entry == null:
			errors.append("%s: null starting equipment" % id)
			continue
		var gear := registry.get_item(entry.item_id) as EquipmentDefinition
		if gear == null or entry.quantity != 1:
			errors.append("%s: invalid starting equipment %s" % [id, entry.item_id])
		elif entry.durability < -1 or entry.durability > gear.max_durability or slots.has(gear.equipment_slot):
			errors.append("%s: invalid durability or duplicate equipment slot: %s" % [id, entry.item_id])
		else:
			slots.append(gear.equipment_slot)
	for facility_id in facility_levels:
		var facility := registry.get_definition(facility_id) as FacilityDefinition
		if facility == null or facility_levels[facility_id] < 0 or facility_levels[facility_id] > facility.max_level:
			errors.append("%s: invalid starting facility %s" % [id, facility_id])
	for region_id in unlocked_regions:
		if not registry.get_definition(region_id) is RegionDefinition:
			errors.append("%s: unknown starting region %s" % [id, region_id])
	for exit_id in unlocked_exits:
		if not registry.get_definition(exit_id) is SettlementExitDefinition:
			errors.append("%s: unknown starting exit %s" % [id, exit_id])
	if not registry.get_definition(difficulty_id) is DifficultyDefinition:
		errors.append("%s: unknown starting difficulty %s" % [id, difficulty_id])
	var resident_ids: Array[StringName] = []
	for resident in residents:
		# There is no ResidentDefinition registry yet: validate local identity only.
		if resident == null or resident.resident_id.is_empty() or resident.current_state.is_empty() or resident_ids.has(resident.resident_id):
			errors.append("%s: invalid or duplicate starting resident" % id)
		else:
			resident_ids.append(resident.resident_id)
	for stat_id in player_stats:
		if stat_id.is_empty() or not is_finite(player_stats[stat_id]):
			errors.append("%s: invalid starting stat %s" % [id, stat_id])
	for stat_id in StatBlock.new().base_values:
		if not player_stats.has(stat_id):
			errors.append("%s: missing starting stat %s" % [id, stat_id])
	if player_stats.get(&"max_health", 0.0) <= 0.0 or player_health > player_stats.get(&"max_health", 0.0):
		errors.append("%s: starting health must fit a positive max_health" % id)
	if not is_finite(player_health) or player_health < 0.0 or not is_finite(hunger) or hunger < 0.0 or not is_finite(thirst) or thirst < 0.0 or not is_finite(progression_reduction) or progression_reduction < 0.0 or progression_reduction > 0.9 or not last_safe_position.is_finite():
		errors.append("%s: invalid starting vitals or position" % id)
	if survival_config != null and (hunger > survival_config.max_hunger or thirst > survival_config.max_thirst):
		errors.append("%s: starting survival exceeds configured maxima" % id)
	return errors

func _validate_items(entries: Array[StartingItemDefinition], capacity: int, registry: Node, errors: PackedStringArray, instances: Dictionary[String, String], context: String) -> void:
	var stacks_needed: int = 0
	if capacity < 1:
		errors.append("%s: starting inventory capacity must be positive" % id)
	for entry in entries:
		if entry == null:
			errors.append("%s: null starting item" % id)
			continue
		var item := registry.get_item(entry.item_id) as ItemDefinition
		var stack: ItemStack = entry.create_stack()
		var error: String = StackValidation.runtime_error(stack, item)
		if not error.is_empty():
			errors.append("%s %s: %s (%s, quantity %d, instance %s)" % [id, context, error, entry.item_id, entry.quantity, entry.instance_id])
			continue
		StackValidation.accept_instance(stack, instances, errors, context)
		stacks_needed += 1 if not entry.instance_id.is_empty() else ceili(float(entry.quantity) / item.max_stack)
	if stacks_needed > capacity:
		errors.append("%s: starting items exceed capacity" % id)

func create_stacks(entries: Array[StartingItemDefinition], registry: Node) -> Array[ItemStack]:
	var stacks: Array[ItemStack] = []
	for entry in entries:
		var item: ItemDefinition = registry.get_item(entry.item_id) as ItemDefinition if entry != null else null
		var initial: ItemStack = entry.create_stack() if entry != null else null
		if not StackValidation.runtime_error(initial, item).is_empty():
			push_error("Cannot create invalid starting stacks")
			return []
		if not initial.instance_id.is_empty():
			stacks.append(initial)
			continue
		var remaining: int = entry.quantity
		while remaining > 0:
			var stack: ItemStack = entry.create_stack()
			stack.quantity = mini(remaining, item.max_stack)
			stacks.append(stack)
			remaining -= stack.quantity
	return stacks
