extends Node2D

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")

func _ready() -> void:
	RenderingServer.set_default_clear_color(Color("162133"))
	WorldHelpers.add_platform(self, Vector2(700, 570), Vector2(1500, 70), Color("435047"))
	WorldHelpers.add_platform(self, Vector2(650, 425), Vector2(240, 24), Color("596451"))
	WorldHelpers.add_label(self, "MOSS-HOLLOW SETTLEMENT", Vector2(38, 38), Color("e8d6a2"))
	WorldHelpers.add_label(self, "Milo - quest keeper", Vector2(255, 455))
	WorldHelpers.add_label(self, "Workbench", Vector2(500, 465))
	WorldHelpers.add_label(self, "Sewer expedition", Vector2(820, 455))
	WorldHelpers.add_label(self, "Field gate (locked)", Vector2(1110, 455), Color("a7a7a7"))
	_create_npc()
	_create_facility()
	_create_exits()
	_create_save_post()
	var player := PLAYER_SCENE.instantiate() as PlayerActor
	player.position = GameSession.last_safe_position
	add_child(player)

func _create_npc() -> void:
	var target := WorldHelpers.add_interaction(self, &"milo", "Talk to Milo", Vector2(300, 525), Vector2(42, 62), Color("a8b37b"), 3)
	target.activated.connect(func(_actor: Node) -> void:
		if not GameSession.quest_states.has(&"sewer_supplies"):
			GameSession.start_quest(&"sewer_supplies")
		elif not GameSession.claim_quest_reward(&"sewer_supplies"):
			GameSession.last_message = "Milo: Bring back 3 scrap and improve the workbench."
	)
	var resident := ResidentAgent.new()
	resident.position = Vector2(340, 530)
	resident.configure([Vector2(340,530), Vector2(520,530), Vector2(620,395)])
	var shape := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new(); rectangle.size = Vector2(22,32); shape.shape = rectangle
	resident.add_child(shape)
	var visual := Polygon2D.new(); visual.polygon = PackedVector2Array([-12,-14,12,-14,12,14,-12,14]); visual.color = Color("b2a17f"); resident.add_child(visual)
	add_child(resident)

func _create_facility() -> void:
	var level: int = GameSession.facility_levels.get(&"workbench", 0)
	var data := (ContentRegistry.get_definition(&"workbench") as FacilityDefinition).get_level_data(level)
	var color := data.appearance_color if data != null else Color("795548")
	var target := WorldHelpers.add_interaction(self, &"workbench", "Upgrade workbench (3 scrap)", Vector2(540, 525), Vector2(90 + level * 24, 52 + level * 10), color, 2)
	target.activated.connect(func(_actor: Node) -> void:
		if GameSession.upgrade_facility(&"workbench"):
			get_tree().call_group(&"hud", "refresh_all")
			queue_redraw()
			SceneRouter.go_to_settlement()
	)

func _create_exits() -> void:
	var sewer_data := ContentRegistry.get_definition(&"sewer_gate") as SettlementExitDefinition
	var sewer := WorldHelpers.add_interaction(self, sewer_data.id, "%s - %s" % [sewer_data.prompt, sewer_data.display_name], Vector2(865, 510), Vector2(96, 90), Color("264653"), 5)
	sewer.activated.connect(func(_actor: Node) -> void:
		var context := GameSession.begin_adventure(sewer_data.id, sewer_data.connected_region_ids[0], sewer_data.entry_point_id)
		if context != null:
			SceneRouter.go_to_adventure(context)
	)
	var field := WorldHelpers.add_interaction(self, &"field_gate", "Locked: improve settlement", Vector2(1160, 510), Vector2(100, 90), Color("4b4b4b"), 1)
	field.enabled = false

func _create_save_post() -> void:
	WorldHelpers.add_label(self, "Archive post", Vector2(30, 455))
	var post := WorldHelpers.add_interaction(self, &"save_post", "Save game", Vector2(85, 520), Vector2(60, 70), Color("486581"), 2)
	post.activated.connect(func(_actor: Node) -> void: SaveManager.save_game())
