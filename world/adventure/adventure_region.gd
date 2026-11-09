extends Node2D

var context: AdventureContext
var server_runtime_mode: bool = false
var environment_presenter: EnvironmentPresenter
var _gather_targets: Dictionary[StringName, InteractionTarget] = {}
var _gather_items: Dictionary[StringName, FieldGatherPoint] = {}
var _consumed_gather: Dictionary[StringName, bool] = {}

func configure(p_context: AdventureContext) -> void:
	context = p_context
	var configured_world := PlayerWorldState.adventure_world_id(context.region_id) if context != null else &""
	var manager := get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	if manager != null and context != null:
		manager.configure_world(configured_world)
	var enemy_manager := get_node_or_null("EnemySpawnManager") as EnemySpawnManager
	if enemy_manager != null:
		enemy_manager.configure_world(configured_world, false)
	var loot_manager := get_node_or_null("LootSpawnManager") as LootSpawnManager
	if loot_manager != null:
		loot_manager.configure_world(configured_world, false)

func configure_server_runtime(p_world_id: StringName, p_region_id: StringName) -> void:
	server_runtime_mode = true
	var definition := ContentRegistry.get_definition(p_region_id) as RegionDefinition
	var entry_id: StringName = definition.entry_point_ids[0] if definition != null and not definition.entry_point_ids.is_empty() else &""
	context = AdventureContext.new(p_region_id, &"", entry_id, GameSession.difficulty.id, GameSession.session_id)
	var manager := get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	if manager != null:
		manager.world_id = p_world_id
		manager.authoritative_runtime = true
	var enemy_manager := get_node_or_null("EnemySpawnManager") as EnemySpawnManager
	if enemy_manager != null:
		enemy_manager.configure_world(p_world_id)
	var loot_manager := get_node_or_null("LootSpawnManager") as LootSpawnManager
	if loot_manager != null:
		loot_manager.configure_world(p_world_id)
	_remove_runtime_duplicate_services()

func _ready() -> void:
	if context == null:
		push_error("AdventureRegion requires AdventureContext")
		return
	NetworkManager.gather_consumed_received.connect(_on_gather_consumed_received)
	if server_runtime_mode:
		NetworkManager.gather_requested.connect(_on_gather_requested)
		NetworkManager.peer_world_ready.connect(_on_peer_world_ready)
	# Client visual environment only; never built for ServerWorldRuntime.
	if not server_runtime_mode:
		_create_environment()
	else:
		var signs := get_node_or_null("Signs") as Node2D
		if signs != null:
			signs.hide()
	_create_escape_points()
	_create_death_drops()
	var spawn_enemies := (NetworkManager.is_authoritative_simulation()
			and (server_runtime_mode or not NetworkManager.is_multiplayer_active()))
	var enemy_manager := get_node("EnemySpawnManager") as EnemySpawnManager
	for marker in find_children("*", "Marker2D", true, false):
		if marker is FieldGatherPoint and marker.enabled:
			_create_gather(marker)
		elif spawn_enemies and marker is FieldEnemySpawnPoint and marker.enabled:
			enemy_manager.spawn_enemy(marker.enemy_id, marker.global_position)
	var points: Array[RegionPoint] = []
	RegionPoint.collect(self, points)
	var entry: RegionPoint
	for point in points:
		if point.kind == RegionPoint.Kind.ENTRY and point.point_id == context.entry_point_id:
			entry = point
	if entry == null:
		push_error("Missing region entry marker: %s" % context.entry_point_id)
		return
	(get_node("PlayerSpawnManager") as PlayerSpawnManager).initialize_spawns()

func _exit_tree() -> void:
	if NetworkManager.gather_consumed_received.is_connected(_on_gather_consumed_received):
		NetworkManager.gather_consumed_received.disconnect(_on_gather_consumed_received)
	if NetworkManager.gather_requested.is_connected(_on_gather_requested):
		NetworkManager.gather_requested.disconnect(_on_gather_requested)
	if NetworkManager.peer_world_ready.is_connected(_on_peer_world_ready):
		NetworkManager.peer_world_ready.disconnect(_on_peer_world_ready)

## Background preset path resolved from the region content of this context
## (never from global session phase), so each player's world picks its own visuals.
func environment_path_for_context() -> String:
	if context == null:
		return ""
	var definition := ContentRegistry.get_definition(context.region_id) as RegionDefinition
	return definition.environment_path if definition != null else ""

func environment_loading_color_for_context() -> Color:
	if context == null:
		return Color("091a24")
	var definition := ContentRegistry.get_definition(context.region_id) as RegionDefinition
	return definition.environment_loading_color if definition != null else Color("091a24")

func _create_environment() -> void:
	environment_presenter = EnvironmentPresenter.new()
	environment_presenter.name = "EnvironmentPresenter"
	add_child(environment_presenter)
	environment_presenter.configure_from_path(
		environment_path_for_context(), false, environment_loading_color_for_context()
	)

func _remove_runtime_duplicate_services() -> void:
	for child_name in ["QuestReplicationService", "SettlementReplicationService", "PlayerItemReplicationService"]:
		var service := get_node_or_null(child_name)
		if service != null:
			remove_child(service)
			service.free()

func _create_escape_points() -> void:
	var points: Array[RegionPoint] = []
	RegionPoint.collect(self, points)
	for point in points:
		if point.kind != RegionPoint.Kind.ESCAPE:
			continue
		var target := EscapePoint2D.new()
		target.interaction_id = point.point_id
		target.prompt = "Escape to settlement"
		target.interaction_priority = 4
		target.requires_landing = point.requires_landing
		target.display_policy = GameSession.current_difficulty_for_world(PlayerWorldState.adventure_world_id(context.region_id)).escape_display
		target.position = to_local(point.global_position)
		target.collision_layer = 8
		target.collision_mask = 0
		var collision := CollisionShape2D.new()
		var shape := RectangleShape2D.new()
		shape.size = Vector2(50, 48)
		collision.shape = shape
		target.add_child(collision)
		var visual := Polygon2D.new()
		visual.polygon = PackedVector2Array([-20,-20,20,-20,20,20,-20,20])
		visual.color = Color("315b63")
		target.add_child(visual)
		add_child(target)
		target.activated.connect(func(actor: Node) -> void:
			var result := NetworkManager._escape_at_point(actor.peer_id, point.point_id) if server_runtime_mode and actor is PlayerActor else NetworkManager.request_escape_at_point(point.point_id)
			GameSession.last_message = result.message
		)

func _create_death_drops() -> void:
	var manager := DeathDropManager.new()
	manager.name = "DeathDropManager"
	manager.configure(context.region_id, server_runtime_mode or not NetworkManager.is_multiplayer_active())
	add_child(manager)

func _create_gather(point: FieldGatherPoint) -> void:
	var id := point.interaction_id
	var definition := ContentRegistry.get_item(point.item_id)
	if definition == null or id.is_empty() or point.amount <= 0 or _gather_targets.has(id):
		push_error("Invalid gather marker: %s" % point.get_path())
		return
	var target := WorldHelpers.add_interaction(self, id, "Gather %s x%d" % [definition.display_name, point.amount], to_local(point.global_position), Vector2(42, 42), Color("8b6f47"), 2)
	target.add_to_group(&"world_gather")
	_gather_targets[id] = target
	_gather_items[id] = point
	target.activated.connect(func(actor: Node) -> void:
		var peer_id := (actor as PlayerActor).peer_id if actor is PlayerActor else GameSession.get_local_peer_id()
		if server_runtime_mode:
			_try_gather(peer_id, id)
		else:
			NetworkManager.request_gather(id)
	)

func _on_gather_requested(peer_id: int, world_id: StringName, interaction_id: StringName) -> void:
	if server_runtime_mode and context != null \
			and world_id == PlayerWorldState.adventure_world_id(context.region_id):
		_try_gather(peer_id, interaction_id)

func _try_gather(peer_id: int, interaction_id: StringName) -> bool:
	if not server_runtime_mode or _consumed_gather.has(interaction_id) \
			or GameSession.get_peer_world_id(peer_id) != PlayerWorldState.adventure_world_id(context.region_id):
		return false
	var target: InteractionTarget = _gather_targets.get(interaction_id)
	var point: FieldGatherPoint = _gather_items.get(interaction_id)
	var player_manager := get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	var actor := player_manager.get_actor(peer_id) if player_manager != null else null
	var runtime := GameSession.get_player_runtime(peer_id)
	if target == null or point == null or actor == null or runtime == null \
			or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE \
			or actor.hurt.is_active() or actor.dodge.is_active() \
			or actor.global_position.distance_to(target.global_position) > 90.0:
		return false
	var result := GameSession.collect_adventure_loot_for_peer(
		point.item_id, point.amount, peer_id
	)
	if result.changed <= 0:
		return false
	_consumed_gather[interaction_id] = true
	GameSession.last_message = "Unsecured loot: %s x%d" % [point.item_id, result.changed]
	_gather_targets.erase(interaction_id)
	target.enabled = false
	target.queue_free()
	NetworkManager.broadcast_gather_consumed(PlayerWorldState.adventure_world_id(context.region_id), interaction_id)
	return true

func _on_gather_consumed_received(world_id: StringName, interaction_id: StringName) -> void:
	if server_runtime_mode or context == null \
			or world_id != PlayerWorldState.adventure_world_id(context.region_id):
		return
	var target: Variant = _gather_targets.get(interaction_id)
	_gather_targets.erase(interaction_id)
	if is_instance_valid(target) and target is InteractionTarget:
		target.enabled = false
		target.queue_free()

func _on_peer_world_ready(peer_id: int) -> void:
	var world_id := PlayerWorldState.adventure_world_id(context.region_id) if context != null else &""
	if server_runtime_mode and GameSession.get_peer_world_id(peer_id) == world_id:
		var ids: Array[StringName] = []
		ids.assign(_consumed_gather.keys())
		NetworkManager.send_gather_state(peer_id, world_id, ids)

func _escape(result: AdventureSession.Result) -> void:
	var transition := NetworkManager.request_return_to_settlement(result)
	GameSession.last_message = transition.message
