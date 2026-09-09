extends Node2D

var context: AdventureContext

func configure(p_context: AdventureContext) -> void:
	context = p_context

func _ready() -> void:
	if context == null:
		push_error("AdventureRegion requires AdventureContext")
		return
	RenderingServer.set_default_clear_color(Color("091a24"))
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
	if NetworkManager.is_authoritative_simulation():
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
			var result: CommandResult = GameSession.adventure.recover_drop(record.id, peer_id)
			GameSession.last_message = result.message
			GameSession.inventory_changed.emit()
			if record.recovered:
				target.enabled = false
				target.queue_free()
		)

func _create_gather(id: StringName, item_id: StringName, amount: int, position: Vector2) -> void:
	var definition := ContentRegistry.get_item(item_id)
	var target := WorldHelpers.add_interaction(self, id, "Gather %s x%d" % [definition.display_name, amount], position, Vector2(42, 42), Color("8b6f47"), 2)
	target.activated.connect(func(actor: Node) -> void:
		var peer_id := (actor as PlayerActor).peer_id if actor is PlayerActor else GameSession.get_local_peer_id()
		var result := GameSession.collect_adventure_loot(item_id, amount, peer_id)
		if result.changed > 0:
			GameSession.last_message = "Unsecured loot: %s x%d" % [definition.display_name, result.changed]
			target.queue_free()
	)

func _escape(result: AdventureSession.Result) -> void:
	GameSession.finish_adventure(result)
	SceneRouter.go_to_settlement()
