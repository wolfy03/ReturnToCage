extends Node2D

var context: AdventureContext
var server_runtime_mode: bool = false
var environment_presenter: EnvironmentPresenter
var _gather_targets: Dictionary[StringName, InteractionTarget] = {}
var _gather_items: Dictionary[StringName, Dictionary] = {}
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
	WorldHelpers.add_platform(self, Vector2(750, 570), Vector2(1600, 70), Color("263c3f"))
	WorldHelpers.add_platform(self, Vector2(420, 440), Vector2(240, 22), Color("37565a"))
	WorldHelpers.add_platform(self, Vector2(760, 350), Vector2(210, 22), Color("37565a"))
	WorldHelpers.add_platform(self, Vector2(1080, 450), Vector2(230, 22), Color("37565a"))
	WorldHelpers.add_label(self, "SEWER ROUTE / Danger 1", Vector2(30, 35), Color("9fd5c7"))
	WorldHelpers.add_label(self, "Entrance", Vector2(35, 455))
	WorldHelpers.add_label(self, "Emergency ladder", Vector2(1310, 455))
	_create_escape_points()
	_create_death_drops()
	_create_gather(&"scrap_cache_a", &"rusty_scrap", 2, Vector2(430, 395))
	_create_gather(&"scrap_cache_b", &"rusty_scrap", 2, Vector2(760, 305))
	_create_gather(&"berry_drop", &"berry", 1, Vector2(1070, 405))
	if server_runtime_mode or not NetworkManager.is_multiplayer_active() and NetworkManager.is_authoritative_simulation():
		(get_node("EnemySpawnManager") as EnemySpawnManager).spawn_enemy(&"sewer_beetle", Vector2(970, 525))
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
		target.display_policy = GameSession.current_difficulty().escape_display
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
		target.activated.connect(func(_actor: Node) -> void: _escape(AdventureSession.Result.NORMAL_ESCAPE))

func _create_death_drops() -> void:
	for record in GameSession.adventure.death_drops:
		if record.region_id != context.region_id or record.recovered:
			continue
		var target: InteractionTarget = WorldHelpers.add_interaction(self, StringName(record.id), "Recover lost items", to_local(record.position), Vector2(34, 34), Color("d5a6e6"), 6)
		target.add_to_group(&"death_drop")
		target.activated.connect(func(actor: Node) -> void:
			var peer_id := (actor as PlayerActor).peer_id if actor is PlayerActor else GameSession.get_local_peer_id()
			var result: CommandResult = GameSession.adventure.recover_drop(record.id, peer_id, GameSession.get_player_id(peer_id))
			GameSession.last_message = result.message
			GameSession.inventory_changed.emit()
			if record.recovered:
				target.enabled = false
				target.queue_free()
		)

func _create_gather(id: StringName, item_id: StringName, amount: int, position: Vector2) -> void:
	var definition := ContentRegistry.get_item(item_id)
	var target := WorldHelpers.add_interaction(self, id, "Gather %s x%d" % [definition.display_name, amount], position, Vector2(42, 42), Color("8b6f47"), 2)
	target.add_to_group(&"world_gather")
	_gather_targets[id] = target
	_gather_items[id] = {"item_id": item_id, "amount": amount}
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
	var data: Dictionary = _gather_items.get(interaction_id, {})
	var player_manager := get_node_or_null("PlayerSpawnManager") as PlayerSpawnManager
	var actor := player_manager.get_actor(peer_id) if player_manager != null else null
	var runtime := GameSession.get_player_runtime(peer_id)
	if target == null or actor == null or runtime == null \
			or runtime.life_phase != PlayerRuntimeState.LifePhase.ALIVE \
			or actor.global_position.distance_to(target.global_position) > 90.0:
		return false
	var result := GameSession.collect_adventure_loot_for_peer(
		data.get("item_id", &""), int(data.get("amount", 0)), peer_id
	)
	if result.changed <= 0:
		return false
	_consumed_gather[interaction_id] = true
	GameSession.last_message = "Unsecured loot: %s x%d" % [data.get("item_id", &""), result.changed]
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
