extends Node

signal session_reset
# Local-player UI compatibility signal. Peer-specific runtime consumers use the
# player_health_changed/player_life_changed signals below.
signal inventory_changed
# Shared, server-owned session model signals.
signal storage_changed
signal facility_changed(facility_id: StringName, level: int)
signal resident_changed(resident_id: StringName)
signal settlement_state_changed(revision: int)
signal shared_progression_changed(revision: int)
signal quest_changed(quest_id: StringName)
signal quest_state_changed(quest_id: StringName, scope: int, owner_player_id: StringName, revision: int)
signal player_item_state_changed(player_id: StringName, revision: int)
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
const LOCAL_EVENT_ACTOR: StringName = &"__local_player__"

var session_id: String = ""
var play_time_seconds: float = 0.0
var last_message: String = ""
# Active peer attachment view. Canonical PlayerState ownership is keyed by the
# persistent logical player_id in _player_states_by_id.
var players: Dictionary[int, PlayerState] = {}
var _player_states_by_id: Dictionary[StringName, PlayerState] = {}
var _attached_player_ids: Dictionary[int, StringName] = {}
var _player_vitals_callbacks: Dictionary[int, Callable] = {}
var _player_item_callbacks: Dictionary[int, Callable] = {}
var player: PlayerState:
	get:
		return get_local_player()
var settlement: SettlementState
var progression: ProgressionState = ProgressionState.new()
var adventure: AdventureState = AdventureState.new()
var difficulty: DifficultyState = DifficultyState.new()
var _quest_system: QuestSystem
var _settlement_command_service: SettlementCommandService
var _player_item_command_service: PlayerItemCommandService

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
	_create_quest_system()
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
		_add_player_state(get_local_peer_id(), get_player_id(get_local_peer_id()), _create_player_state())
	if settlement == null:
		settlement = SettlementState.new(
			Callable(ContentRegistry, "get_item"),
			Callable(self, "can_mutate_authoritative_state")
		)
	progression.set_mutation_guard(Callable(self, "can_mutate_authoritative_state"))
	_connect_model_signals()

func _create_quest_system() -> void:
	if _quest_system != null and _quest_system.quest_mutated.is_connected(_on_quest_mutated):
		_quest_system.quest_mutated.disconnect(_on_quest_mutated)
	_quest_system = QuestSystem.new(progression, settlement, ContentRegistry, Callable(self, "get_player_state_by_player_id"))
	_quest_system.quest_mutated.connect(_on_quest_mutated)
	_settlement_command_service = SettlementCommandService.new(
		settlement,
		progression,
		ContentRegistry,
		Callable(self, "report_gameplay_event")
	)
	_player_item_command_service = PlayerItemCommandService.new(ContentRegistry)

func _on_quest_mutated(quest_id: StringName, scope: int, owner_player_id: StringName, revision: int) -> void:
	quest_changed.emit(quest_id)
	quest_state_changed.emit(quest_id, scope, owner_player_id, revision)

func _create_player_state() -> PlayerState:
	return PlayerState.new(
		Callable(ContentRegistry, "get_item"),
		Callable(self, "can_mutate_authoritative_state")
	)

func get_local_peer_id() -> int:
	return NetworkManager.local_peer_id() if NetworkManager != null else LOCAL_SINGLEPLAYER_PEER_ID

func get_local_player() -> PlayerState:
	return players.get(get_local_peer_id())

func get_player_id(peer_id: int) -> StringName:
	var attached: StringName = _attached_player_ids.get(peer_id, &"")
	if not attached.is_empty():
		return attached
	var mapped := NetworkManager.player_id_for_peer(peer_id) if NetworkManager != null else &""
	if not mapped.is_empty():
		return mapped
	return NetworkManager.local_profile_player_id() \
		if peer_id == LOCAL_SINGLEPLAYER_PEER_ID and not NetworkManager.is_multiplayer_active() else &""

func get_local_player_id() -> StringName:
	return get_player_id(get_local_peer_id())

func get_player_state_by_player_id(player_id: StringName) -> PlayerState:
	return _player_states_by_id.get(player_id) if not player_id.is_empty() else null

func has_persistent_player(player_id: StringName) -> bool:
	return not player_id.is_empty() and _player_states_by_id.has(player_id)

func get_persistent_player(player_id: StringName) -> PlayerState:
	return get_player_state_by_player_id(player_id)

func persistent_player_count() -> int:
	return _player_states_by_id.size()

func has_player(peer_id: int) -> bool:
	return players.has(peer_id)

func get_player(peer_id: int) -> PlayerState:
	return players.get(peer_id)

func register_player(peer_id: int) -> PlayerState:
	return attach_player(peer_id, get_player_id(peer_id))

func attach_player(peer_id: int, player_id: StringName) -> PlayerState:
	if peer_id <= 0 or player_id.is_empty():
		return null
	if players.has(peer_id):
		return players[peer_id] if get_player_id(peer_id) == player_id else null
	if _attached_player_ids.values().has(player_id):
		return null
	var state: PlayerState = _player_states_by_id.get(player_id)
	if state == null:
		state = _create_player_state()
		var start := get_start_definition(false)
		if start != null:
			state.reset(start, ContentRegistry)
		if NetworkManager.is_session_connected() and not NetworkManager.is_server():
			state.prepare_network_item_mirror()
		_player_states_by_id[player_id] = state
	_add_player_state(peer_id, player_id, state)
	state.effects.paused = false
	progression.ensure_personal_progression(player_id)
	if adventure.active_session != null:
		adventure.active_session.register_player(peer_id, Callable(ContentRegistry, "get_item"))
	if peer_id == get_local_peer_id():
		_connect_model_signals()
	player_registered.emit(peer_id, state)
	return state

func unregister_player(peer_id: int) -> void:
	detach_player(peer_id)

func detach_player(peer_id: int) -> void:
	if not players.has(peer_id):
		return
	var state: PlayerState = players[peer_id]
	_disconnect_player_state_signals(peer_id, state)
	state.effects.paused = true
	players.erase(peer_id)
	_attached_player_ids.erase(peer_id)
	_player_runtime.erase(peer_id)
	if adventure.active_session != null:
		# PlayerState and personal progression survive by persistent player_id, but
		# expedition participation does not: disconnect forfeits this peer's
		# unsecured loot and reconnect creates an empty adventure state.
		adventure.active_session.discard_player_adventure(peer_id)
	player_unregistered.emit(peer_id)

func remove_player_state(player_id: StringName) -> void:
	var state: PlayerState = _player_states_by_id.get(player_id)
	if state == null:
		return
	var attached_peers: Array[int] = []
	for peer_id in _attached_player_ids:
		if _attached_player_ids[peer_id] == player_id:
			attached_peers.append(peer_id)
	for peer_id in attached_peers:
		detach_player(peer_id)
	state.effects.paused = true
	_player_states_by_id.erase(player_id)

func _add_player_state(peer_id: int, player_id: StringName, state: PlayerState) -> void:
	if peer_id <= 0 or player_id.is_empty() or state == null:
		return
	players[peer_id] = state
	_attached_player_ids[peer_id] = player_id
	_player_states_by_id[player_id] = state
	_player_runtime[peer_id] = PlayerRuntimeState.new(peer_id)
	_connect_player_state_signals(peer_id, state)

func _clear_player_state_registry() -> void:
	_disconnect_player_model_signals()
	for state in _player_states_by_id.values():
		(state as PlayerState).effects.paused = true
	players.clear()
	_attached_player_ids.clear()
	_player_states_by_id.clear()
	_player_runtime.clear()
	_player_vitals_callbacks.clear()
	_player_item_callbacks.clear()

func _connect_player_state_signals(peer_id: int, state: PlayerState) -> void:
	if _player_vitals_callbacks.has(peer_id) or _player_item_callbacks.has(peer_id):
		_disconnect_player_state_signals(peer_id, state)
	var callback := _on_player_vitals_changed.bind(peer_id)
	state.vitals_changed.connect(callback)
	_player_vitals_callbacks[peer_id] = callback
	var item_callback := _on_player_item_state_changed.bind(peer_id)
	state.item_state_changed.connect(item_callback)
	_player_item_callbacks[peer_id] = item_callback

func _disconnect_player_state_signals(peer_id: int, state: PlayerState) -> void:
	var callback: Callable = _player_vitals_callbacks.get(peer_id, Callable())
	if callback.is_valid() and state.vitals_changed.is_connected(callback):
		state.vitals_changed.disconnect(callback)
	_player_vitals_callbacks.erase(peer_id)
	var item_callback: Callable = _player_item_callbacks.get(peer_id, Callable())
	if item_callback.is_valid() and state.item_state_changed.is_connected(item_callback):
		state.item_state_changed.disconnect(item_callback)
	_player_item_callbacks.erase(peer_id)

func _on_player_vitals_changed(peer_id: int) -> void:
	if _applying_runtime_snapshot:
		return
	var state := get_player(peer_id)
	if state != null:
		player_health_changed.emit(peer_id, state.health, maxf(1.0, state.stats.value(&"max_health")))

func _on_player_item_state_changed(revision: int, peer_id: int) -> void:
	var player_id := get_player_id(peer_id)
	if not player_id.is_empty():
		player_item_state_changed.emit(player_id, revision)

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
	if settlement != null and not settlement.changed.is_connected(_on_settlement_state_changed):
		settlement.changed.connect(_on_settlement_state_changed)
	if progression != null and not progression.shared_changed.is_connected(_on_shared_progression_changed):
		progression.shared_changed.connect(_on_shared_progression_changed)

func _disconnect_shared_model_signals() -> void:
	if settlement != null:
		if settlement.storage != null and settlement.storage.changed.is_connected(storage_changed.emit):
			settlement.storage.changed.disconnect(storage_changed.emit)
		if settlement.changed.is_connected(_on_settlement_state_changed):
			settlement.changed.disconnect(_on_settlement_state_changed)
	if progression != null and progression.shared_changed.is_connected(_on_shared_progression_changed):
		progression.shared_changed.disconnect(_on_shared_progression_changed)

func _on_settlement_state_changed(revision: int) -> void:
	settlement_state_changed.emit(revision)

func _on_shared_progression_changed(revision: int) -> void:
	shared_progression_changed.emit(revision)

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
	for peer_id in players:
		progression.ensure_personal_progression(get_player_id(peer_id))
	difficulty.reset(start)
	adventure.reset()

func start_new_game() -> bool:
	if not NetworkManager.is_authoritative_simulation():
		last_message = "Only the host can start a multiplayer session"
		return false
	var start: GameStartDefinition = get_start_definition()
	if start == null:
		return false
	_clear_player_state_registry()
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

func start_quest(quest_id: StringName, player_id: StringName = &"") -> bool:
	if not can_mutate_authoritative_state():
		return false
	var actor_id := get_local_player_id() if player_id.is_empty() else player_id
	var result := _quest_system.start_quest(quest_id, actor_id)
	last_message = result.message
	return result.success

func report_quest_event(type: QuestObjectiveDefinition.ObjectiveType, target_id: StringName, amount: int = 1, player_id: StringName = LOCAL_EVENT_ACTOR) -> void:
	if not can_mutate_authoritative_state():
		return
	var actor_id := get_local_player_id() if player_id == LOCAL_EVENT_ACTOR else player_id
	report_gameplay_event(GameplayEvent.new(type, actor_id, target_id, amount))

func report_gameplay_event(event: GameplayEvent) -> void:
	if can_mutate_authoritative_state() and _quest_system != null:
		_quest_system.report(event)

func claim_quest_reward(quest_id: StringName, player_id: StringName = &"") -> bool:
	# Compatibility API; detailed callers can inspect the transaction result.
	return claim_quest_reward_result(quest_id, player_id).success

func claim_quest_reward_result(quest_id: StringName, player_id: StringName = &"") -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can change quest state")
	var actor_id := get_local_player_id() if player_id.is_empty() else player_id
	var result := _quest_system.claim_reward(quest_id, actor_id)
	last_message = result.message
	return result

func get_shared_quest_states() -> Dictionary[StringName, QuestState]:
	return progression.shared_quest_states

func get_local_personal_quest_states() -> Dictionary[StringName, QuestState]:
	var personal := progression.get_personal_progression(get_local_player_id())
	return personal.quest_states if personal != null else {}

func make_quest_snapshot(quest_id: StringName, owner_player_id: StringName = &"") -> QuestStateSnapshot:
	if not can_mutate_authoritative_state():
		return null
	var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
	var state := progression.get_quest_state(quest_id, owner_player_id, ContentRegistry)
	if definition == null or state == null:
		return null
	var owner := owner_player_id if definition.scope == QuestDefinition.Scope.PERSONAL else &""
	return QuestStateSnapshot.from_state(definition, state, owner, progression.quest_revision(quest_id, owner))

func quest_snapshots_for_player(player_id: StringName) -> Array[QuestStateSnapshot]:
	var result: Array[QuestStateSnapshot] = []
	for quest_id in progression.shared_quest_states:
		var snapshot := make_quest_snapshot(quest_id)
		if snapshot != null:
			result.append(snapshot)
	var personal := progression.get_personal_progression(player_id)
	if personal != null:
		for quest_id in personal.quest_states:
			var snapshot := make_quest_snapshot(quest_id, player_id)
			if snapshot != null:
				result.append(snapshot)
	return result

func apply_quest_network_snapshot(snapshot: QuestStateSnapshot) -> bool:
	if not NetworkManager.is_session_connected() or NetworkManager.is_server() \
			or snapshot == null or not snapshot.error_message.is_empty():
		return false
	var owner := snapshot.owner_player_id if snapshot.scope == QuestDefinition.Scope.PERSONAL else &""
	if not progression.accept_quest_revision(snapshot.quest_id, owner, snapshot.revision):
		return false
	var definition := ContentRegistry.get_definition(snapshot.quest_id) as QuestDefinition
	if definition == null:
		return false
	var state := progression.get_quest_state(snapshot.quest_id, owner, ContentRegistry)
	if state == null:
		state = QuestState.new(snapshot.quest_id)
		state.initialize(definition)
		if not progression.set_quest_state(snapshot.quest_id, owner, state, ContentRegistry):
			return false
	state.progress = snapshot.progress.duplicate()
	state.completed = snapshot.completed
	state.reward_claimed = snapshot.reward_claimed
	quest_changed.emit(snapshot.quest_id)
	return true

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
		report_gameplay_event(GameplayEvent.collect_item(get_player_id(owner_peer_id), item_id, result.changed))
	return result

func record_enemy_kill(enemy_id: StringName, killer_player_id: StringName = LOCAL_EVENT_ACTOR) -> void:
	if not can_mutate_authoritative_state():
		return
	if adventure.active_session == null:
		return
	adventure.active_session.record_kill(enemy_id)
	var actor_id := get_local_player_id() if killer_player_id == LOCAL_EVENT_ACTOR else killer_player_id
	report_gameplay_event(GameplayEvent.kill_enemy(actor_id, enemy_id))

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
	var discoveries_changed := false
	for point in adventure.active_session.discovered_escape_points:
		if not progression.discovered_escape_points.has(point):
			progression.discovered_escape_points.append(point)
			discoveries_changed = true
	if discoveries_changed:
		progression.mark_shared_changed()
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
	state.begin_item_update()
	runtime.death_result = DeathResolutionService.resolve(state, settlement, adventure, rules, death_position, start.respawn_policy, start.survival_config, session_id, Callable(ContentRegistry, "get_item"), not individual_multiplayer_death, personal_adventure, peer_id)
	state.end_item_update()
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
	return execute_craft_command(recipe_id, get_local_player_id())

func execute_craft_command(recipe_id: StringName, actor_player_id: StringName) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can craft")
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Crafting requires settlement state")
	var result := _settlement_command_service.try_craft(recipe_id, actor_player_id)
	last_message = "Crafted %s" % recipe_id if result.success else result.message
	return result

func discover_escape(point_id: StringName, player_id: StringName = LOCAL_EVENT_ACTOR) -> void:
	if not can_mutate_authoritative_state():
		return
	if adventure.active_session != null:
		if adventure.active_session.discover_escape(point_id):
			report_quest_event(QuestObjectiveDefinition.ObjectiveType.DISCOVER_POINT, point_id, 1, player_id)

func can_upgrade_facility(facility_id: StringName) -> bool:
	if not can_mutate_authoritative_state():
		return false
	var check: CommandResult = ProgressionService.facility_check(facility_id, settlement, progression, ContentRegistry)
	if not check.success:
		last_message = check.message
	return check.success

func upgrade_facility(facility_id: StringName, player_id: StringName = LOCAL_EVENT_ACTOR) -> bool:
	var actor_id := get_local_player_id() if player_id == LOCAL_EVENT_ACTOR else player_id
	return execute_facility_upgrade_command(facility_id, actor_id).success

func execute_facility_upgrade_command(facility_id: StringName, actor_player_id: StringName) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can upgrade facilities")
	if phase != Phase.SETTLEMENT:
		return CommandResult.make(false, "Facility upgrades require settlement state")
	var result := _settlement_command_service.try_upgrade_facility(facility_id, actor_player_id)
	last_message = result.message
	if result.success:
		facility_changed.emit(facility_id, settlement.facility_levels.get(facility_id, 0))
	return result

func make_settlement_snapshot() -> SettlementStateSnapshot:
	return SettlementStateSnapshot.from_state(settlement) if can_mutate_authoritative_state() else null

func make_shared_progression_snapshot() -> SharedProgressionSnapshot:
	return SharedProgressionSnapshot.from_state(progression) if can_mutate_authoritative_state() else null

func make_player_item_snapshot(peer_id: int) -> PlayerItemStateSnapshot:
	if not can_mutate_authoritative_state():
		return null
	var player_id := get_player_id(peer_id)
	var state := get_player(peer_id)
	return PlayerItemStateSnapshot.from_state(player_id, state) if not player_id.is_empty() and state != null else null

func apply_player_item_network_snapshot(snapshot: PlayerItemStateSnapshot) -> bool:
	if NetworkManager.is_server() or not NetworkManager.is_session_connected() or snapshot == null \
			or snapshot.owner_player_id != get_local_player_id():
		return false
	var state := get_local_player()
	return state != null and state.apply_item_network_mirror(snapshot)

func execute_equip_command(peer_id: int, instance_id: String) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can equip items")
	return _player_item_command_service.try_equip(get_player(peer_id), instance_id)

func execute_unequip_command(peer_id: int, slot: int) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can unequip items")
	return _player_item_command_service.try_unequip(get_player(peer_id), slot)

func execute_use_item_command(
	peer_id: int,
	item_id: StringName,
	survival_component: SurvivalComponent,
	effect_controller: EffectController
) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can use items")
	return _player_item_command_service.try_use_item(
		get_player(peer_id), survival_component, effect_controller, item_id
	)

func execute_item_transfer_command(
	peer_id: int,
	direction: int,
	item_id: StringName,
	instance_id: String,
	amount: int
) -> CommandResult:
	if not can_mutate_authoritative_state():
		return CommandResult.make(false, "Only the server can transfer items")
	return _player_item_command_service.try_transfer(
		get_player(peer_id), settlement, direction, item_id, instance_id, amount
	)

func apply_settlement_network_snapshot(snapshot: SettlementStateSnapshot) -> bool:
	if not NetworkManager.is_session_connected() or NetworkManager.is_server() or snapshot == null:
		return false
	var previous_facilities := settlement.facility_levels.duplicate()
	var previous_residents := settlement.resident_states.duplicate()
	if not settlement.apply_network_mirror(snapshot):
		return false
	for facility_id in settlement.facility_levels:
		if previous_facilities.get(facility_id, -1) != settlement.facility_levels[facility_id]:
			facility_changed.emit(facility_id, settlement.facility_levels[facility_id])
	for facility_id in previous_facilities:
		if not settlement.facility_levels.has(facility_id):
			facility_changed.emit(facility_id, 0)
	for resident_id in settlement.resident_states:
		var before: ResidentState = previous_residents.get(resident_id)
		var after: ResidentState = settlement.resident_states[resident_id]
		if before == null or before.unlocked != after.unlocked or before.current_state != after.current_state:
			resident_changed.emit(resident_id)
	for resident_id in previous_residents:
		if not settlement.resident_states.has(resident_id):
			resident_changed.emit(resident_id)
	return true

func apply_shared_progression_network_snapshot(snapshot: SharedProgressionSnapshot) -> bool:
	return not NetworkManager.is_server() \
		and NetworkManager.is_session_connected() \
		and progression.apply_shared_network_mirror(snapshot)

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
	var identities: Array[Dictionary] = []
	for peer_id in peer_ids:
		var player_id := get_player_id(peer_id)
		if not player_id.is_empty():
			identities.append(PlayerIdentityRecord.new(peer_id, player_id).to_payload())
	return {
		"protocol_version": protocol_version,
		"session_id": session_id,
		"phase": int(_phase),
		"difficulty_id": String(difficulty.id),
		"players": identities,
	}

func apply_network_snapshot(snapshot: NetworkSessionSnapshot) -> bool:
	if NetworkManager.is_server() or snapshot == null or not snapshot.error_message.is_empty():
		return false
	if snapshot.phase < Phase.MENU or snapshot.phase > Phase.RESPAWNING:
		return false
	var start := get_start_definition()
	if start == null:
		return false
	_clear_player_state_registry()
	settlement.reset(start, ContentRegistry)
	progression.reset(start)
	# Revision zero is a valid authoritative initial snapshot. A newly joined
	# client starts below it so the first full mirror is accepted.
	settlement.revision = -1
	progression.shared_revision = -1
	difficulty.reset(start)
	adventure.reset()
	for peer_id in snapshot.player_ids:
		register_player(peer_id)
	_create_quest_system()
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
	_clear_player_state_registry()
	if retained_state == null:
		retained_state = _create_player_state()
		var start := get_start_definition(false)
		if start != null:
			retained_state.reset(start, ContentRegistry)
	_add_player_state(LOCAL_SINGLEPLAYER_PEER_ID, NetworkManager.local_profile_player_id(), retained_state)
	progression.personal_progression.clear()
	progression.ensure_personal_progression(get_local_player_id())
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
	_clear_player_state_registry()
	_disconnect_shared_model_signals()
	snapshot.player.set_item_mutation_guard(Callable(self, "can_mutate_authoritative_state"))
	_add_player_state(get_local_peer_id(), get_local_player_id(), snapshot.player)
	settlement = snapshot.settlement
	settlement.set_mutation_guard(Callable(self, "can_mutate_authoritative_state"))
	progression = snapshot.progression
	progression.set_mutation_guard(Callable(self, "can_mutate_authoritative_state"))
	difficulty = snapshot.difficulty
	adventure = snapshot.adventure
	_create_quest_system()
	progression.ensure_personal_progression(get_local_player_id())
	session_id = snapshot.session_id
	play_time_seconds = snapshot.play_time_seconds
	_connect_model_signals()
	set_phase(Phase.SETTLEMENT)
	session_reset.emit()
