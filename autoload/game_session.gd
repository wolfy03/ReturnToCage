extends Node

signal session_reset
signal inventory_changed
signal storage_changed
signal facility_changed(facility_id: StringName, level: int)
signal quest_changed(quest_id: StringName)
signal adventure_started(context: AdventureContext)
signal adventure_finished(result: AdventureSession.Result, summary: String)
signal difficulty_changed(id: StringName)

signal phase_changed
signal player_respawned(result: RespawnResult)
enum Phase { MENU, SETTLEMENT, ADVENTURE, RESPAWNING }
var _phase: Phase = Phase.MENU
var _life_id: int = 0
var phase: Phase:
	get:
		return _phase
var last_death_result: RespawnResult

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
# Object/collection properties are getter-only; replacement would break model wiring.
# New callers should use the typed domain models directly.
var player_stats: StatBlock:
	get:
		return player.stats
var player_inventory: InventoryModel:
	get:
		return player.inventory
var equipment: EquipmentModel:
	get:
		return player.equipment
var settlement_storage: InventoryModel:
	get:
		return settlement.storage
var protected_inventory: InventoryModel:
	get:
		return player.protected_inventory
var active_adventure: AdventureSession:
	get:
		return adventure.active_session
var facility_levels: Dictionary[StringName, int]:
	get:
		return settlement.facility_levels
var quest_states: Dictionary[StringName, QuestState]:
	get:
		return progression.quest_states
var unlocked_regions: Array[StringName]:
	get:
		return progression.unlocked_regions
var unlocked_exits: Array[StringName]:
	get:
		return progression.unlocked_exits
var unlocked_flags: Array[StringName]:
	get:
		return progression.unlocked_flags
var discovered_escape_points: Array[StringName]:
	get:
		return progression.discovered_escape_points
var resident_states: Dictionary[StringName, ResidentState]:
	get:
		return settlement.resident_states
var difficulty_id: StringName:
	get:
		return difficulty.id
var difficulty_overrides: Dictionary[StringName, Variant]:
	get:
		return difficulty.overrides
var player_health: float:
	get:
		return player.health
	set(value):
		player.set_health(value)
var last_safe_position: Vector2:
	get:
		return player.last_safe_position

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
		if phase in [Phase.SETTLEMENT, Phase.ADVENTURE]:
			player.effects.tick(delta)
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

func get_start_definition(report_error: bool = true) -> GameStartDefinition:
	var start := ContentRegistry.get_definition(DEFAULT_START_ID) as GameStartDefinition
	if start == null:
		if report_error:
			push_error("Missing or invalid GameStartDefinition: %s" % DEFAULT_START_ID)
		return null
	var errors: PackedStringArray = start.validate_definition(ContentRegistry)
	if not errors.is_empty():
		if report_error:
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
	_life_id += 1
	_phase = Phase.MENU # Explicit new-session reset, not an in-session transition.
	last_death_result = null
	set_phase(Phase.SETTLEMENT)
	last_message = "New journey started"
	session_reset.emit()
	return true

func current_difficulty() -> DifficultyDefinition:
	if adventure.active_session != null and adventure.active_session.rules != null:
		return adventure.active_session.rules.effective()
	return difficulty.effective(ContentRegistry)

func set_phase(value: Phase) -> bool:
	if value == _phase:
		return value != Phase.ADVENTURE
	var allowed: bool = false
	match _phase:
		Phase.MENU:
			allowed = value == Phase.SETTLEMENT and not session_id.is_empty()
		Phase.SETTLEMENT:
			allowed = value in [Phase.MENU, Phase.RESPAWNING] or (value == Phase.ADVENTURE and adventure.active_session != null)
		Phase.ADVENTURE:
			allowed = value == Phase.RESPAWNING or (value == Phase.SETTLEMENT and adventure.active_session == null)
		Phase.RESPAWNING:
			allowed = value == Phase.SETTLEMENT and adventure.active_session == null and last_death_result != null and last_death_result.success
	if not allowed:
		last_message = "Invalid session phase transition: %s -> %s" % [_phase, value]
		return false
	_phase = value
	phase_changed.emit()
	return true


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
	var check: CommandResult = ProgressionService.check_quest_start(quest_id, progression, ContentRegistry)
	if not check.success:
		last_message = check.message
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
	# Compatibility API; detailed callers can inspect the transaction result.
	return claim_quest_reward_result(quest_id).success

func claim_quest_reward_result(quest_id: StringName) -> CommandResult:
	var state: QuestState = progression.quest_states.get(quest_id)
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	if state == null or definition == null or not state.begin_reward_claim():
		last_message = "Quest reward is unavailable"
		return CommandResult.make(false, last_message)
	var reward: CommandResult = settlement.storage.exchange([], ProgressionService.item_amounts(definition.reward_item_ids, definition.reward_amounts))
	state.finish_reward_claim(reward.success)
	if not reward.success:
		last_message = reward.message
		return reward
	quest_changed.emit(quest_id)
	for next_quest in definition.follow_up_quest_ids:
		start_quest(next_quest)
	last_message = "Quest reward claimed"
	return CommandResult.make(true, last_message)

func begin_adventure(exit_id: StringName, region_id: StringName, entry_id: StringName) -> AdventureContext:
	var check: CommandResult = can_use_exit(exit_id, region_id)
	var exit := ContentRegistry.get_definition(exit_id) as SettlementExitDefinition
	if not check.success or exit == null or entry_id != exit.entry_point_id:
		last_message = check.message if not check.success else "Invalid entry point"
		return null
	var context := AdventureContext.new(region_id, exit_id, entry_id, difficulty.id, session_id)
	context.prepared_inventory = player.inventory.to_array()
	adventure.active_session = AdventureSession.new(context, Callable(ContentRegistry, "get_item"))
	adventure.active_session.rules = AdventureRulesSnapshot.new(difficulty.effective(ContentRegistry))
	last_death_result = null
	set_phase(Phase.ADVENTURE)
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
	if result == AdventureSession.Result.DEATH:
		return handle_player_death(player.last_safe_position).summary()
	if result != AdventureSession.Result.NORMAL_ESCAPE and result != AdventureSession.Result.RETURN_ITEM_ESCAPE:
		return "An expedition must end through an escape or death"
	adventure.active_session.result = result
	var loot: Array[ItemStack] = adventure.active_session.unsecured_loot.stacks()
	var secured: CommandResult = settlement.secure_loot(loot)
	for stack in loot:
		report_quest_event(QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM, stack.item_id, stack.quantity)
	for point in adventure.active_session.discovered_escape_points:
		if not progression.discovered_escape_points.has(point):
			progression.discovered_escape_points.append(point)
	last_message = "Expedition secured: %d loot stacks" % loot.size() if secured.success else "Storage full: %d loot stacks retained in pending storage" % loot.size()
	adventure.active_session = null
	set_phase(Phase.SETTLEMENT)
	adventure_finished.emit(result, last_message)
	return last_message

func handle_player_death(death_position: Vector2, life_id: int = -1) -> RespawnResult:
	if life_id >= 0 and life_id != _life_id:
		return RespawnResult.failure("Ignored death callback from a retired actor")
	if last_death_result != null:
		return last_death_result
	if phase not in [Phase.SETTLEMENT, Phase.ADVENTURE]:
		return RespawnResult.failure("Death unavailable in this session phase")
	# Validate all dependencies before changing phase, pause flags or possessions.
	var start: GameStartDefinition = get_start_definition(false)
	var rules: DifficultyDefinition = current_difficulty()
	if start == null or rules == null or not death_position.is_finite():
		return RespawnResult.failure("Cannot resolve death: invalid start configuration, difficulty or position")
	if not set_phase(Phase.RESPAWNING):
		return RespawnResult.failure(last_message)
	player.effects.paused = true
	last_death_result = DeathResolutionService.resolve(player, settlement, adventure, rules, death_position, start.respawn_policy, start.survival_config, session_id, Callable(ContentRegistry, "get_item"))
	adventure.active_session = null
	last_message = last_death_result.summary()
	adventure_finished.emit(AdventureSession.Result.DEATH, last_message)
	player_respawned.emit(last_death_result)
	return last_death_result

func complete_respawn() -> void:
	if phase == Phase.RESPAWNING and set_phase(Phase.SETTLEMENT):
		player.effects.paused = false

func arm_player_life() -> int:
	# Each actor receives a transient generation token; late signals from a retired
	# actor cannot affect a new life even after last_death_result is cleared.
	if phase in [Phase.SETTLEMENT, Phase.ADVENTURE]:
		_life_id += 1
		last_death_result = null
		player.effects.paused = false
	return _life_id

func is_current_life(life_id: int) -> bool:
	return life_id == _life_id

func can_use_exit(exit_id: StringName, region_id: StringName) -> CommandResult:
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Exit use requires settlement state")
	return ExitService.check(exit_id, region_id, progression, settlement, adventure, ContentRegistry)

func request_adventure_from_exit(exit_id: StringName, region_id: StringName) -> AdventureContext:
	var exit := ContentRegistry.get_definition(exit_id) as SettlementExitDefinition
	return begin_adventure(exit_id, region_id, exit.entry_point_id) if exit != null else null

func claim_pending_loot() -> CommandResult:
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Pending loot is available in the settlement")
	var result: CommandResult = settlement.claim_pending_loot()
	last_message = "Pending loot claimed" if result.success else result.message
	storage_changed.emit()
	return result

func craft(recipe_id: StringName) -> CommandResult:
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Crafting requires settlement state")
	var result: CommandResult = CraftingService.craft(ContentRegistry.get_definition(recipe_id) as RecipeDefinition, settlement, progression)
	last_message = "Crafted %s" % recipe_id if result.success else result.message
	return result

func discover_escape(point_id: StringName) -> void:
	if adventure.active_session != null:
		adventure.active_session.discover_escape(point_id)
		report_quest_event(QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT, point_id)

func can_upgrade_facility(facility_id: StringName) -> bool:
	var check: CommandResult = ProgressionService.facility_check(facility_id, settlement, progression, ContentRegistry)
	if not check.success:
		last_message = check.message
	return check.success

func upgrade_facility(facility_id: StringName) -> bool:
	if not can_upgrade_facility(facility_id):
		return false
	var definition := ContentRegistry.get_definition(facility_id) as FacilityDefinition
	var next_level: int = settlement.facility_levels.get(facility_id, 0) + 1
	var level: FacilityLevelDefinition = definition.get_level_data(next_level)
	var result: CommandResult = settlement.storage.exchange(ProgressionService.item_amounts(level.cost_item_ids, level.cost_amounts), [])
	if not result.success:
		last_message = result.message
		return false
	settlement.facility_levels[facility_id] = next_level
	for flag in level.unlock_flags:
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
	if adventure.active_session != null or phase == Phase.RESPAWNING:
		return PackedStringArray(["Restore unavailable during expedition or respawn"])
	var snapshot: SessionSnapshot = prepare_restore(data)
	if not snapshot.fatal_error.is_empty():
		return PackedStringArray([snapshot.fatal_error])
	apply_snapshot(snapshot)
	return snapshot.warnings

func prepare_restore(data: Dictionary) -> SessionSnapshot:
	var start: GameStartDefinition = get_start_definition()
	if start == null:
		var failed := SessionSnapshot.new()
		failed.fatal_error = "Invalid start configuration"
		return failed
	return SessionSnapshot.build(data, start, ContentRegistry)

func apply_snapshot(snapshot: SessionSnapshot) -> void:
	if adventure.active_session != null or phase == Phase.RESPAWNING or not snapshot.fatal_error.is_empty():
		return
	if player.inventory.changed.is_connected(inventory_changed.emit):
		player.inventory.changed.disconnect(inventory_changed.emit)
	if settlement.storage.changed.is_connected(storage_changed.emit):
		settlement.storage.changed.disconnect(storage_changed.emit)
	player = snapshot.player
	settlement = snapshot.settlement
	progression = snapshot.progression
	difficulty = snapshot.difficulty
	adventure = snapshot.adventure
	session_id = snapshot.session_id
	play_time_seconds = snapshot.play_time_seconds
	last_death_result = null
	_life_id += 1
	_connect_model_signals()
	set_phase(Phase.SETTLEMENT)
	session_reset.emit()
