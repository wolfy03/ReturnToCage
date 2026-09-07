extends Node

signal session_reset
signal inventory_changed
signal storage_changed
signal facility_changed(facility_id: StringName, level: int)
signal quest_changed(quest_id: StringName)
signal adventure_started(context: AdventureContext)
signal adventure_finished(result: AdventureSession.Result, summary: String)
signal difficulty_changed(id: StringName)

const DEFAULT_START_ID: StringName = &"default_game_start"

var session_id: String = ""
var play_time_seconds: float = 0.0
var last_message: String = ""
var player: PlayerState
var settlement: SettlementState
var progression: ProgressionState = ProgressionState.new()
var adventure: AdventureState = AdventureState.new()
var difficulty: DifficultyState = DifficultyState.new()

# Deprecated compatibility facade. These properties never own separate state.
# New callers should use the typed domain models directly.
var player_stats: StatBlock:
	get:
		return player.stats
	set(value):
		player.stats = value
var player_inventory: InventoryModel:
	get:
		return player.inventory
	set(value):
		if player.inventory != null and player.inventory.changed.is_connected(inventory_changed.emit):
			player.inventory.changed.disconnect(inventory_changed.emit)
		player.inventory = value
		_connect_model_signals()
var equipment: EquipmentModel:
	get:
		return player.equipment
	set(value):
		player.equipment = value
var settlement_storage: InventoryModel:
	get:
		return settlement.storage
	set(value):
		if settlement.storage != null and settlement.storage.changed.is_connected(storage_changed.emit):
			settlement.storage.changed.disconnect(storage_changed.emit)
		settlement.storage = value
		_connect_model_signals()
var protected_inventory: InventoryModel:
	get:
		return player.protected_inventory
	set(value):
		player.protected_inventory = value
var active_adventure: AdventureSession:
	get:
		return adventure.active_session
	set(value):
		adventure.active_session = value
var facility_levels: Dictionary[StringName, int]:
	get:
		return settlement.facility_levels
	set(value):
		settlement.facility_levels = value
var quest_states: Dictionary[StringName, QuestState]:
	get:
		return progression.quest_states
	set(value):
		progression.quest_states = value
var unlocked_regions: Array[StringName]:
	get:
		return progression.unlocked_regions
	set(value):
		progression.unlocked_regions = value
var unlocked_exits: Array[StringName]:
	get:
		return progression.unlocked_exits
	set(value):
		progression.unlocked_exits = value
var unlocked_flags: Array[StringName]:
	get:
		return progression.unlocked_flags
	set(value):
		progression.unlocked_flags = value
var discovered_escape_points: Array[StringName]:
	get:
		return progression.discovered_escape_points
	set(value):
		progression.discovered_escape_points = value
var resident_states: Dictionary[StringName, ResidentState]:
	get:
		return settlement.resident_states
	set(value):
		settlement.resident_states = value
var difficulty_id: StringName:
	get:
		return difficulty.id
	set(value):
		difficulty.id = value
var difficulty_overrides: Dictionary[StringName, Variant]:
	get:
		return difficulty.overrides
	set(value):
		difficulty.overrides = value
var player_health: float:
	get:
		return player.health
	set(value):
		player.health = value
var last_safe_position: Vector2:
	get:
		return player.last_safe_position
	set(value):
		player.last_safe_position = value

# Deprecated serialization adapter: getter returns a snapshot. Use player.survival
# for live typed mutations; assign a Dictionary only when adapting legacy callers.
var survival_state: Dictionary:
	get:
		return player.survival.to_dict()
	set(value):
		player.survival.restore(value)

func _ready() -> void:
	_create_models()
	var start: GameStartDefinition = get_start_definition()
	if start != null:
		_reset_states(start)

func _process(delta: float) -> void:
	if not session_id.is_empty():
		play_time_seconds += delta
	if adventure.active_session != null:
		adventure.active_session.elapsed_seconds += delta

func _create_models() -> void:
	var resolver := Callable(ContentRegistry, "get_item")
	if player == null:
		player = PlayerState.new(resolver)
	if settlement == null:
		settlement = SettlementState.new(resolver)
	_connect_model_signals()

func _connect_model_signals() -> void:
	if player != null and player.inventory != null and not player.inventory.changed.is_connected(inventory_changed.emit):
		player.inventory.changed.connect(inventory_changed.emit)
	if settlement != null and settlement.storage != null and not settlement.storage.changed.is_connected(storage_changed.emit):
		settlement.storage.changed.connect(storage_changed.emit)

func get_start_definition() -> GameStartDefinition:
	var start := ContentRegistry.get_definition(DEFAULT_START_ID) as GameStartDefinition
	if start == null:
		push_error("Missing or invalid GameStartDefinition: %s" % DEFAULT_START_ID)
		return null
	var errors: PackedStringArray = start.validate_definition(ContentRegistry)
	if not errors.is_empty():
		push_error("Invalid GameStartDefinition: %s" % "; ".join(errors))
		return null
	return start

func _reset_states(start: GameStartDefinition) -> void:
	player.reset(start, ContentRegistry)
	settlement.reset(start, ContentRegistry)
	progression.reset(start)
	difficulty.reset(start)
	adventure.reset()

func start_new_game() -> bool:
	var start: GameStartDefinition = get_start_definition()
	if start == null:
		return false
	_create_models()
	session_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	play_time_seconds = 0.0
	_reset_states(start)
	last_message = "New journey started"
	session_reset.emit()
	return true

func current_difficulty() -> DifficultyDefinition:
	return difficulty.effective(ContentRegistry)

func set_difficulty(id: StringName) -> bool:
	if not difficulty.set_id(id, ContentRegistry):
		return false
	difficulty_changed.emit(id)
	return true

func set_difficulty_override(property_name: StringName, value: Variant) -> bool:
	if not difficulty.set_override(property_name, value):
		return false
	difficulty_changed.emit(difficulty.id)
	return true

func clear_difficulty_override(property_name: StringName) -> void:
	difficulty.overrides.erase(property_name)
	difficulty_changed.emit(difficulty.id)

func start_quest(quest_id: StringName) -> bool:
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	if definition == null or progression.quest_states.has(quest_id):
		return false
	var state := QuestState.new(quest_id)
	state.initialize(definition)
	progression.quest_states[quest_id] = state
	quest_changed.emit(quest_id)
	last_message = "Quest started: %s" % definition.title
	return true

func report_quest_event(type: QuestObjectiveDefinition.ObjectiveType, target_id: StringName, amount: int = 1) -> void:
	for quest_id in progression.quest_states:
		var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = progression.quest_states[quest_id]
		if definition != null and state.apply_event(definition, type, target_id, amount):
			quest_changed.emit(quest_id)

func claim_quest_reward(quest_id: StringName) -> bool:
	var state: QuestState = progression.quest_states.get(quest_id)
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	if state == null or definition == null or not state.completed or state.reward_claimed:
		return false
	for index in definition.reward_item_ids.size():
		settlement.storage.add_item(definition.reward_item_ids[index], definition.reward_amounts[index])
	state.reward_claimed = true
	quest_changed.emit(quest_id)
	last_message = "Quest reward claimed"
	return true

func begin_adventure(exit_id: StringName, region_id: StringName, entry_id: StringName) -> AdventureContext:
	if not progression.unlocked_regions.has(region_id) or not progression.unlocked_exits.has(exit_id):
		return null
	var context := AdventureContext.new(region_id, exit_id, entry_id, difficulty.id, session_id)
	context.prepared_inventory = player.inventory.to_array()
	adventure.active_session = AdventureSession.new(context, Callable(ContentRegistry, "get_item"))
	adventure_started.emit(context)
	return context

func collect_adventure_loot(item_id: StringName, amount: int) -> InventoryResult:
	if adventure.active_session == null:
		return InventoryResult.make(amount, 0, "no active adventure")
	var result := adventure.active_session.unsecured_loot.add_item(item_id, amount)
	if result.changed > 0:
		inventory_changed.emit()
	return result

func record_enemy_kill(enemy_id: StringName) -> void:
	if adventure.active_session == null:
		return
	adventure.active_session.record_kill(enemy_id)
	report_quest_event(QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, enemy_id)

func finish_adventure(result: AdventureSession.Result) -> String:
	if adventure.active_session == null:
		return "No active adventure"
	adventure.active_session.result = result
	var summary := ""
	if result == AdventureSession.Result.NORMAL_ESCAPE or result == AdventureSession.Result.RETURN_ITEM_ESCAPE:
		for stack in adventure.active_session.unsecured_loot.stacks():
			settlement.storage.add_item(stack.item_id, stack.quantity)
			report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, stack.item_id, stack.quantity)
		for point in adventure.active_session.discovered_escape_points:
			if not progression.discovered_escape_points.has(point):
				progression.discovered_escape_points.append(point)
		summary = "Expedition secured: %d loot stacks" % adventure.active_session.unsecured_loot.stacks().size()
	else:
		var effective_difficulty := current_difficulty()
		var loss := DeathLossPolicy.apply(adventure.active_session.unsecured_loot.stacks(), effective_difficulty, Callable(ContentRegistry, "get_item"))
		var carried_loss := DeathLossPolicy.apply(player.inventory.stacks(), effective_difficulty, Callable(ContentRegistry, "get_item"))
		player.inventory.clear()
		for kept_carried in carried_loss.kept:
			player.inventory.add_item(kept_carried.item_id, kept_carried.quantity)
		var equipment_loss := DeathLossPolicy.apply_equipment(player.equipment.all_equipped(), effective_difficulty)
		player.equipment.restore({})
		for kept_equipment in equipment_loss.equipment_kept:
			player.equipment.equip(kept_equipment)
		for stack in loss.kept:
			settlement.storage.add_item(stack.item_id, stack.quantity)
		summary = "Expedition lost: %d items" % (_sum_stacks(loss.lost) + _sum_stacks(carried_loss.lost))
	last_message = summary
	adventure.active_session = null
	adventure_finished.emit(result, summary)
	return summary

func discover_escape(point_id: StringName) -> void:
	if adventure.active_session != null:
		adventure.active_session.discover_escape(point_id)
		report_quest_event(QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT, point_id)

func can_upgrade_facility(facility_id: StringName) -> bool:
	var definition := ContentRegistry.get_definition(facility_id) as FacilityDefinition
	if definition == null:
		return false
	var next_level: int = int(settlement.facility_levels.get(facility_id, 0)) + 1
	var level_data := definition.get_level_data(next_level)
	if level_data == null or next_level > definition.max_level:
		return false
	for index in level_data.cost_item_ids.size():
		if settlement.storage.count(level_data.cost_item_ids[index]) < level_data.cost_amounts[index]:
			return false
	return true

func upgrade_facility(facility_id: StringName) -> bool:
	if not can_upgrade_facility(facility_id):
		last_message = "Not enough resources"
		return false
	var definition := ContentRegistry.get_definition(facility_id) as FacilityDefinition
	var next_level: int = int(settlement.facility_levels.get(facility_id, 0)) + 1
	var level_data := definition.get_level_data(next_level)
	for index in level_data.cost_item_ids.size():
		settlement.storage.remove_item(level_data.cost_item_ids[index], level_data.cost_amounts[index])
	settlement.facility_levels[facility_id] = next_level
	for flag in level_data.unlock_flags:
		if not progression.unlocked_flags.has(flag):
			progression.unlocked_flags.append(flag)
	report_quest_event(QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY, facility_id, 1)
	facility_changed.emit(facility_id, next_level)
	last_message = "%s upgraded to level %d" % [definition.display_name, next_level]
	return true

func export_state() -> Dictionary:
	var result: Dictionary = {"session_id": session_id, "play_time_seconds": play_time_seconds}
	result.merge(player.to_save_dict())
	result.merge(settlement.to_save_dict())
	result.merge(progression.to_save_dict())
	result.merge(difficulty.to_save_dict())
	result.merge(adventure.to_save_dict())
	return result

func restore_state(data: Dictionary) -> PackedStringArray:
	var start: GameStartDefinition = get_start_definition()
	if start == null:
		return PackedStringArray(["Cannot restore session: invalid GameStartDefinition"])
	_create_models()
	var errors := PackedStringArray()
	session_id = SaveData.text_value(data, "session_id", "restored", errors)
	play_time_seconds = SaveData.number(data, "play_time_seconds", 0.0, errors)
	errors.append_array(player.restore(data, start))
	errors.append_array(settlement.restore(data, start, ContentRegistry))
	errors.append_array(progression.restore(data, ContentRegistry))
	errors.append_array(difficulty.restore(data, start, ContentRegistry))
	errors.append_array(adventure.restore(data))
	session_reset.emit()
	return errors

func _sum_stacks(stacks: Array[ItemStack]) -> int:
	var total := 0
	for stack in stacks:
		total += stack.quantity
	return total
