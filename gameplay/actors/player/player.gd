class_name PlayerActor
extends CharacterBody2D

signal interaction_prompt_changed(text: String)
signal return_channel_changed(active: bool, progress: float)

@onready var input: PlayerInputComponent = %Input
@onready var movement: MovementComponent = %Movement
@onready var health: HealthComponent = %Health
@onready var survival: SurvivalComponent = %Survival
@onready var combat: CombatComponent = %Combat
@onready var interaction: InteractionComponent = %Interaction
@onready var effects: EffectController = %Effects
var facing: float = 1.0
var return_channel: float = 0.0
var return_channel_required: float = 3.0
var return_channel_origin: Vector2

func _ready() -> void:
	add_to_group(&"player")
	movement.configure(self, input, GameSession.player_stats)
	combat.configure(self, GameSession.player_stats)
	effects.configure(GameSession.player_stats)
	input.attack_requested.connect(_on_attack)
	input.interact_requested.connect(_on_interact)
	input.quick_item_requested.connect(_on_quick_item)
	interaction.target_changed.connect(_on_target_changed)
	health.died.connect(_on_died)
	health.damaged.connect(_cancel_return_channel.unbind(1))
	health.current_health = clampf(GameSession.player_health, 0.0, health.max_health)
	health.health_changed.connect(func(current: float, _maximum: float) -> void: GameSession.player_health = current)
	GameSession.player_stats.stat_changed.connect(_on_stat_changed)
	_on_stat_changed(&"defense", GameSession.player_stats.value(&"defense"))
	var config := ContentRegistry.get_definition(&"survival_default") as SurvivalConfig
	var difficulty := GameSession.current_difficulty()
	survival.configure(config, difficulty.survival_drain_multiplier if difficulty != null else 1.0)
	survival.restore_state(GameSession.survival_state)
	survival.survival_changed.connect(_on_survival_changed)

func _physics_process(delta: float) -> void:
	if absf(input.move_axis) > 0.01:
		facing = signf(input.move_axis)
	movement.physics_tick(delta)
	if return_channel > 0.0:
		if absf(input.move_axis) > 0.01 or global_position.distance_to(return_channel_origin) > 3.0:
			_cancel_return_channel()
		else:
			return_channel += delta
			return_channel_changed.emit(true, return_channel / return_channel_required)
			if return_channel >= return_channel_required:
				_complete_return_channel()

func _on_attack() -> void:
	if combat.attack(facing):
		_cancel_return_channel()

func _on_interact() -> void:
	interaction.try_interact(self)

func _on_target_changed(target: InteractionTarget) -> void:
	interaction_prompt_changed.emit("[E] %s" % target.prompt if target != null else "")

func _on_quick_item() -> void:
	if GameSession.active_adventure == null:
		consume_item(&"berry")
		return
	if GameSession.player_inventory.count(&"return_seed") <= 0 or return_channel > 0.0:
		return
	var region := ContentRegistry.get_definition(GameSession.active_adventure.context.region_id) as RegionDefinition
	if region == null or not region.allow_return_item:
		GameSession.last_message = "Return items cannot be used in this area"
		return
	return_channel = 0.001
	return_channel_origin = global_position
	movement.enabled = false
	return_channel_changed.emit(true, 0.0)

func _complete_return_channel() -> void:
	if GameSession.player_inventory.remove_item(&"return_seed", 1).changed == 1:
		GameSession.finish_adventure(AdventureSession.Result.RETURN_ITEM_ESCAPE)
		SceneRouter.go_to_settlement()
	_cancel_return_channel()

func _cancel_return_channel() -> void:
	if return_channel > 0.0:
		return_channel = 0.0
		movement.enabled = true
		return_channel_changed.emit(false, 0.0)

func consume_item(item_id: StringName) -> bool:
	return ItemUseService.use_item(GameSession.player_inventory, survival, effects, item_id, Callable(ContentRegistry, "get_item"))

func _on_survival_changed(hunger: float, thirst: float, hunger_stage: int, thirst_stage: int) -> void:
	GameSession.survival_state = survival.to_dict()
	combat.stamina_regen_multiplier = survival.config.critical_stamina_multiplier if hunger_stage >= 2 or thirst_stage >= 2 else 1.0
	if (hunger_stage == 3 or thirst_stage == 3) and health.current_health > 0.0:
		health.receive_damage(DamageContext.new(survival.config.starvation_damage_per_second * get_process_delta_time(), &"starvation", self, &"environment"))

func _on_died(_context: DamageContext) -> void:
	movement.enabled = false
	if GameSession.active_adventure != null:
		GameSession.finish_adventure(AdventureSession.Result.DEATH)
	await get_tree().create_timer(1.0).timeout
	SceneRouter.go_to_settlement()

func _on_stat_changed(stat_id: StringName, value: float) -> void:
	if stat_id == &"defense":
		health.defense = value
	elif stat_id == &"max_health":
		health.max_health = value
