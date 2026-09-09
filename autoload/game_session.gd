extends Node

signal session_reset
# Local-player UI compatibility signal. Peer-specific runtime consumers use the
# player_health_changed/player_life_changed signals below.
signal inventory_changed
# Shared, server-owned session model signals.
signal storage_changed
signal facility_changed(facility_id: StringName, level: int)
signal quest_changed(quest_id: StringName)
signal adventure_started(context: AdventureContext)
signal adventure_finished(result: AdventureSession.Result, summary: String)
signal difficulty_changed(id: StringName)

signal phase_changed
signal player_died(peer_id: int, result: RespawnResult)
signal player_respawned(peer_id: int, result: RespawnResult)
signal player_health_changed(peer_id: int, health: float, max_health: float)
signal player_life_changed(peer_id: int, life_id: int, life_phase: int)
signal player_registered(peer_id: int, state: PlayerState)
signal player_unregistered(peer_id: int)
# RESPAWNING remains only for the offline scene-transition compatibility path.
enum Phase { MENU, SETTLEMENT, ADVENTURE, RESPAWNING }
var _phase: Phase = Phase.MENU
var _player_runtime: Dictionary[int, PlayerRuntimeState] = {}
var _applying_runtime_snapshot: bool = false
var phase: Phase:
	get:
		return _phase
var last_death_result: RespawnResult:
	get:
		return get_player_death_result(get_local_peer_id())

const DEFAULT_START_ID: StringName = &"default_game_start"
const LOCAL_SINGLEPLAYER_PEER_ID := 1

var session_id: String = ""
var play_time_seconds: float = 0.0
var last_message: String = ""
# Read as the canonical registry; mutate membership only through register_player,
# unregister_player, restore, or reset_to_offline_local_player.
var players: Dictionary[int, PlayerState] = {}
var player: PlayerState:
	get:
		return get_local_player()
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
	if not NetworkManager.is_authoritative_simulation():
		return
	if not session_id.is_empty():
		play_time_seconds += delta
		if phase in [Phase.SETTLEMENT, Phase.ADVENTURE]:
			for peer_id in players:
				var runtime := get_player_runtime(peer_id)
				if runtime != null and runtime.life_phase == PlayerRuntimeState.LifePhase.ALIVE:
					players[peer_id].effects.tick(delta)
	if adventure.active_session != null:
		adventure.active_session.elapsed_seconds += delta

func _create_models() -> void:
	if not has_player(get_local_peer_id()):
		_add_player_state(get_local_peer_id(), _create_player_state())
	if settlement == null:
		settlement = SettlementState.new(Callable(ContentRegistry, "get_item"))
	_connect_model_signals()

func _create_player_state() -> PlayerState:
	return PlayerState.new(Callable(ContentRegistry, "get_item"))

func get_local_peer_id() -> int:
	return NetworkManager.local_peer_id() if NetworkManager != null else LOCAL_SINGLEPLAYER_PEER_ID

func get_local_player() -> PlayerState:
	return players.get(get_local_peer_id())

func has_player(peer_id: int) -> bool:
	return players.has(peer_id)

func get_player(peer_id: int) -> PlayerState:
	return players.get(peer_id)

func register_player(peer_id: int) -> PlayerState:
	if peer_id <= 0:
		return null
	if players.has(peer_id):
		return players[peer_id]
	var state := _create_player_state()
	var start := get_start_definition(false)
	if start != null:
		state.reset(start, ContentRegistry)
	_add_player_state(peer_id, state)
	if adventure.active_session != null:
		adventure.active_session.register_player(peer_id, Callable(ContentRegistry, "get_item"))
	if peer_id == get_local_peer_id():
		_connect_model_signals()
	player_registered.emit(peer_id, state)
	return state

func unregister_player(peer_id: int) -> void:
	if not players.has(peer_id):
		return
	_disconnect_player_state_signals(peer_id, players[peer_id])
	players[peer_id].effects.paused = true
	players.erase(peer_id)
	_player_runtime.erase(peer_id)
	if adventure.active_session != null:
		# Disconnect policy: without reconnect persistence, this peer forfeits its
		# unsecured expedition loot while every other peer remains untouched.
		adventure.active_session.discard_player_adventure(peer_id)
	player_unregistered.emit(peer_id)

func _add_player_state(peer_id: int, state: PlayerState) -> void:
	players[peer_id] = state
	_player_runtime[peer_id] = PlayerRuntimeState.new(peer_id)
	_connect_player_state_signals(peer_id, state)

func _connect_player_state_signals(peer_id: int, state: PlayerState) -> void:
	var callback := _on_player_vitals_changed.bind(peer_id)
	if not state.vitals_changed.is_connected(callback):
		state.vitals_changed.connect(callback)

func _disconnect_player_state_signals(peer_id: int, state: PlayerState) -> void:
	var callback := _on_player_vitals_changed.bind(peer_id)
	if state.vitals_changed.is_connected(callback):
		state.vitals_changed.disconnect(callback)

func _on_player_vitals_changed(peer_id: int) -> void:
	if _applying_runtime_snapshot:
		return
	var state := get_player(peer_id)
	if state != null:
		player_health_changed.emit(peer_id, state.health, maxf(1.0, state.stats.value(&"max_health")))

func get_player_runtime(peer_id: int) -> PlayerRuntimeState:
	return _player_runtime.get(peer_id)

func get_player_life_id(peer_id: int) -> int:
	var runtime := get_player_runtime(peer_id)
	return runtime.life_id if runtime != null else -1

func get_player_life_phase(peer_id: int) -> int:
	var runtime := get_player_runtime(peer_id)
	return int(runtime.life_phase) if runtime != null else -1

func get_player_death_result(peer_id: int) -> RespawnResult:
	var runtime := get_player_runtime(peer_id)
	return runtime.death_result if runtime != null else null

func _connect_model_signals() -> void:
	if player != null and player.inventory != null and not player.inventory.changed.is_connected(inventory_changed.emit):
		player.inventory.changed.connect(inventory_changed.emit)
	if settlement != null and settlement.storage != null and not settlement.storage.changed.is_connected(storage_changed.emit):
		settlement.storage.changed.connect(storage_changed.emit)

func _disconnect_player_model_signals() -> void:
	for peer_id in players:
		var state: PlayerState = players[peer_id]
		if state.inventory != null and state.inventory.changed.is_connected(inventory_changed.emit):
			state.inventory.changed.disconnect(inventory_changed.emit)
		_disconnect_player_state_signals(peer_id, state)

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
	for state in players.values():
		state.reset(start, ContentRegistry)
	settlement.reset(start, ContentRegistry)
	progression.reset(start)
	difficulty.reset(start)
	adventure.reset()

func start_new_game() -> bool:
	if not NetworkManager.is_authoritative_simulation():
		last_message = "Only the host can start a multiplayer session"
		return false
	var start: GameStartDefinition = get_start_definition()
	if start == null:
		return false
	_disconnect_player_model_signals()
	players.clear()
	_player_runtime.clear()
	_create_models()
	session_id = "%s-%s" % [Time.get_unix_time_from_system(), randi()]
	play_time_seconds = 0.0
	_reset_states(start)
	_phase = Phase.MENU # Explicit new-session reset, not an in-session transition.
	set_phase(Phase.SETTLEMENT)
	last_message = "New journey started"
	session_reset.emit()
	return true

func current_difficulty() -> DifficultyDefinition:
	if adventure.active_session != null and adventure.active_session.rules != null:
		return adventure.active_session.rules.effective()
	return difficulty.effective(ContentRegistry)

func can_mutate_authoritative_state() -> bool:
	return NetworkManager.is_authoritative_simulation()

func set_phase(value: Phase) -> bool:
	if not can_mutate_authoritative_state():
		return false
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
	if not can_mutate_authoritative_state():
		return false
	if not difficulty.set_id(id, ContentRegistry):
		return false
	difficulty_changed.emit(id)
	return true

func set_difficulty_override(property_name: StringName, value: Variant) -> bool:
	if not can_mutate_authoritative_state():
		return false
	if not difficulty.set_override(property_name, value):
		return false
	difficulty_changed.emit(difficulty.id)
	return true

func clear_difficulty_override(property_name: StringName) -> void:
	if not can_mutate_authoritative_state():
		return
	difficulty.overrides.erase(property_name)
	difficulty_changed.emit(difficulty.id)

func start_quest(quest_id: StringName) -> bool:
	if not can_mutate_authoritative_state():
		return false
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
	if not can_mutate_authoritative_state():
		return
	for quest_id in progression.quest_states:
		var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = progression.quest_states[quest_id]
		if definition != null and state.apply_event(definition, type, target_id, amount):
			quest_changed.emit(quest_id)

func claim_quest_reward(quest_id: StringName) -> bool:
	# Compatibility API; detailed callers can inspect the transaction result.
	return claim_quest_reward_result(quest_id).success

func claim_quest_reward_result(quest_id: StringName) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can change quest state")
	var state: QuestState = progression.quest_states.get(quest_id)
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	if state == null or definition == null or not state.begin_reward_claim():
		last_message = "Quest reward is unavailable"
		return CommandResult.make(false, last_message)
	var reward_storage: InventoryModel = settlement.storage
	reward_storage.begin_update()
	var reward: CommandResult = reward_storage.exchange([], ProgressionService.item_amounts(definition.reward_item_ids, definition.reward_amounts))
	state.finish_reward_claim(reward.success)
	reward_storage.end_update()
	if not reward.success:
		last_message = reward.message
		return reward
	quest_changed.emit(quest_id)
	for next_quest in definition.follow_up_quest_ids:
		start_quest(next_quest)
	last_message = "Quest reward claimed"
	return CommandResult.make(true, last_message)

func begin_adventure(exit_id: StringName, region_id: StringName, entry_id: StringName) -> AdventureContext:
	if not can_mutate_authoritative_state():
		return null
	var check: CommandResult = can_use_exit(exit_id, region_id)
	var exit := ContentRegistry.get_definition(exit_id) as SettlementExitDefinition
	if not check.success or exit == null or entry_id != exit.entry_point_id:
		last_message = check.message if not check.success else "Invalid entry point"
		return null
	var context := AdventureContext.new(region_id, exit_id, entry_id, difficulty.id, session_id)
	context.prepared_inventory = player.inventory.to_array()
	adventure.active_session = AdventureSession.new(context, Callable(ContentRegistry, "get_item"))
	adventure.active_session.set_compatibility_peer_id(get_local_peer_id(), Callable(ContentRegistry, "get_item"))
	for peer_id in players:
		adventure.active_session.register_player(peer_id, Callable(ContentRegistry, "get_item"))
	adventure.active_session.rules = AdventureRulesSnapshot.new(difficulty.effective(ContentRegistry))
	var runtime := get_player_runtime(get_local_peer_id())
	if runtime != null:
		runtime.death_result = null
	set_phase(Phase.ADVENTURE)
	adventure_started.emit(context)
	return context

func collect_adventure_loot(item_id: StringName, amount: int, peer_id: int = -1) -> InventoryResult:
	if not can_mutate_authoritative_state():
		return InventoryResult.make(amount, 0, "Only the server can collect loot")
	if adventure.active_session == null:
		return InventoryResult.make(amount, 0, "no active adventure")
	var owner_peer_id := get_local_peer_id() if peer_id < 0 else peer_id
	var personal := adventure.active_session.get_player_adventure(owner_peer_id)
	if personal == null:
		return InventoryResult.make(amount, 0, "unknown adventure player")
	var result := personal.unsecured_loot.add_item(item_id, amount)
	if result.changed > 0:
		inventory_changed.emit()
	return result

func record_enemy_kill(enemy_id: StringName) -> void:
	if not can_mutate_authoritative_state():
		return
	if adventure.active_session == null:
		return
	# Temporary phase-2 policy: kill credit is party-shared. Personal/PARTY/WORLD
	# quest ownership is intentionally deferred to phase 3.
	adventure.active_session.record_kill(enemy_id)
	report_quest_event(QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, enemy_id)

func finish_adventure(result: AdventureSession.Result) -> String:
	if not can_mutate_authoritative_state():
		return "Only the server can finish an adventure"
	if adventure.active_session == null:
		return "No active adventure"
	if result == AdventureSession.Result.DEATH:
		return handle_player_death(get_local_peer_id(), player.last_safe_position).summary()
	if result != AdventureSession.Result.NORMAL_ESCAPE and result != AdventureSession.Result.RETURN_ITEM_ESCAPE:
		return "An expedition must end through an escape or death"
	adventure.active_session.result = result
	# Temporary party-wide finish policy. Future individual extraction should be a
	# separate finish_player_adventure(peer_id) operation, not an implicit branch.
	var loot: Array[ItemStack] = []
	for personal in adventure.active_session.player_adventures.values():
		loot.append_array((personal as PlayerAdventureState).unsecured_loot.stacks())
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

func handle_player_death(peer_id: int, death_position: Vector2, life_id: int = -1) -> RespawnResult:
	if not can_mutate_authoritative_state():
		return RespawnResult.failure("Only the server can resolve player death")
	var state := get_player(peer_id)
	var runtime := get_player_runtime(peer_id)
	if state == null or runtime == null:
		return RespawnResult.failure("Unknown player peer")
	var expected_life_id := runtime.life_id if life_id < 0 else life_id
	if not is_current_life(peer_id, expected_life_id):
		return RespawnResult.failure("Ignored death callback from a retired actor")
	if runtime.death_result != null:
		return runtime.death_result
	if phase not in [Phase.SETTLEMENT, Phase.ADVENTURE]:
		return RespawnResult.failure("Death unavailable in this session phase")
	# Validate all dependencies before changing phase, pause flags or possessions.
	var start: GameStartDefinition = get_start_definition(false)
	var rules: DifficultyDefinition = current_difficulty()
	if start == null or rules == null or not death_position.is_finite():
		return RespawnResult.failure("Cannot resolve death: invalid start configuration, difficulty or position")
	var individual_multiplayer_death := NetworkManager.is_multiplayer_active()
	if not individual_multiplayer_death and not set_phase(Phase.RESPAWNING):
		return RespawnResult.failure(last_message)
	runtime.life_phase = PlayerRuntimeState.LifePhase.DEAD
	state.effects.paused = true
	player_life_changed.emit(peer_id, runtime.life_id, runtime.life_phase)
	var personal_adventure := adventure.active_session.get_player_adventure(peer_id) if adventure.active_session != null else null
	runtime.death_result = DeathResolutionService.resolve(state, settlement, adventure, rules, death_position, start.respawn_policy, start.survival_config, session_id, Callable(ContentRegistry, "get_item"), not individual_multiplayer_death, personal_adventure, peer_id)
	runtime.life_phase = PlayerRuntimeState.LifePhase.RESPAWNING
	last_message = runtime.death_result.summary()
	player_life_changed.emit(peer_id, runtime.life_id, runtime.life_phase)
	player_died.emit(peer_id, runtime.death_result)
	if not individual_multiplayer_death:
		adventure.active_session = null
		adventure_finished.emit(AdventureSession.Result.DEATH, last_message)
	return runtime.death_result

func complete_respawn(peer_id: int) -> void:
	if not can_mutate_authoritative_state():
		return
	var state := get_player(peer_id)
	if state == null:
		return
	if not NetworkManager.is_multiplayer_active() and phase == Phase.RESPAWNING and set_phase(Phase.SETTLEMENT):
		state.effects.paused = false

func arm_player_life(peer_id: int) -> int:
	# Each actor receives a transient generation token; late signals from a retired
	# actor cannot affect a new life after its peer-specific result is cleared.
	if phase in [Phase.SETTLEMENT, Phase.ADVENTURE]:
		var state := get_player(peer_id)
		var runtime := get_player_runtime(peer_id)
		if state == null or runtime == null:
			return -1
		var completed_result := runtime.death_result
		runtime.life_id += 1
		runtime.life_phase = PlayerRuntimeState.LifePhase.ALIVE
		runtime.death_result = null
		state.effects.paused = false
		player_life_changed.emit(peer_id, runtime.life_id, runtime.life_phase)
		if completed_result != null:
			player_respawned.emit(peer_id, completed_result)
		return runtime.life_id
	return -1

func is_current_life(peer_id: int, life_id: int) -> bool:
	var runtime := get_player_runtime(peer_id)
	return runtime != null and runtime.life_id == life_id

func apply_player_runtime_snapshot(snapshot: PlayerRuntimeSnapshot) -> bool:
	if NetworkManager.is_server() or snapshot == null or not snapshot.error_message.is_empty() or not has_player(snapshot.peer_id):
		return false
	if not is_finite(snapshot.health) or not is_finite(snapshot.max_health) \
		or snapshot.max_health <= 0.0 or snapshot.health < 0.0 or snapshot.health > snapshot.max_health:
		return false
	var runtime := get_player_runtime(snapshot.peer_id)
	var state := get_player(snapshot.peer_id)
	if runtime == null or state == null or snapshot.life_id < runtime.life_id:
		return false
	runtime.life_id = snapshot.life_id
	runtime.life_phase = snapshot.life_phase as PlayerRuntimeState.LifePhase
	_applying_runtime_snapshot = true
	var applied := state.apply_replicated_health(snapshot.health, snapshot.max_health)
	_applying_runtime_snapshot = false
	if not applied:
		return false
	player_life_changed.emit(snapshot.peer_id, runtime.life_id, runtime.life_phase)
	player_health_changed.emit(snapshot.peer_id, snapshot.health, snapshot.max_health)
	return true

func can_use_exit(exit_id: StringName, region_id: StringName) -> CommandResult:
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Exit use requires settlement state")
	return ExitService.check(exit_id, region_id, progression, settlement, adventure, ContentRegistry)

func request_adventure_from_exit(exit_id: StringName, region_id: StringName) -> AdventureContext:
	var exit := ContentRegistry.get_definition(exit_id) as SettlementExitDefinition
	return begin_adventure(exit_id, region_id, exit.entry_point_id) if exit != null else null

func claim_pending_loot() -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can claim loot")
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Pending loot is available in the settlement")
	var result: CommandResult = settlement.claim_pending_loot()
	last_message = "Pending loot claimed" if result.success else result.message
	return result

func craft(recipe_id: StringName) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can craft")
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Crafting requires settlement state")
	var result: CommandResult = CraftingService.craft(ContentRegistry.get_definition(recipe_id) as RecipeDefinition, settlement, progression)
	last_message = "Crafted %s" % recipe_id if result.success else result.message
	return result

func discover_escape(point_id: StringName) -> void:
	if not can_mutate_authoritative_state():
		return
	if adventure.active_session != null:
		adventure.active_session.discover_escape(point_id)
		report_quest_event(QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT, point_id)

func can_upgrade_facility(facility_id: StringName) -> bool:
	if not can_mutate_authoritative_state():
		return false
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

func to_network_snapshot(protocol_version: int) -> Dictionary:
	var peer_ids: Array[int] = []
	peer_ids.assign(players.keys())
	peer_ids.sort()
	return {
		"protocol_version": protocol_version,
		"session_id": session_id,
		"phase": int(_phase),
		"difficulty_id": String(difficulty.id),
		"players": peer_ids,
	}

func apply_network_snapshot(snapshot: NetworkSessionSnapshot) -> bool:
	if NetworkManager.is_server() or snapshot == null or not snapshot.error_message.is_empty():
		return false
	if snapshot.phase < Phase.MENU or snapshot.phase > Phase.RESPAWNING:
		return false
	var start := get_start_definition()
	if start == null:
		return false
	_disconnect_player_model_signals()
	players.clear()
	_player_runtime.clear()
	settlement.reset(start, ContentRegistry)
	progression.reset(start)
	difficulty.reset(start)
	adventure.reset()
	for peer_id in snapshot.player_ids:
		register_player(peer_id)
	if get_local_player() == null or not difficulty.set_id(snapshot.difficulty_id, ContentRegistry):
		return false
	session_id = snapshot.session_id
	play_time_seconds = 0.0
	_phase = snapshot.phase as Phase
	_connect_model_signals()
	phase_changed.emit()
	session_reset.emit()
	return true

func reset_to_offline_local_player(previous_local_peer_id: int) -> void:
	var retained_state := get_player(previous_local_peer_id)
	if retained_state == null:
		retained_state = get_player(LOCAL_SINGLEPLAYER_PEER_ID)
	var retired_peer_ids: Array[int] = []
	retired_peer_ids.assign(players.keys())
	_disconnect_player_model_signals()
	for state in players.values():
		if state != retained_state:
			state.effects.paused = true
	players.clear()
	_player_runtime.clear()
	if retained_state == null:
		retained_state = _create_player_state()
		var start := get_start_definition(false)
		if start != null:
			retained_state.reset(start, ContentRegistry)
	_add_player_state(LOCAL_SINGLEPLAYER_PEER_ID, retained_state)
	retained_state.effects.paused = false
	session_id = ""
	play_time_seconds = 0.0
	_phase = Phase.MENU
	_connect_model_signals()
	for peer_id in retired_peer_ids:
		if previous_local_peer_id != LOCAL_SINGLEPLAYER_PEER_ID or peer_id != LOCAL_SINGLEPLAYER_PEER_ID:
			player_unregistered.emit(peer_id)
	phase_changed.emit()

# Compatibility entry point for older menu code. NetworkManager owns transport
# teardown and passes the pre-disconnect local id to the explicit API above.
func end_network_session() -> void:
	reset_to_offline_local_player(get_local_peer_id())

func restore_state(data: Dictionary) -> PackedStringArray:
	if not can_mutate_authoritative_state():
		return PackedStringArray(["Only the server can restore session state"])
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
	_disconnect_player_model_signals()
	if settlement.storage.changed.is_connected(storage_changed.emit):
		settlement.storage.changed.disconnect(storage_changed.emit)
	players.clear()
	_player_runtime.clear()
	_add_player_state(get_local_peer_id(), snapshot.player)
	settlement = snapshot.settlement
	progression = snapshot.progression
	difficulty = snapshot.difficulty
	adventure = snapshot.adventure
	session_id = snapshot.session_id
	play_time_seconds = snapshot.play_time_seconds
	_connect_model_signals()
	set_phase(Phase.SETTLEMENT)
	session_reset.emit()
