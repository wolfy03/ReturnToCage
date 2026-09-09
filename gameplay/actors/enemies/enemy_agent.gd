class_name EnemyAgent
extends CharacterBody2D

signal state_changed(state_id: StringName)
signal finished(agent: EnemyAgent)

@export var definition: EnemyDefinition
@onready var health: HealthComponent = %Health
@onready var hurtbox: HurtboxComponent = %Hurtbox
@onready var network: NetworkEnemyComponent = %NetworkEnemy
var network_entity_id: int = 0
var simulation_enabled: bool = true
var effects: EffectController
var effect_stats: StatBlock
var player: PlayerActor
var states: Dictionary[StringName, EnemyState] = {}
var current_state: EnemyState
var current_state_id: StringName
var patrol_origin: Vector2
var patrol_direction := 1.0
var last_hit_direction := 1.0
var facing := 1.0
var _death_resolved: bool = false

func setup_enemy(p_definition: EnemyDefinition, entity_id: int, p_simulation_enabled: bool) -> void:
	definition = p_definition
	network_entity_id = entity_id
	simulation_enabled = p_simulation_enabled

func is_simulation_authority() -> bool:
	return simulation_enabled and NetworkManager.is_authoritative_simulation()

func _ready() -> void:
	add_to_group(&"enemy")
	if definition == null:
		definition = ContentRegistry.get_definition(&"sewer_beetle") as EnemyDefinition
	if definition == null:
		push_error("EnemyAgent requires EnemyDefinition")
		return
	patrol_origin = global_position
	health.max_health = definition.max_health * GameSession.current_difficulty().enemy_health_multiplier
	health.current_health = health.max_health
	effect_stats = StatBlock.new()
	effect_stats.set_base(&"move_speed", definition.move_speed)
	effect_stats.set_base(&"attack_power", definition.attack_damage * GameSession.current_difficulty().enemy_damage_multiplier)
	effect_stats.set_base(&"max_health", health.max_health)
	effect_stats.stat_changed.connect(_on_effect_stat_changed)
	effects = EffectController.new()
	effects.name = "Effects"
	add_child(effects)
	effects.configure(effect_stats)
	effects.model.periodic.connect(_on_periodic)
	hurtbox.faction = definition.faction
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	for child in %States.get_children():
		if child is EnemyState:
			child.setup(self)
			states[StringName(child.name.to_snake_case())] = child
	change_state(&"idle")
	network.configure(self)
	if not is_simulation_authority():
		set_physics_process(false)
		health.set_process(false)
		hurtbox.monitoring = false
		hurtbox.monitorable = false
		for state in states.values():
			(state as EnemyState).set_process(false)

func _physics_process(delta: float) -> void:
	if not is_simulation_authority() or _death_resolved:
		return
	_select_target()
	if not is_on_floor():
		velocity.y += 1100.0 * delta
	if current_state != null:
		var next := current_state.physics_tick(delta)
		if not next.is_empty():
			change_state(next)
	move_and_slide()
	if absf(velocity.x) > 0.01:
		facing = signf(velocity.x)

func _select_target() -> void:
	if _valid_target(player):
		return
	player = null
	var nearest_distance := INF
	for node in get_tree().get_nodes_in_group(&"player"):
		var candidate := node as PlayerActor
		if not _valid_target(candidate):
			continue
		var distance := global_position.distance_squared_to(candidate.global_position)
		if distance < nearest_distance:
			nearest_distance = distance
			player = candidate

func _valid_target(candidate: PlayerActor) -> bool:
	if candidate == null or not is_instance_valid(candidate) or candidate.get_parent() != get_parent():
		return false
	var runtime := GameSession.get_player_runtime(candidate.peer_id)
	return runtime != null and runtime.life_phase == PlayerRuntimeState.LifePhase.ALIVE and not candidate.is_death_handled()

func change_state(id: StringName) -> void:
	if not states.has(id):
		push_error("Missing enemy state: %s" % id)
		return
	current_state_id = id
	current_state = states[id]
	current_state.enter()
	state_changed.emit(id)

func distance_to_player() -> float:
	return INF if player == null else global_position.distance_to(player.global_position)

func perform_attack() -> void:
	if not is_simulation_authority() or not _valid_target(player) or distance_to_player() > definition.attack_range + 12.0:
		return
	var target_health := player.get_node_or_null("Health") as HealthComponent
	if target_health != null:
		var damage: float = effect_stats.value(&"attack_power")
		target_health.receive_damage(DamageContext.new(damage, &"physical", self, definition.faction, Vector2(signf(player.global_position.x - global_position.x) * 100.0, -30.0)))

func _on_damaged(context: DamageContext) -> void:
	if not is_simulation_authority() or _death_resolved:
		return
	last_hit_direction = signf(context.source.global_position.x - global_position.x) if context.source is Node2D else 1.0
	change_state(&"hurt")

func _on_died(_context: DamageContext) -> void:
	if not is_simulation_authority() or _death_resolved:
		return
	_death_resolved = true
	change_state(&"dead")

func drop_loot_and_remove() -> void:
	if is_simulation_authority():
		finished.emit(self)

func _on_periodic(amount: float, damage: bool) -> void:
	if not is_simulation_authority() or _death_resolved:
		return
	if damage:
		health.receive_periodic_damage(amount)
	else:
		health.heal(amount)

func _on_effect_stat_changed(id: StringName, value: float) -> void:
	if id == &"defense":
		health.defense = value
	elif id == &"max_health":
		health.max_health = maxf(1.0, value)
		health.current_health = minf(health.current_health, health.max_health)

func apply_runtime_presentation(snapshot: EnemyRuntimeSnapshot) -> void:
	if is_simulation_authority() or snapshot == null:
		return
	health.max_health = snapshot.max_health
	health.current_health = 0.0 if snapshot.state == EnemyRuntimeSnapshot.State.DEAD else snapshot.health
	current_state_id = _state_id(snapshot.state)
	health.health_changed.emit(health.current_health, health.max_health)

static func _state_id(value: EnemyRuntimeSnapshot.State) -> StringName:
	match value:
		EnemyRuntimeSnapshot.State.MOVING: return &"chase"
		EnemyRuntimeSnapshot.State.ATTACKING: return &"attack"
		EnemyRuntimeSnapshot.State.HURT: return &"hurt"
		EnemyRuntimeSnapshot.State.DEAD: return &"dead"
		_: return &"idle"
