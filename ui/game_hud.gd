extends CanvasLayer

var vitals_label: Label
var prompt_label: Label
var inventory_label: Label
var quest_label: Label
var status_label: Label
var return_bar: ProgressBar
var detail_panel: PanelContainer
var bound_player: PlayerActor

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = not GameSession.session_id.is_empty()
	add_to_group(&"hud")
	_build_ui()
	SceneRouter.transition_finished.connect(_on_transition_finished)
	GameSession.inventory_changed.connect(refresh_all)
	GameSession.session_reset.connect(func() -> void: visible = true; refresh_all())
	GameSession.storage_changed.connect(refresh_all)
	GameSession.facility_changed.connect(func(_id: StringName, _level: int) -> void: refresh_all())
	GameSession.quest_changed.connect(func(_id: StringName) -> void: refresh_all())
	SaveManager.save_finished.connect(_on_persistence_result)
	SaveManager.load_finished.connect(_on_persistence_result)
	refresh_all()

func _build_ui() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 18)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 18)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)
	var root := VBoxContainer.new()
	margin.add_child(root)
	var top := HBoxContainer.new()
	root.add_child(top)
	vitals_label = Label.new(); vitals_label.custom_minimum_size = Vector2(420, 0); top.add_child(vitals_label)
	status_label = Label.new(); status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; top.add_child(status_label)
	return_bar = ProgressBar.new(); return_bar.visible = false; return_bar.max_value = 1.0; return_bar.custom_minimum_size = Vector2(300, 18); root.add_child(return_bar)
	prompt_label = Label.new(); prompt_label.add_theme_font_size_override("font_size", 22); prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; root.add_child(prompt_label)
	var spacer := Control.new(); spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL; root.add_child(spacer)
	detail_panel = PanelContainer.new(); detail_panel.visible = true; root.add_child(detail_panel)
	var details := HBoxContainer.new(); detail_panel.add_child(details)
	inventory_label = Label.new(); inventory_label.custom_minimum_size = Vector2(420, 115); details.add_child(inventory_label)
	quest_label = Label.new(); quest_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; details.add_child(quest_label)
	var buttons := VBoxContainer.new(); details.add_child(buttons)
	var save_button := Button.new(); save_button.text = "Save"; save_button.pressed.connect(func() -> void: SaveManager.save_game()); buttons.add_child(save_button)
	var load_button := Button.new(); load_button.text = "Load"; load_button.pressed.connect(func() -> void:
		if SaveManager.load_game(): SceneRouter.go_to_settlement()
	); buttons.add_child(load_button)
	var eat_button := Button.new(); eat_button.text = "Eat berry"; eat_button.pressed.connect(func() -> void:
		var player := get_tree().get_first_node_in_group(&"player") as PlayerActor
		if player != null: player.consume_item(&"berry"); refresh_all()
	); buttons.add_child(eat_button)
	var drink_button := Button.new(); drink_button.text = "Drink water"; drink_button.pressed.connect(func() -> void:
		var player := get_tree().get_first_node_in_group(&"player") as PlayerActor
		if player != null: player.consume_item(&"water_drop"); refresh_all()
	); buttons.add_child(drink_button)
	var difficulty := OptionButton.new()
	difficulty.add_item("Story"); difficulty.set_item_metadata(0, &"story")
	difficulty.add_item("Normal"); difficulty.set_item_metadata(1, &"normal")
	difficulty.add_item("Survival"); difficulty.set_item_metadata(2, &"survival")
	difficulty.selected = 1
	difficulty.item_selected.connect(func(index: int) -> void: GameSession.set_difficulty(difficulty.get_item_metadata(index)); refresh_all())
	buttons.add_child(difficulty)
	var no_loss := CheckButton.new(); no_loss.text = "Override: no loot loss"
	no_loss.toggled.connect(func(enabled: bool) -> void:
		if enabled: GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE)
		else: GameSession.clear_difficulty_override(&"inventory_loss")
		refresh_all()
	); buttons.add_child(no_loss)

func _on_transition_finished(_destination: StringName) -> void:
	await get_tree().process_frame
	_bind_player(get_tree().get_first_node_in_group(&"player") as PlayerActor)
	refresh_all()

func _bind_player(player: PlayerActor) -> void:
	bound_player = player
	if player == null:
		return
	player.interaction_prompt_changed.connect(func(text: String) -> void: prompt_label.text = text)
	player.return_channel_changed.connect(func(active: bool, progress: float) -> void:
		return_bar.visible = active; return_bar.value = progress
	)
	player.health.health_changed.connect(_on_health_changed)
	player.survival.survival_changed.connect(_on_survival_changed)
	_on_health_changed(player.health.current_health, player.health.max_health)
	_on_survival_changed(player.survival.hunger, player.survival.thirst, 0, 0)

func _on_health_changed(current: float, maximum: float) -> void:
	var hunger := bound_player.survival.hunger if bound_player != null else 0.0
	var thirst := bound_player.survival.thirst if bound_player != null else 0.0
	vitals_label.text = "HP %.0f/%.0f   Stamina %.0f   Hunger %.0f   Thirst %.0f" % [current, maximum, bound_player.combat.stamina if bound_player != null else 0.0, hunger, thirst]

func _on_survival_changed(hunger: float, thirst: float, _hunger_stage: int, _thirst_stage: int) -> void:
	var current := bound_player.health.current_health if bound_player != null else 0.0
	var maximum := bound_player.health.max_health if bound_player != null else 0.0
	vitals_label.text = "HP %.0f/%.0f   Stamina %.0f   Hunger %.0f   Thirst %.0f" % [current, maximum, bound_player.combat.stamina if bound_player != null else 0.0, hunger, thirst]

func refresh_all() -> void:
	if inventory_label == null:
		return
	var carried := _format_inventory(GameSession.player_inventory)
	var storage := _format_inventory(GameSession.settlement_storage)
	var loot := _format_inventory(GameSession.active_adventure.unsecured_loot) if GameSession.active_adventure != null else "none"
	var main_hand := GameSession.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	var equipment_text := ContentRegistry.get_item(main_hand.item_id).display_name if main_hand != null else "none"
	inventory_label.text = "CARRIED (I to toggle)\n%s\nEQUIPMENT: %s\nSTORAGE\n%s\nUNSECURED\n%s" % [carried, equipment_text, storage, loot]
	var lines: Array[String] = []
	for quest_id in GameSession.quest_states:
		var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = GameSession.quest_states[quest_id]
		lines.append("QUEST: %s%s" % [definition.title, " [complete - talk to Milo]" if state.completed else ""])
		for index in definition.objectives.size():
			lines.append("  %s  %d/%d" % [definition.objectives[index].description, state.progress[index], definition.objectives[index].required_amount])
	if lines.is_empty(): lines.append("Talk to Milo to start the sample quest")
	quest_label.text = "\n".join(lines)
	var buffs := ", ".join(bound_player.effects.descriptions()) if bound_player != null else "none"
	status_label.text = "%s | Difficulty: %s | Workbench Lv.%d | Buffs: %s" % [GameSession.last_message, GameSession.difficulty_id, GameSession.facility_levels.get(&"workbench", 0), buffs]

func _format_inventory(inventory: InventoryModel) -> String:
	if inventory == null or inventory.stacks().is_empty():
		return "none"
	var parts: Array[String] = []
	for stack in inventory.stacks():
		var definition := ContentRegistry.get_item(stack.item_id)
		parts.append("%s x%d" % [definition.display_name if definition != null else stack.item_id, stack.quantity])
	return ", ".join(parts)

func _on_persistence_result(_success: bool, message: String) -> void:
	GameSession.last_message = message
	refresh_all()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"open_inventory"):
		detail_panel.visible = not detail_panel.visible
	elif event.is_action_pressed(&"pause") and not GameSession.session_id.is_empty():
		get_tree().paused = not get_tree().paused
		GameSession.last_message = "Paused" if get_tree().paused else "Resumed"
		refresh_all()
