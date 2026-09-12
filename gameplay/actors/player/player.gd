class_name PlayerActor
extends CharacterBody2D

signal interaction_prompt_changed(text: String)
signal return_channel_changed(active: bool, progress: float)
signal attack_presented(sequence: int, facing: float)

@onready var input: PlayerInputComponent = %Input
@onready var movement: MovementComponent = %Movement
@onready var health: HealthComponent = %Health
@onready var survival: SurvivalComponent = %Survival
@onready var combat: CombatComponent = %Combat
@onready var interaction: InteractionComponent = %Interaction
@onready var effects: EffectController = %Effects
@onready var network: NetworkPlayerComponent = %Network
@onready var network_combat: NetworkCombatComponent = %NetworkCombat
@export var peer_id: int = GameSession.LOCAL_SINGLEPLAYER_PEER_ID
var simulation_enabled: bool = true
var presentation_enabled: bool = true
var world_id: StringName = &""
var _death_handled: bool = false
var _life_id: int = -1
var _bound_state: PlayerState
var facing: float = 1.0
var return_channel: float = 0.0
var return_channel_required: float = 3.0
var return_channel_origin: Vector2

func setup_player(
	p_peer_id: int,
	p_simulation_enabled: bool = true,
	p_presentation_enabled: bool = true,
	p_world_id: StringName = &""
) -> void:
	peer_id = p_peer_id
	simulation_enabled = p_simulation_enabled
	presentation_enabled = p_presentation_enabled
	world_id = p_world_id

func is_local_player() -> bool:
	return presentation_enabled and peer_id == NetworkManager.local_peer_id()

func is_simulation_authority() -> bool:
	return simulation_enabled and NetworkManager.is_authoritative_simulation()

func player_state() -> PlayerState:
	return _bound_state

func _ready() -> void:
	add_to_group(&"player")
	add_to_group(&"authoritative_player" if is_simulation_authority() else &"presentation_player")
	if is_local_player():
		add_to_group(&"local_player")
	_bound_state = GameSession.get_player(peer_id)
	if _bound_state == null:
		push_error("PlayerActor has no PlayerState for peer %d" % peer_id)
		set_physics_process(false)
		return
	_life_id = GameSession.arm_player_life(peer_id) if is_simulation_authority() else -1
	movement.configure(self, input, _bound_state.stats)
	combat.configure(self, _bound_state.stats)
	effects.configure(_bound_state.stats, _bound_state.effects)
	network.configure(self, input, movement)
	network_combat.configure(self, input)
	network_combat.attack_presented.connect(func(_peer_id: int, sequence: int, replicated_facing: float) -> void: attack_presented.emit(sequence, replicated_facing))
	input.interact_requested.connect(_on_interact)
	input.quick_item_requested.connect(_on_quick_item)
	interaction.target_changed.connect(_on_target_changed)
	health.died.connect(_on_died)
	health.damaged.connect(_on_damaged)
	health.max_health = _bound_state.stats.value(&"max_health")
	health.current_health = clampf(_bound_state.health, 0.0, health.max_health)
	health.health_changed.connect(_on_health_changed)
	_bound_state.vitals_changed.connect(_sync_persistent_health)
	_bound_state.stats.stat_changed.connect(_on_stat_changed)
	_on_stat_changed(&"defense", _bound_state.stats.value(&"defense"))
	var config := GameSession.get_start_definition().survival_config
	var difficulty := GameSession.current_difficulty()
	survival.configure(config, difficulty.survival_drain_multiplier if difficulty != null else 1.0, _bound_state.survival)
	survival.survival_changed.connect(_on_survival_changed)
	movement.climb_hint_changed.connect(_refresh_interaction_prompt)
	movement.mode_changed.connect(_refresh_interaction_prompt)
	(get_node("Camera2D") as Camera2D).enabled = is_local_player()
	if not is_simulation_authority():
		health.set_process(false)
		survival.set_process(false)
		combat.set_process(false)
		effects.set_process(false)
		interaction.set_process(is_local_player())
		var client_hurtbox := get_node_or_null("Hurtbox") as HurtboxComponent
		if client_hurtbox != null:
			client_hurtbox.monitoring = false
			client_hurtbox.monitorable = false

func _exit_tree() -> void:
	if _bound_state == null:
		return
	if _bound_state.vitals_changed.is_connected(_sync_persistent_health):
		_bound_state.vitals_changed.disconnect(_sync_persistent_health)
	if _bound_state.stats.stat_changed.is_connected(_on_stat_changed):
		_bound_state.stats.stat_changed.disconnect(_on_stat_changed)

func _physics_process(delta: float) -> void:
	if _death_handled:
		return
	if not is_simulation_authority():
		network.presentation_tick(delta)
		return
	if absf(input.move_axis) > 0.01:
		facing = signf(input.move_axis)
	movement.physics_tick(delta)
	network.server_snapshot_tick(delta)
	if return_channel > 0.0:
		if input.move_vector.length() > 0.01 or global_position.distance_to(return_channel_origin) > 3.0:
			_cancel_return_channel()
		else:
			return_channel += delta
			return_channel_changed.emit(true, return_channel / return_channel_required)
			if return_channel >= return_channel_required:
				_complete_return_channel()

func _on_interact() -> void:
	if _death_handled:
		return
	if not is_simulation_authority():
		var loot := interaction.current_target as LootActor
		if loot != null:
			loot.request_local_pickup()
		elif interaction.current_target != null and interaction.current_target.can_interact(self):
			interaction.try_interact(self)
		return
	if interaction.current_target != null and interaction.current_target.can_interact(self):
		interaction.try_interact(self)
	else:
		movement.grant_climb_interaction()

func _on_target_changed(target: InteractionTarget) -> void:
	_refresh_interaction_prompt()

func _on_quick_item() -> void:
	if movement.mode == MovementComponent.Mode.CLIMB or _death_handled:
		return
	if not GameSession.is_peer_in_adventure(peer_id):
		var item_service := get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
		if item_service != null:
			item_service.request_use_item(&"berry")
		elif is_simulation_authority():
			consume_item(&"berry")
		return
	if not is_simulation_authority():
		return
	if _bound_state.inventory.count(&"return_seed") <= 0 or return_channel > 0.0:
		return
	var local_world := GameSession.get_peer_world(peer_id)
	var region := ContentRegistry.get_definition(local_world.region_id) as RegionDefinition \
			if local_world != null else null
	if region == null or not region.allow_return_item:
		GameSession.last_message = "Return items cannot be used in this area"
		return
	return_channel = 0.001
	return_channel_origin = global_position
	movement.enabled = false
	return_channel_changed.emit(true, 0.0)

func _complete_return_channel() -> void:
	if _bound_state.inventory.remove_item(&"return_seed", 1).changed == 1:
		NetworkManager.request_return_to_settlement(AdventureSession.Result.RETURN_ITEM_ESCAPE)
	_cancel_return_channel()

func _cancel_return_channel() -> void:
	if return_channel > 0.0:
		return_channel = 0.0
		movement.enabled = true
		return_channel_changed.emit(false, 0.0)

func cancel_return_channel_for_combat() -> void:
	_cancel_return_channel()

func is_death_handled() -> bool:
	return _death_handled

func consume_item(item_id: StringName) -> bool:
	if _death_handled or not is_simulation_authority():
		return false
	return ItemUseService.use_item(_bound_state.inventory, survival, effects, item_id, Callable(ContentRegistry, "get_item"))

func _on_survival_changed(hunger: float, thirst: float, hunger_stage: int, thirst_stage: int) -> void:
	if not is_simulation_authority():
		return
	combat.stamina_regen_multiplier = survival.config.critical_stamina_multiplier if hunger_stage >= 2 or thirst_stage >= 2 else 1.0
	if (hunger_stage == 3 or thirst_stage == 3) and health.current_health > 0.0:
		health.receive_damage(DamageContext.new(survival.config.starvation_damage_per_second * get_process_delta_time(), &"starvation", self, &"environment"))

func _on_died(_context: DamageContext) -> void:
	if _death_handled or not is_simulation_authority() or not GameSession.is_current_life(peer_id, _life_id):
		return
	_death_handled = true
	movement.exit_climb()
	movement.enabled = false
	survival.drain_paused = true
	_cancel_return_channel()
	movement.enabled = false
	var result: RespawnResult = GameSession.handle_player_death(peer_id, global_position, _life_id)
	if not result.success:
		GameSession.last_message = result.error_message
		_death_handled = false
		movement.enabled = true
		survival.drain_paused = false
		return
	if NetworkManager.is_multiplayer_active():
		var spawn_manager := get_parent().get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
		if spawn_manager == null:
			push_error("Cannot respawn peer %d: PlayerSpawnManager is unavailable" % peer_id)
			return
		spawn_manager.call_deferred("respawn_player", peer_id)
	else:
		await get_tree().create_timer(1.0).timeout
		if is_inside_tree():
			SceneRouter.go_to_settlement()

func _on_health_changed(current: float, _maximum: float) -> void:
	if is_simulation_authority() and not _death_handled and GameSession.is_current_life(peer_id, _life_id):
		_bound_state.set_health(current)

func _sync_persistent_health() -> void:
	if _death_handled or not is_simulation_authority() or not GameSession.is_current_life(peer_id, _life_id):
		return
	health.current_health = _bound_state.health
	health.health_changed.emit(health.current_health, health.max_health)
	if health.current_health <= 0.0:
		_on_died(DamageContext.new(0.0, &"periodic", self, &"effect"))

func _on_damaged(context: DamageContext) -> void:
	if not is_simulation_authority():
		return
	_cancel_return_channel()
	movement.on_damage(context.knockback.length() > 0.0)

func _refresh_interaction_prompt() -> void:
	var target: InteractionTarget = interaction.current_target
	if target != null and target.can_interact(self):
		interaction_prompt_changed.emit("[E] %s" % target.prompt)
	elif movement.climb_candidate() != null or movement.mode == MovementComponent.Mode.CLIMB:
		var candidate: ClimbableArea2D = movement.climb_candidate()
		interaction_prompt_changed.emit("[E] Grip  [W/S] Climb  [Space] Jump off" if candidate != null and candidate.definition.requires_interaction else "[W/S] Climb  [Space] Jump off")
	else:
		interaction_prompt_changed.emit("")

func _on_stat_changed(stat_id: StringName, value: float) -> void:
	if stat_id == &"defense":
		health.defense = value
	elif stat_id == &"max_health":
		health.max_health = maxf(1.0, value)
		health.current_health = minf(health.current_health, health.max_health)
		health.health_changed.emit(health.current_health, health.max_health)

func apply_runtime_presentation(snapshot: PlayerRuntimeSnapshot) -> void:
	if is_simulation_authority() or snapshot == null or snapshot.peer_id != peer_id or not snapshot.error_message.is_empty():
		return
	health.max_health = snapshot.max_health
	match snapshot.life_phase:
		PlayerRuntimeState.LifePhase.ALIVE:
			health.current_health = snapshot.health
		PlayerRuntimeState.LifePhase.DEAD, PlayerRuntimeState.LifePhase.RESPAWNING:
			health.current_health = 0.0
	health.health_changed.emit(health.current_health, health.max_health)
	facing = snapshot.facing
