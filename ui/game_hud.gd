extends CanvasLayer

var vitals_label: Label
var prompt_label: Label
var inventory_label: Label
var quest_label: Label
var status_label: Label
var return_bar: ProgressBar
var detail_panel: PanelContainer
var save_button: Button
var load_button: Button
var difficulty: OptionButton
var no_loss: CheckButton
var settlement_buttons: Array[Button] = []
var network_settlement_buttons: Array[Button] = []
var direct_player_buttons: Array[Button] = []
var bound_player: PlayerActor
var _refresh_remaining: float = 0.0

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
	GameSession.phase_changed.connect(refresh_all)
	GameSession.difficulty_changed.connect(func(_id: StringName) -> void: refresh_all())
	GameSession.adventure_finished.connect(func(_result: AdventureSession.Result, _summary: String) -> void: refresh_all())
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
	status_label = Label.new(); status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT; status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; top.add_child(status_label)
	return_bar = ProgressBar.new(); return_bar.visible = false; return_bar.max_value = 1.0; return_bar.custom_minimum_size = Vector2(300, 18); root.add_child(return_bar)
	prompt_label = Label.new(); prompt_label.add_theme_font_size_override("font_size", 22); prompt_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER; root.add_child(prompt_label)
	var spacer := Control.new(); spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL; root.add_child(spacer)
	detail_panel = PanelContainer.new(); detail_panel.visible = true; root.add_child(detail_panel)
	var details := HBoxContainer.new(); detail_panel.add_child(details)
	inventory_label = Label.new(); inventory_label.custom_minimum_size = Vector2(420, 115); inventory_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; details.add_child(inventory_label)
	quest_label = Label.new(); quest_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; quest_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART; details.add_child(quest_label)
	var buttons := GridContainer.new(); buttons.columns = 2; details.add_child(buttons)
	save_button = Button.new(); save_button.text = "Save"; save_button.pressed.connect(func() -> void: SaveManager.save_game()); buttons.add_child(save_button)
	load_button = Button.new(); load_button.text = "Load"; load_button.pressed.connect(func() -> void:
		if SaveManager.load_game(): SceneRouter.go_to_settlement()
	); buttons.add_child(load_button)
	var eat_button := Button.new(); eat_button.text = "Eat berry"; eat_button.pressed.connect(func() -> void:
		var player := get_tree().get_first_node_in_group(&"local_player") as PlayerActor
		if player != null: player.consume_item(&"berry"); refresh_all()
	); buttons.add_child(eat_button)
	direct_player_buttons.append(eat_button)
	var drink_button := Button.new(); drink_button.text = "Drink water"; drink_button.pressed.connect(func() -> void:
		var player := get_tree().get_first_node_in_group(&"local_player") as PlayerActor
		if player != null: player.consume_item(&"water_drop"); refresh_all()
	); buttons.add_child(drink_button)
	direct_player_buttons.append(drink_button)
	difficulty = OptionButton.new()
	difficulty.add_item("Story"); difficulty.set_item_metadata(0, &"story")
	difficulty.add_item("Normal"); difficulty.set_item_metadata(1, &"normal")
	difficulty.add_item("Survival"); difficulty.set_item_metadata(2, &"survival")
	difficulty.selected = 1
	difficulty.item_selected.connect(func(index: int) -> void: GameSession.set_difficulty(difficulty.get_item_metadata(index)); refresh_all())
	buttons.add_child(difficulty)
	no_loss = CheckButton.new(); no_loss.text = "Override: no loot loss"
	no_loss.toggled.connect(func(enabled: bool) -> void:
		if enabled: GameSession.set_difficulty_override(&"inventory_loss", DifficultyDefinition.InventoryLoss.NONE)
		else: GameSession.clear_difficulty_override(&"inventory_loss")
		refresh_all()
	); buttons.add_child(no_loss)
	var pending := Button.new()
	pending.text = "Claim pending loot"
	pending.pressed.connect(func() -> void: GameSession.claim_pending_loot(); refresh_all())
	buttons.add_child(pending)
	settlement_buttons.append(pending)
	for content in ContentRegistry.all_definitions():
		if content is RecipeDefinition:
			var craft_button := Button.new()
			craft_button.text = "Craft: %s" % content.id
			craft_button.pressed.connect(func() -> void:
				var service := _settlement_replication_service()
				if service != null:
					service.request_craft(content.id)
				refresh_all()
			)
			buttons.add_child(craft_button)
			network_settlement_buttons.append(craft_button)
	for content in ContentRegistry.all_definitions():
		if content is FacilityDefinition:
			var upgrade_button := Button.new()
			upgrade_button.text = "Upgrade: %s" % content.id
			upgrade_button.pressed.connect(func() -> void:
				var service := _settlement_replication_service()
				if service != null:
					service.request_upgrade_facility(content.id)
				refresh_all()
			)
			buttons.add_child(upgrade_button)
			network_settlement_buttons.append(upgrade_button)

func _settlement_replication_service() -> SettlementReplicationService:
	return get_tree().get_first_node_in_group(&"settlement_replication_service") as SettlementReplicationService

func _on_transition_finished(_destination: StringName) -> void:
	await get_tree().process_frame
	_bind_player(get_tree().get_first_node_in_group(&"local_player") as PlayerActor)
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
	var hunger := bound_player.survival.hunger if is_instance_valid(bound_player) else 0.0
	var thirst := bound_player.survival.thirst if is_instance_valid(bound_player) else 0.0
	vitals_label.text = "HP %.0f/%.0f   Stamina %.0f   Hunger %.0f   Thirst %.0f" % [current, maximum, bound_player.combat.stamina if is_instance_valid(bound_player) else 0.0, hunger, thirst]

func _on_survival_changed(hunger: float, thirst: float, _hunger_stage: int, _thirst_stage: int) -> void:
	var current := bound_player.health.current_health if is_instance_valid(bound_player) else 0.0
	var maximum := bound_player.health.max_health if is_instance_valid(bound_player) else 0.0
	vitals_label.text = "HP %.0f/%.0f   Stamina %.0f   Hunger %.0f   Thirst %.0f" % [current, maximum, bound_player.combat.stamina if is_instance_valid(bound_player) else 0.0, hunger, thirst]

func refresh_all() -> void:
	if inventory_label == null:
		return
	save_button.disabled = not SaveManager.can_save().success
	load_button.disabled = not SaveManager.can_load().success
	save_button.tooltip_text = SaveManager.can_save().message
	load_button.tooltip_text = SaveManager.can_load().message
	var read_only_client := NetworkManager.is_multiplayer_active() and not NetworkManager.is_server()
	for button in direct_player_buttons:
		button.disabled = read_only_client
		button.tooltip_text = "Not synchronized in multiplayer yet" if read_only_client else ""
	difficulty.disabled = read_only_client or GameSession.phase == GameSession.Phase.ADVENTURE or GameSession.phase == GameSession.Phase.RESPAWNING
	no_loss.disabled = difficulty.disabled
	for button in settlement_buttons:
		button.disabled = read_only_client or GameSession.phase != GameSession.Phase.SETTLEMENT
		button.tooltip_text = "Available in the settlement" if button.disabled else ""
	for button in network_settlement_buttons:
		button.disabled = GameSession.phase != GameSession.Phase.SETTLEMENT
		button.tooltip_text = "Available in the settlement" if button.disabled else ""
	difficulty.tooltip_text = "Expedition rules are fixed until return" if difficulty.disabled else "Difficulty for the next expedition"
	no_loss.tooltip_text = difficulty.tooltip_text
	for index in difficulty.item_count:
		if difficulty.get_item_metadata(index) == GameSession.difficulty.id:
			difficulty.select(index)
	no_loss.set_pressed_no_signal(GameSession.difficulty.overrides.get(&"inventory_loss", -1) == DifficultyDefinition.InventoryLoss.NONE)
	var carried := _format_inventory(GameSession.player.inventory)
	var storage := _format_inventory(GameSession.settlement.storage)
	var loot := _format_inventory(GameSession.adventure.active_session.unsecured_loot) if GameSession.adventure.active_session != null else "none"
	var main_hand := GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	var equipment_text := ContentRegistry.get_item(main_hand.item_id).display_name if main_hand != null else "none"
	inventory_label.text = "CARRIED (I to toggle)\n%s\nEQUIPMENT: %s\nSTORAGE\n%s\nUNSECURED\n%s" % [carried, equipment_text, storage, loot]
	var pending_items: Array[String] = []
	for stack in GameSession.settlement.pending_loot:
		pending_items.append("%s x%d" % [stack.item_id, stack.quantity])
	if not pending_items.is_empty():
		inventory_label.text += "\nPENDING (storage full): " + ", ".join(pending_items)
	var lines: Array[String] = []
	for quest_id in GameSession.progression.quest_states:
		var definition := ContentRegistry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = GameSession.progression.quest_states[quest_id]
		lines.append("QUEST: %s%s" % [definition.title, " [complete - talk to Milo]" if state.completed else ""])
		for index in definition.objectives.size():
			lines.append("  %s  %d/%d" % [definition.objectives[index].description, state.progress[index], definition.objectives[index].required_amount])
	if lines.is_empty(): lines.append("Talk to Milo to start the sample quest")
	quest_label.text = "\n".join(lines)
	var buffs := ", ".join(GameSession.player.effects.descriptions())
	status_label.text = "%s | Difficulty: %s | Workbench Lv.%d | Buffs: %s" % [GameSession.last_message, GameSession.difficulty.id, GameSession.settlement.facility_levels.get(&"workbench", 0), buffs]

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
		if NetworkManager.is_multiplayer_active():
			GameSession.last_message = "Pause is unavailable during multiplayer"
			refresh_all()
			return
		get_tree().paused = not get_tree().paused
		GameSession.last_message = "Paused" if get_tree().paused else "Resumed"
		refresh_all()

func _process(delta: float) -> void:
	_refresh_remaining -= delta
	if visible and _refresh_remaining <= 0.0:
		_refresh_remaining = 0.2
		refresh_all()
