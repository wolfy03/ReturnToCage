extends CanvasLayer

var panel: PanelContainer

func _ready() -> void:
	if not OS.is_debug_build():
		queue_free()
		return
	_build_ui()

func _build_ui() -> void:
	panel = PanelContainer.new()
	panel.visible = false
	panel.position = Vector2(18, 100)
	panel.custom_minimum_size = Vector2(260, 0)
	add_child(panel)
	var buttons := VBoxContainer.new(); panel.add_child(buttons)
	_add_button(buttons, "Toggle invincible", func() -> void:
		var p := get_tree().get_first_node_in_group(&"player") as PlayerActor
		if p != null: p.health.god_mode = not p.health.god_mode
	)
	_add_button(buttons, "Toggle survival drain", func() -> void:
		var p := get_tree().get_first_node_in_group(&"player") as PlayerActor
		if p != null: p.survival.drain_paused = not p.survival.drain_paused
	)
	_add_button(buttons, "Set hunger/thirst 10", func() -> void:
		var p := get_tree().get_first_node_in_group(&"player") as PlayerActor
		if p != null: p.survival.set_values(10, 10)
	)
	_add_button(buttons, "Give carried supplies", func() -> void:
		GameSession.player_inventory.add_item(&"berry", 3); GameSession.player_inventory.add_item(&"water_drop", 2)
	)
	_add_button(buttons, "Give storage scrap", func() -> void: GameSession.settlement_storage.add_item(&"rusty_scrap", 10))
	_add_button(buttons, "Spawn sewer beetle", func() -> void:
		if GameSession.active_adventure != null:
			var scene := load("res://gameplay/actors/enemies/sewer_beetle.tscn") as PackedScene
			var enemy := scene.instantiate() as EnemyAgent; enemy.position = Vector2(850, 500)
			get_tree().current_scene.get_node("WorldLayer").get_child(0).add_child(enemy)
	)
	_add_button(buttons, "Kill player", func() -> void:
		var p := get_tree().get_first_node_in_group(&"player") as PlayerActor
		if p != null: p.health.receive_damage(DamageContext.new(9999, &"debug", self, &"debug"))
	)
	_add_button(buttons, "Upgrade facility", func() -> void: GameSession.upgrade_facility(&"workbench"))
	_add_button(buttons, "Loss policy: none", func() -> void: GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE))
	_add_button(buttons, "Loss policy: half", func() -> void: GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.HALF))
	_add_button(buttons, "Loss policy: all", func() -> void: GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.ALL))
	_add_button(buttons, "Discover escape", func() -> void: GameSession.discover_escape(&"sewer_ladder"))
	_add_button(buttons, "Save", func() -> void: SaveManager.save_game())
	_add_button(buttons, "Load", func() -> void: if SaveManager.load_game(): SceneRouter.go_to_settlement())
	_add_button(buttons, "Validate content", func() -> void:
		var errors := ContentRegistry.validate_all(); GameSession.last_message = "Content valid" if errors.is_empty() else "; ".join(errors); get_tree().call_group(&"hud", "refresh_all")
	)
	_add_button(buttons, "Print session", func() -> void: print(JSON.stringify(GameSession.export_state(), "  ")))

func _add_button(parent: VBoxContainer, text: String, callback: Callable) -> void:
	var button := Button.new(); button.text = text; button.pressed.connect(callback); parent.add_child(button)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"debug_panel"):
		panel.visible = not panel.visible
