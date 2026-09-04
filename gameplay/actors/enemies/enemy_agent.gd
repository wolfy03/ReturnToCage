class_name EnemyAgent
extends CharacterBody2D

@export var definition: EnemyDefinition
@onready var health: HealthComponent = %Health
@onready var hurtbox: HurtboxComponent = %Hurtbox
var player: PlayerActor
var states: Dictionary[StringName, EnemyState] = {}
var current_state: EnemyState
var current_state_id: StringName
var patrol_origin: Vector2
var patrol_direction := 1.0
var last_hit_direction := 1.0

func _ready() -> void:
	if definition == null:
		definition = ContentRegistry.get_definition(&"sewer_beetle") as EnemyDefinition
	if definition == null:
		push_error("EnemyAgent requires EnemyDefinition")
		return
	patrol_origin = global_position
	health.max_health = definition.max_health * GameSession.current_difficulty().enemy_health_multiplier
	health.current_health = health.max_health
	hurtbox.faction = definition.faction
	health.damaged.connect(_on_damaged)
	health.died.connect(_on_died)
	for child in %States.get_children():
		if child is EnemyState:
			child.setup(self)
			states[StringName(child.name.to_snake_case())] = child
	change_state(&"idle")

func _physics_process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		player = get_tree().get_first_node_in_group(&"player") as PlayerActor
	if not is_on_floor():
		velocity.y += 1100.0 * delta
	if current_state != null:
		var next := current_state.physics_tick(delta)
		if not next.is_empty():
			change_state(next)
	move_and_slide()

func change_state(id: StringName) -> void:
	if not states.has(id):
		push_error("Missing enemy state: %s" % id)
		return
	current_state_id = id
	current_state = states[id]
	current_state.enter()

func distance_to_player() -> float:
	return INF if player == null else global_position.distance_to(player.global_position)

func perform_attack() -> void:
	if player == null or distance_to_player() > definition.attack_range + 12.0:
		return
	var target_health := player.get_node_or_null("Health") as HealthComponent
	if target_health != null:
		var damage := definition.attack_damage * GameSession.current_difficulty().enemy_damage_multiplier
		target_health.receive_damage(DamageContext.new(damage, &"physical", self, definition.faction, Vector2(signf(player.global_position.x - global_position.x) * 100.0, -30.0)))

func _on_damaged(context: DamageContext) -> void:
	last_hit_direction = signf(context.source.global_position.x - global_position.x) if context.source is Node2D else 1.0
	change_state(&"hurt")

func _on_died(_context: DamageContext) -> void:
	change_state(&"dead")

func drop_loot_and_remove() -> void:
	GameSession.record_enemy_kill(definition.id)
	if definition.loot_table != null:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(Time.get_ticks_usec())
		for stack in definition.loot_table.roll(rng, GameSession.current_difficulty().loot_multiplier):
			GameSession.collect_adventure_loot(stack.item_id, stack.quantity)
	queue_free()
