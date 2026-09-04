extends Node

signal session_reset
signal inventory_changed
signal storage_changed
signal facility_changed(facility_id: StringName, level: int)
signal quest_changed(quest_id: StringName)
signal adventure_started(context: AdventureContext)
signal adventure_finished(result: AdventureSession.Result, summary: String)
signal difficulty_changed(id: StringName)

var session_id: String = ""
var play_time_seconds: float = 0.0
var player_stats := StatBlock.new()
var player_inventory: InventoryModel
var equipment: EquipmentModel
var settlement_storage: InventoryModel
var protected_inventory: InventoryModel
var active_adventure: AdventureSession
var facility_levels: Dictionary[StringName, int] = {}
var quest_states: Dictionary[StringName, QuestState] = {}
var unlocked_regions: Array[StringName] = [&"sewer_region"]
var unlocked_exits: Array[StringName] = [&"sewer_gate"]
var unlocked_flags: Array[StringName] = []
var discovered_escape_points: Array[StringName] = []
var resident_states: Dictionary[StringName, Dictionary] = {&"milo": {"unlocked": true, "state": "idle"}}
var difficulty_id: StringName = &"normal"
var difficulty_overrides: Dictionary = {}
var survival_state: Dictionary = {"hunger": 100.0, "thirst": 100.0, "progression_reduction": 0.0}
var player_health: float = 100.0
var last_safe_position := Vector2(180.0, 500.0)
var last_message: String = ""

func _ready() -> void:
	_create_models()

func _process(delta: float) -> void:
	if not session_id.is_empty():
		play_time_seconds += delta
	if active_adventure != null:
		active_adventure.elapsed_seconds += delta

func _create_models() -> void:
	var resolver := Callable(ContentRegistry, "get_item")
	player_inventory = InventoryModel.new(12, resolver)
	equipment = EquipmentModel.new(resolver)
	settlement_storage = InventoryModel.new(48, resolver)
	protected_inventory = InventoryModel.new(8, resolver)
	player_inventory.changed.connect(inventory_changed.emit)
	settlement_storage.changed.connect(storage_changed.emit)

func start_new_game() -> void:
	session_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	play_time_seconds = 0.0
	player_stats = StatBlock.new()
	_create_models()
	facility_levels = {&"workbench": 0}
	quest_states.clear()
	unlocked_regions = [&"sewer_region"]
	unlocked_exits = [&"sewer_gate"]
	unlocked_flags.clear()
	discovered_escape_points.clear()
	resident_states = {&"milo": {"unlocked": true, "state": "idle"}}
	difficulty_id = &"normal"
	difficulty_overrides.clear()
	survival_state = {"hunger": 100.0, "thirst": 100.0, "progression_reduction": 0.0}
	player_health = 100.0
	last_safe_position = Vector2(180.0, 500.0)
	player_inventory.add_item(&"berry", 2)
	player_inventory.add_item(&"water_drop", 1)
	player_inventory.add_item(&"return_seed", 1)
	var weapon := ItemStack.new(&"twig_sword", 1)
	weapon.durability = 60
	equipment.equip(weapon)
	active_adventure = null
	last_message = "New journey started"
	session_reset.emit()

func current_difficulty() -> DifficultyDefinition:
	var original := ContentRegistry.get_definition(difficulty_id) as DifficultyDefinition
	if original == null:
		return null
	var effective := original.duplicate() as DifficultyDefinition
	for property_name in difficulty_overrides:
		if property_name in [&"enemy_health_multiplier", &"enemy_damage_multiplier", &"survival_drain_multiplier", &"loot_multiplier", &"inventory_loss", &"equipment_loss", &"recovery_policy", &"escape_display"]:
			effective.set(property_name, difficulty_overrides[property_name])
	return effective

func set_difficulty(id: StringName) -> bool:
	if not ContentRegistry.get_definition(id) is DifficultyDefinition:
		return false
	difficulty_id = id
	difficulty_changed.emit(id)
	return true

func set_difficulty_override(property_name: StringName, value: Variant) -> bool:
	if not property_name in [&"enemy_health_multiplier", &"enemy_damage_multiplier", &"survival_drain_multiplier", &"loot_multiplier", &"inventory_loss", &"equipment_loss", &"recovery_policy", &"escape_display"]:
		return false
	difficulty_overrides[property_name] = value
	difficulty_changed.emit(difficulty_id)
	return true

func clear_difficulty_override(property_name: StringName) -> void:
	difficulty_overrides.erase(property_name)
	difficulty_changed.emit(difficulty_id)

func start_quest(quest_id: StringName) -> bool:
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	if definition == null or quest_states.has(quest_id):
		return false
	var state := QuestState.new(quest_id)
	state.initialize(definition)
	quest_states[quest_id] = state
	quest_changed.emit(quest_id)
	last_message = "Quest started: %s" % definition.title
	return true

func report_quest_event(type: QuestObjectiveDefinition.ObjectiveType, target_id: StringName, amount: int = 1) -> void:
	for quest_id in quest_states:
		var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = quest_states[quest_id]
		if definition != null and state.apply_event(definition, type, target_id, amount):
			quest_changed.emit(quest_id)

func claim_quest_reward(quest_id: StringName) -> bool:
	var state: QuestState = quest_states.get(quest_id)
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	if state == null or definition == null or not state.completed or state.reward_claimed:
		return false
	for index in definition.reward_item_ids.size():
		settlement_storage.add_item(definition.reward_item_ids[index], definition.reward_amounts[index])
	state.reward_claimed = true
	quest_changed.emit(quest_id)
	last_message = "Quest reward claimed"
	return true

func begin_adventure(exit_id: StringName, region_id: StringName, entry_id: StringName) -> AdventureContext:
	if not unlocked_regions.has(region_id) or not unlocked_exits.has(exit_id):
		return null
	var context := AdventureContext.new(region_id, exit_id, entry_id, difficulty_id, session_id)
	context.prepared_inventory = player_inventory.to_array()
	active_adventure = AdventureSession.new(context, Callable(ContentRegistry, "get_item"))
	adventure_started.emit(context)
	return context

func collect_adventure_loot(item_id: StringName, amount: int) -> InventoryResult:
	if active_adventure == null:
		return InventoryResult.make(amount, 0, "no active adventure")
	var result := active_adventure.unsecured_loot.add_item(item_id, amount)
	if result.changed > 0:
		inventory_changed.emit()
	return result

func record_enemy_kill(enemy_id: StringName) -> void:
	if active_adventure == null:
		return
	active_adventure.record_kill(enemy_id)
	report_quest_event(QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, enemy_id)

func finish_adventure(result: AdventureSession.Result) -> String:
	if active_adventure == null:
		return "No active adventure"
	active_adventure.result = result
	var summary := ""
	if result == AdventureSession.Result.NORMAL_ESCAPE or result == AdventureSession.Result.RETURN_ITEM_ESCAPE:
		for stack in active_adventure.unsecured_loot.stacks():
			settlement_storage.add_item(stack.item_id, stack.quantity)
			report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, stack.item_id, stack.quantity)
		for point in active_adventure.discovered_escape_points:
			if not discovered_escape_points.has(point):
				discovered_escape_points.append(point)
		summary = "Expedition secured: %d loot stacks" % active_adventure.unsecured_loot.stacks().size()
	else:
		var difficulty := current_difficulty()
		var loss := DeathLossPolicy.apply(active_adventure.unsecured_loot.stacks(), difficulty, Callable(ContentRegistry, "get_item"))
		var carried_loss := DeathLossPolicy.apply(player_inventory.stacks(), difficulty, Callable(ContentRegistry, "get_item"))
		player_inventory.clear()
		for kept_carried in carried_loss.kept:
			player_inventory.add_item(kept_carried.item_id, kept_carried.quantity)
		var equipment_loss := DeathLossPolicy.apply_equipment(equipment.all_equipped(), difficulty)
		equipment.restore({})
		for kept_equipment in equipment_loss.equipment_kept:
			equipment.equip(kept_equipment)
		for stack in loss.kept:
			settlement_storage.add_item(stack.item_id, stack.quantity)
		summary = "Expedition lost: %d items" % (_sum_stacks(loss.lost) + _sum_stacks(carried_loss.lost))
	last_message = summary
	active_adventure = null
	adventure_finished.emit(result, summary)
	return summary

func discover_escape(point_id: StringName) -> void:
	if active_adventure != null:
		active_adventure.discover_escape(point_id)
		report_quest_event(QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT, point_id)

func can_upgrade_facility(facility_id: StringName) -> bool:
	var definition := ContentRegistry.get_definition(facility_id) as FacilityDefinition
	if definition == null:
		return false
	var next_level: int = int(facility_levels.get(facility_id, 0)) + 1
	var level_data := definition.get_level_data(next_level)
	if level_data == null or next_level > definition.max_level:
		return false
	for index in level_data.cost_item_ids.size():
		if settlement_storage.count(level_data.cost_item_ids[index]) < level_data.cost_amounts[index]:
			return false
	return true

func upgrade_facility(facility_id: StringName) -> bool:
	if not can_upgrade_facility(facility_id):
		last_message = "Not enough resources"
		return false
	var definition := ContentRegistry.get_definition(facility_id) as FacilityDefinition
	var next_level: int = int(facility_levels.get(facility_id, 0)) + 1
	var level_data := definition.get_level_data(next_level)
	for index in level_data.cost_item_ids.size():
		settlement_storage.remove_item(level_data.cost_item_ids[index], level_data.cost_amounts[index])
	facility_levels[facility_id] = next_level
	for flag in level_data.unlock_flags:
		if not unlocked_flags.has(flag):
			unlocked_flags.append(flag)
	report_quest_event(QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY, facility_id, 1)
	facility_changed.emit(facility_id, next_level)
	last_message = "%s upgraded to level %d" % [definition.display_name, next_level]
	return true

func export_state() -> Dictionary:
	var quests: Array[Dictionary] = []
	for state in quest_states.values():
		quests.append(state.to_dict())
	var facilities: Dictionary = {}
	for key in facility_levels:
		facilities[String(key)] = facility_levels[key]
	return {
		"session_id": session_id, "play_time_seconds": play_time_seconds,
		"player_stats": player_stats.to_dict(), "player_inventory": player_inventory.to_array(),
		"equipment": equipment.to_dict(), "settlement_storage": settlement_storage.to_array(),
		"protected_inventory": protected_inventory.to_array(), "facility_levels": facilities,
		"quests": quests, "unlocked_regions": _string_name_array(unlocked_regions),
		"unlocked_exits": _string_name_array(unlocked_exits), "unlocked_flags": _string_name_array(unlocked_flags), "discovered_escape_points": _string_name_array(discovered_escape_points),
		"resident_states": resident_states, "difficulty_id": String(difficulty_id),
		"difficulty_overrides": difficulty_overrides, "survival_state": survival_state, "player_health": player_health,
		"last_safe_position": [last_safe_position.x, last_safe_position.y]
	}

func restore_state(data: Dictionary) -> PackedStringArray:
	var errors := PackedStringArray()
	session_id = str(data.get("session_id", "restored"))
	play_time_seconds = float(data.get("play_time_seconds", 0.0))
	player_stats.restore(data.get("player_stats", {}))
	errors.append_array(player_inventory.restore(data.get("player_inventory", [])))
	equipment.restore(data.get("equipment", {}))
	errors.append_array(settlement_storage.restore(data.get("settlement_storage", [])))
	errors.append_array(protected_inventory.restore(data.get("protected_inventory", [])))
	facility_levels.clear()
	for key in data.get("facility_levels", {}):
		facility_levels[StringName(str(key))] = int(data["facility_levels"][key])
	quest_states.clear()
	for raw in data.get("quests", []):
		var state := QuestState.from_dict(raw)
		if ContentRegistry.get_definition(state.quest_id) is QuestDefinition:
			quest_states[state.quest_id] = state
		else:
			errors.append("unknown quest in save: %s" % state.quest_id)
	unlocked_regions = _to_string_names(data.get("unlocked_regions", []))
	unlocked_exits = _to_string_names(data.get("unlocked_exits", []))
	unlocked_flags = _to_string_names(data.get("unlocked_flags", []))
	discovered_escape_points = _to_string_names(data.get("discovered_escape_points", []))
	resident_states.clear()
	var raw_residents: Dictionary = data.get("resident_states", {})
	for resident_id in raw_residents:
		var resident_data: Dictionary = raw_residents[resident_id]
		resident_states[StringName(str(resident_id))] = resident_data
	difficulty_id = StringName(str(data.get("difficulty_id", "normal")))
	difficulty_overrides = data.get("difficulty_overrides", {})
	survival_state = data.get("survival_state", survival_state)
	player_health = float(data.get("player_health", player_stats.value(&"max_health")))
	var position: Array = data.get("last_safe_position", [180.0, 500.0])
	last_safe_position = Vector2(float(position[0]), float(position[1]))
	active_adventure = null
	session_reset.emit()
	return errors

func _sum_stacks(stacks: Array[ItemStack]) -> int:
	var total := 0
	for stack in stacks:
		total += stack.quantity
	return total

func _string_name_array(values: Array[StringName]) -> Array[String]:
	var result: Array[String] = []
	for value in values:
		result.append(String(value))
	return result

func _to_string_names(values: Array) -> Array[StringName]:
	var result: Array[StringName] = []
	for value in values:
		result.append(StringName(str(value)))
	return result
