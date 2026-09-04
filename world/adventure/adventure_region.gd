extends Node2D

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")
const ENEMY_SCENE := preload("res://gameplay/actors/enemies/sewer_beetle.tscn")
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
	_create_gather(&"scrap_cache_a", &"rusty_scrap", 2, Vector2(430, 395))
	_create_gather(&"scrap_cache_b", &"rusty_scrap", 2, Vector2(760, 305))
	_create_gather(&"berry_drop", &"berry", 1, Vector2(1070, 405))
	var enemy := ENEMY_SCENE.instantiate() as EnemyAgent
	enemy.position = Vector2(970, 525)
	add_child(enemy)
	var player := PLAYER_SCENE.instantiate() as PlayerActor
	player.position = Vector2(150, 520)
	add_child(player)

func _create_escape_points() -> void:
	var entrance := WorldHelpers.add_interaction(self, &"sewer_entrance", "Return through entrance", Vector2(70, 510), Vector2(90, 90), Color("315b63"), 4)
	entrance.activated.connect(func(_actor: Node) -> void: _escape(AdventureSession.Result.NORMAL_ESCAPE))
	var ladder := WorldHelpers.add_interaction(self, &"sewer_ladder", "Discover / use escape ladder", Vector2(1370, 500), Vector2(70, 110), Color("c89f54"), 4)
	ladder.activated.connect(func(_actor: Node) -> void:
		GameSession.discover_escape(&"sewer_ladder")
		_escape(AdventureSession.Result.NORMAL_ESCAPE)
	)

func _create_gather(id: StringName, item_id: StringName, amount: int, position: Vector2) -> void:
	var definition := ContentRegistry.get_item(item_id)
	var target := WorldHelpers.add_interaction(self, id, "Gather %s x%d" % [definition.display_name, amount], position, Vector2(42, 42), Color("8b6f47"), 2)
	target.activated.connect(func(_actor: Node) -> void:
		var result := GameSession.collect_adventure_loot(item_id, amount)
		if result.changed > 0:
			GameSession.last_message = "Unsecured loot: %s x%d" % [definition.display_name, result.changed]
			target.queue_free()
	)

func _escape(result: AdventureSession.Result) -> void:
	GameSession.finish_adventure(result)
	SceneRouter.go_to_settlement()
