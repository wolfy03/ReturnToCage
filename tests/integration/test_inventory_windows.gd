extends RefCounted

class DelayedUseService extends PlayerItemReplicationService:
	var submissions := 0

	func request_use_item(_item_id: StringName) -> bool:
		submissions += 1
		return true

class DelayedDropService extends PlayerItemReplicationService:
	var submissions: Array[Vector2i] = []

	func request_drop_slot(kind: int, index: int, _amount: int = -1) -> int:
		submissions.append(Vector2i(kind, index))
		return _next_sequence()

var app: AppRoot
var presenter: InventoryPresenter

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.activate_offline_local_identity()
	app = (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	t.add_child(app)
	await _frames(t)
	presenter = app.get_node("UILayer/GameHUD").inventory_presenter
	await key(t, KEY_I)
	t.assert_true(not presenter.inventory_window.visible, "inventory cannot open in menu")
	await click(t, app.new_game_button)
	await _frames(t)
	await _check_input_capture(t)
	var original_id := GameSession.get_local_player_id()
	var original_capacity := GameSession.player.inventory.capacity
	var snapshot := _items()
	await key(t, KEY_I)
	await key(t, KEY_P)
	var bag := presenter.inventory_window
	var gear := presenter.equipment_window
	t.assert_true(bag.visible and gear.visible, "physical I/P events open separate windows")
	app.multiplayer_panel.address_edit.grab_focus()
	await key(t, KEY_I)
	await key(t, KEY_P)
	t.assert_true(bag.visible and gear.visible, "typing I/P into an address field does not toggle game windows")
	app.multiplayer_panel.address_edit.release_focus()
	await key(t, KEY_ESCAPE)
	t.assert_true(bag.visible and not gear.visible and not t.get_tree().paused, "Escape closes only the front item window without pausing gameplay")
	# Recover the test session even when running the regression against the old code.
	t.get_tree().paused = false
	gear.show_window()
	t.assert_equal(bag.slots.size(), 24, "inventory always renders 6 by 4 presentation cells")
	t.assert_equal(bag.get_node("%Grid").columns, 6, "inventory has six columns")
	t.assert_equal(gear.slot_views.keys(), [0, 1, 2, 3, 4], "equipment layout renders five slots in authored row order")
	t.assert_true(gear.slot_views[EquipmentDefinition.EquipmentSlot.MAIN_HAND].stack != null, "equipped weapon is displayed")
	t.assert_true(gear._durability[0].text.contains("60"), "equipment shows current durability")
	t.assert_true(bag.slots[0].item_icon.texture != null and bag.slots[0].quantity_label.text == "2", "missing icon uses placeholder and stack quantity is visible")
	t.assert_true(bag.slots[23].stack == null and bag.slots[23].empty_mark.visible, "unoccupied cells are visibly empty")
	await click(t, bag.slots[0])
	t.assert_equal(bag.selected_slot, 0, "real GUI click selects a slot")
	t.assert_true(bag.slots[0].selected, "selected cell has highlight state")
	await _hover(t, bag.slots[0].get_global_rect().get_center())
	t.assert_true(presenter.tooltip.visible, "mouse hover opens tooltip")
	for field in ["Quantity", "Weight", "Base value", "Food"]:
		t.assert_true(presenter.tooltip.body_label.text.contains(field), "tooltip includes " + field)
	t.assert_equal(presenter.tooltip.title_label.text, ContentRegistry.get_item(&"berry").display_name, "tooltip reads content display name")
	await click(t, bag.tab_buttons[InventoryWindow.Tab.EQUIPMENT])
	t.assert_true(bag.current_tab == InventoryWindow.Tab.EQUIPMENT and bag.slots[0].stack == null, "Equip tab excludes equipped item and consumables")
	for tab in [InventoryWindow.Tab.OTHER, InventoryWindow.Tab.QUEST, InventoryWindow.Tab.CONSUMABLE]:
		await click(t, bag.tab_buttons[tab])
		t.assert_equal(bag.current_tab, tab, "tab receives actual mouse input")
	var quest := ItemDefinition.new()
	quest.category = ItemDefinition.ItemCategory.QUEST
	t.assert_equal(InventoryWindow.tab_for(quest), InventoryWindow.Tab.QUEST, "quest category has dedicated tab")
	t.assert_equal(InventoryWindow.tab_for(ContentRegistry.get_item(&"return_seed")), InventoryWindow.Tab.CONSUMABLE, "protected return item remains in Use category")
	var equipment_items: Array[ItemStack] = [GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)]
	bag.display_items(equipment_items, "display-only equipment fixture")
	bag.select_tab(InventoryWindow.Tab.EQUIPMENT)
	t.assert_equal(bag.slots[0].stack.item_id, &"twig_sword", "Equip tab displays inventory equipment snapshots")
	var custom_icon_item := ItemDefinition.new()
	custom_icon_item.icon = GradientTexture2D.new()
	bag.slots[0].display_item(ItemStack.new(&"berry", 1), custom_icon_item)
	t.assert_true(bag.slots[0].item_icon.texture == custom_icon_item.icon, "authored icons take precedence over common placeholder")
	bag.select_tab(InventoryWindow.Tab.CONSUMABLE)
	var pages: Array[ItemStack] = []
	for index in 25:
		pages.append(ItemStack.new(&"berry", index + 1))
	bag.display_items(pages, "UI-only pagination fixture")
	await click(t, bag.get_node("%Next"))
	t.assert_true(bag.page == 1 and bag.slots[0].stack.quantity == 25 and bag.slots[1].stack == null, "more than 24 entries remain visible through pages without slot-model changes")
	presenter.refresh()
	bag.select_tab(InventoryWindow.Tab.CONSUMABLE)
	# Window dragging uses GUI title-bar press and viewport motion, including offscreen motion.
	var title_position := bag.title_bar.get_global_rect().get_center()
	await _hover(t, title_position)
	_mouse(t, title_position, true)
	t.assert_true(bag._dragging, "title bar receives GUI press and starts window drag")
	await _hover(t, Vector2(9999, 9999))
	_mouse(t, Vector2(9999, 9999), false)
	await _frames(t)
	t.assert_true(_inside(bag), "dragged window is clamped inside viewport")
	t.assert_true(bag.position.distance_to(Vector2(24, 100)) > 10, "GUI motion actually moves the window")
	presenter.tooltip.show_item(gear.slot_views[0].stack, gear.slot_views[0].definition)
	await _frames(t)
	t.assert_true(_inside(presenter.tooltip), "tooltip is clamped inside viewport")
	t.assert_true(presenter.tooltip.body_label.text.contains("Durability") and presenter.tooltip.body_label.text.contains("Damage"), "equipment tooltip includes base stats and durability")
	var armor := ItemStack.new(&"leaf_vest", 1)
	armor.durability = 30
	presenter.tooltip.show_item(armor, ContentRegistry.get_item(&"leaf_vest"))
	t.assert_true(presenter.tooltip.body_label.text.contains("Defense  +2.0") and presenter.tooltip.body_label.text.contains("30 / 45"), "armor tooltip includes base modifiers and instance durability")
	t.assert_equal(_items(), snapshot, "selection, tab, hover, pagination and drag never mutate inventory or equipment")
	t.assert_equal(GameSession.player.inventory.capacity, original_capacity, "24 UI cells do not change existing model capacity")
	# Restore positions before the world lifecycle checks and optional rendered capture.
	bag.position = Vector2(24, 100)
	gear.position = Vector2(434, 100)
	bag.fit_to_viewport()
	await _capture(t)
	GameSession.player.inventory.add_item(&"rusty_scrap", 2)
	await _frames(t)
	await click(t, bag.tab_buttons[InventoryWindow.Tab.OTHER])
	t.assert_true(bag.slots[3].stack != null and bag.slots[3].stack.item_id == &"rusty_scrap" and bag.slots[3].stack.quantity == 2, "authoritative model change refreshes the actual fixed slot")
	t.assert_true(bag.slots[0].stack == null, "category tabs do not compact away other item positions")
	GameSession.player.inventory.move_slot(3, 7)
	await _frames(t)
	t.assert_true(bag.slots[3].stack == null and bag.slots[7].stack != null and bag.slots[7].stack.item_id == &"rusty_scrap", "read-only UI follows a model move and preserves its hole")
	var small_viewport := SubViewport.new()
	small_viewport.size = Vector2i(320, 240)
	t.add_child(small_viewport)
	var small_window := presenter.INVENTORY_SCENE.instantiate() as InventoryWindow
	small_viewport.add_child(small_window)
	await _frames(t)
	small_window.show_window()
	t.assert_true(_inside(small_window) and small_window.scale.x < 1, "small viewport fits all inventory cells without offscreen controls")
	small_viewport.size = Vector2i(240, 180)
	await _frames(t)
	t.assert_true(_inside(small_window), "viewport resize reclamps and scales the window")
	small_viewport.queue_free()
	await _frames(t)
	var instance := presenter.get_instance_id()
	var former_actor := NetworkManager.authoritative_actor(1).get_instance_id()
	_parse_key(KEY_A, true)
	t.assert_true(GameSession.begin_player_adventure(1, &"sewer_gate", &"sewer_region").success, "world fixture enters Sewer")
	app._present_local_world_assignment()
	await _frames(t)
	t.assert_true(presenter.get_instance_id() == instance and bag.visible and gear.visible, "open windows survive local world presentation replacement")
	var replacement := NetworkManager.authoritative_actor(1)
	t.assert_true(LocalInputContext.is_gameplay_blocked() and replacement != null \
		and replacement.get_instance_id() != former_actor and replacement.input.move_vector == Vector2.ZERO,
		"new world actor starts blocked while the same windows remain visible")
	_parse_key(KEY_A, false)
	var old := GameSession.player
	app._leave_game()
	await _frames(t)
	t.assert_true(not bag.visible and not gear.visible and not presenter.tooltip.visible, "Disconnect closes both windows and tooltip")
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "returning to the menu releases both owners")
	t.assert_true(presenter._state == null and bag.slots[0].stack == null, "menu releases old owner models and item snapshots")
	t.assert_true(not old.inventory.changed.is_connected(presenter.queue_refresh) \
		and not old.item_state_changed.is_connected(presenter._on_item_state_changed), "retired models release presenter signals")
	await click(t, app.new_game_button)
	await _frames(t)
	await key(t, KEY_I)
	await key(t, KEY_P)
	t.assert_true(bag.visible and gear.visible and presenter._state == GameSession.player and GameSession.player != old, "New Game binds new local state and reopens via physical keys")
	t.assert_equal(GameSession.get_local_player_id(), original_id, "UI lifecycle preserves persistent identity")
	var path := "user://inventory_ui_fixture.json"
	t.assert_true(SaveManager.save_game(path), "UI fixture writes Save v5")
	t.assert_true(SaveManager.load_game(path), "existing Save loader restores UI fixture")
	SceneRouter.go_to_settlement()
	await _frames(t)
	t.assert_true(presenter._state == GameSession.player, "Load rebinds presenter to restored model")
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "Load closes and releases the previous windows")
	var user_root := OS.get_environment("RTC_TEST_USER_ROOT").replace("\\", "/").trim_suffix("/")
	var default_save := ProjectSettings.globalize_path(SaveManager.SAVE_PATH).replace("\\", "/")
	if not user_root.is_empty() and default_save.begins_with(user_root + "/"):
		var loaded_session := GameSession.session_id
		t.assert_true(SaveManager.save_game(), "isolated GUI fixture writes the default save")
		app._leave_game()
		await _frames(t)
		await click(t, app.load_game_button)
		t.assert_true(not app.menu.visible and GameSession.session_id == loaded_session \
			and not LocalInputContext.is_gameplay_blocked(), "actual Load Game click restores the isolated save with no stale owner")
	await key(t, KEY_I)
	await key(t, KEY_P)
	t.assert_true(bag.visible and gear.visible, "Load Game permits I/P windows")
	await _check_item_actions(t, bag, gear, path)
	await _check_expanded_gear(t, bag, gear)
	await _check_slot_controls(t, bag)
	await click(t, bag.close_button)
	t.assert_true(not bag.visible, "close button receives real GUI input")
	await key(t, KEY_I)
	await _check_delayed_owner_update(t, bag)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	await _check_world_drop(t, bag, gear)
	await _check_death_and_teardown(t)
	NetworkManager.leave_game()
	app.queue_free()
	SceneRouter.register_world_layer(null)
	await _frames(t)

func _check_input_capture(t: Node) -> void:
	var bag := presenter.inventory_window
	var gear := presenter.equipment_window
	var actor := NetworkManager.authoritative_actor(1)
	t.assert_true(actor != null, "GUI input fixture has the offline actor")
	if actor == null:
		return
	for frame in 45:
		if actor.is_on_floor():
			break
		await t.get_tree().physics_frame
	_parse_key(KEY_D, true)
	await _frames(t)
	t.assert_true(Input.is_action_pressed(&"move_right") and actor.input.move_axis > 0.0, "real D key starts movement before opening inventory")
	await key(t, KEY_I)
	t.assert_true(bag.visible and not gear.visible and LocalInputContext.is_gameplay_blocked(), "I opens the inventory and acquires input")
	t.assert_equal(actor.input.move_vector, Vector2.ZERO, "opening the inventory immediately neutralizes held movement")
	# The actor keeps its authored locomotion deceleration after input stops.
	for frame in 30:
		if is_zero_approx(actor.velocity.x):
			break
		await t.get_tree().physics_frame
	var stopped_x := actor.position.x
	for frame in 4:
		await t.get_tree().physics_frame
	t.assert_true(is_zero_approx(actor.velocity.x) and is_equal_approx(actor.position.x, stopped_x),
		"held D cannot keep the real actor moving while the inventory is visible")

	var actions: Array[String] = []
	var jump := func() -> void: actions.append("jump")
	var attack := func() -> void: actions.append("attack")
	var dodge := func(_axis: float) -> void: actions.append("dodge")
	var interact := func() -> void: actions.append("interact")
	var quick_item := func() -> void: actions.append("quick item")
	actor.input.jump_requested.connect(jump)
	actor.input.attack_requested.connect(attack)
	actor.input.dodge_requested.connect(dodge)
	actor.input.interact_requested.connect(interact)
	actor.input.quick_item_requested.connect(quick_item)
	await _hover(t, Vector2(600, 680))
	for physical in [KEY_SPACE, KEY_J, KEY_SHIFT, KEY_E, KEY_Q]:
		await key(t, physical)
	t.assert_true(actions.is_empty() and not actor.input.take_jump_pressed(),
		"gameplay keys emit no action or pending jump while the pointer is over the world")
	for physical in [KEY_W, KEY_S, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
		_parse_key(physical, true)
		await _frames(t)
		t.assert_equal(actor.input.move_vector, Vector2.ZERO, "blocked movement or climb key %s keeps both axes neutral" % physical)
		_parse_key(physical, false)
	actor.input.jump_requested.disconnect(jump)
	actor.input.attack_requested.disconnect(attack)
	actor.input.dodge_requested.disconnect(dodge)
	actor.input.interact_requested.disconnect(interact)
	actor.input.quick_item_requested.disconnect(quick_item)

	await key(t, KEY_P)
	t.assert_true(bag.visible and gear.visible and LocalInputContext.is_gameplay_blocked(), "I and P can show both input owners")
	for editor in [LineEdit.new(), TextEdit.new()]:
		presenter.get_child(0).add_child(editor)
		editor.position = Vector2(850, 85)
		editor.size = Vector2(130, 60)
		editor.grab_focus()
		await key(t, KEY_I, 105)
		await key(t, KEY_P, 112)
		await key(t, KEY_ESCAPE)
		t.assert_true(editor.text == "ip" and bag.visible and gear.visible and not t.get_tree().paused,
			"text entry owns I/P and Escape without changing the item windows or pause")
		editor.free()

	await click(t, bag.close_button)
	t.assert_true(not bag.visible and gear.visible and LocalInputContext.is_gameplay_blocked(),
		"closing one window by mouse leaves the equipment window's block active")
	await key(t, KEY_ESCAPE)
	t.assert_true(not gear.visible and not LocalInputContext.is_gameplay_blocked() and not t.get_tree().paused,
		"Escape closes the last window without also pausing")
	t.assert_equal(actor.input.move_vector, Vector2.ZERO, "D held across close is still neutral")
	_parse_key(KEY_D, false)
	_parse_key(KEY_D, true)
	await _frames(t)
	t.assert_true(actor.input.move_axis > 0.0, "releasing and pressing D again restores normal movement")
	_parse_key(KEY_D, false)

	await key(t, KEY_ESCAPE)
	t.assert_true(t.get_tree().paused, "Escape pauses only after all item windows close")
	await key(t, KEY_ESCAPE)
	t.assert_true(not t.get_tree().paused, "a second Escape resumes gameplay")
	t.get_tree().paused = false
	for physical in [KEY_P, KEY_P, KEY_I, KEY_I]:
		await key(t, physical)
	t.assert_true(not bag.visible and not gear.visible and not LocalInputContext.is_gameplay_blocked(),
		"rapid I and P toggles leave no stale owner")

	await key(t, KEY_I)
	var window_root := bag.get_parent() as Control
	window_root.hide()
	t.assert_true(not bag.is_visible_in_tree() and not LocalInputContext.is_gameplay_blocked(),
		"hiding a window ancestor releases the effective visibility block")
	window_root.show()
	t.assert_true(bag.is_visible_in_tree() and LocalInputContext.is_gameplay_blocked(),
		"showing the ancestor reacquires the visible window's block")
	presenter.hide()
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "hiding the presenter's canvas releases input")
	presenter.show()
	t.assert_true(LocalInputContext.is_gameplay_blocked(), "showing the presenter's canvas restores its visible owner")
	await key(t, KEY_I)

func _check_death_and_teardown(t: Node) -> void:
	await click(t, app.new_game_button)
	await key(t, KEY_I)
	await key(t, KEY_P)
	var actor := NetworkManager.authoritative_actor(1)
	t.assert_true(actor != null and LocalInputContext.is_gameplay_blocked(), "death fixture starts with both windows open")
	if actor != null:
		var old_actor_id := actor.get_instance_id()
		actor.health.invulnerable_remaining = 0.0
		var damage := DamageContext.new(10000.0, &"item_ui_probe", null, &"environment")
		damage.can_be_evaded = false
		actor.health.receive_damage(damage)
		t.assert_true(not presenter.inventory_window.visible and not presenter.equipment_window.visible \
			and not LocalInputContext.is_gameplay_blocked(), "local death closes both windows and releases immediately")
		await key(t, KEY_I)
		t.assert_true(not presenter.inventory_window.visible, "item windows stay closed while respawning")
		await t.get_tree().create_timer(1.1).timeout
		var respawned := NetworkManager.authoritative_actor(1)
		t.assert_true(respawned != null and respawned.get_instance_id() != old_actor_id \
			and not LocalInputContext.is_gameplay_blocked(), "respawn creates a new actor with no stale block")

	await key(t, KEY_I)
	await key(t, KEY_P)
	t.assert_true(LocalInputContext.is_gameplay_blocked(), "newly visible item windows reacquire after respawn")
	app.get_parent().remove_child(app)
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "detaching the visible presenter releases input before the nodes are freed")

static func _parse_key(physical: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = physical
	event.physical_keycode = physical
	event.pressed = pressed
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _check_item_actions(t: Node, bag: InventoryWindow, gear: EquipmentWindow, path: String) -> void:
	var player := GameSession.player
	var main := player.inventory
	var body := EquipmentDefinition.EquipmentSlot.BODY
	var hand := EquipmentDefinition.EquipmentSlot.MAIN_HAND
	var legacy := ItemStack.new(&"leaf_vest", 1)
	legacy.durability = 31
	var newer := ItemStack.new(&"leaf_vest", 1)
	newer.instance_id = "gui-replacement-vest"
	newer.durability = 43
	main.initialize([legacy, newer, ItemStack.new(&"berry", 2)])
	player.survival.hunger = 30.0
	await _frames(t)
	await click(t, bag.tab_buttons[InventoryWindow.Tab.EQUIPMENT])
	var legacy_id := main.get_slot(0).instance_id
	t.assert_true(not legacy_id.is_empty() and main.get_slot(0).durability == 31 and legacy.instance_id.is_empty(), "authority assigns a carried legacy identity without mutating the input")
	var before := _items()
	await _drag(t, bag.slots[0], gear.slot_views[hand].get_global_rect().get_center())
	t.assert_true(_items() == before and bag._status.text.contains("different equipment slot"), "equipment drag refuses an unrelated slot")
	await _drag(t, bag.slots[0], gear.slot_views[body].get_global_rect().get_center())
	t.assert_true(gear.slot_views[body].stack != null and gear.slot_views[body].stack.instance_id == legacy_id and main.get_slot(0) == null, "GUI drag equips a legacy instance through the service")
	t.assert_equal(player.stats.value(&"defense"), 2.0, "equipment adds its defense modifier")
	await double_click(t, bag.slots[1])
	t.assert_true(player.equipment.equipped(body).instance_id == newer.instance_id and main.get_slot(0).instance_id == legacy_id and main.get_slot(0).durability == 31, "double-click replacement returns the previous identity and durability")
	t.assert_equal(player.stats.value(&"defense"), 2.0, "replacement applies the equipment modifier once")
	var full: Array[ItemStack] = [ItemStack.new(&"berry", 2)]
	main.initialize(full, 1)
	await _frames(t)
	before = _items()
	await double_click(t, gear.slot_views[body])
	t.assert_true(_items() == before and bag._status.text.contains("full") and presenter._pending_item_type == -1, "full main bag rejects unequip and unlocks the UI")
	main.expand_capacity(2)
	await _frames(t)
	await double_click(t, gear.slot_views[body])
	t.assert_true(gear.slot_views[body].stack == null and main.get_slot(1).instance_id == newer.instance_id, "double-click unequip uses the first free main bag slot")
	t.assert_equal(player.stats.value(&"defense"), 0.0, "unequip removes the equipment modifier")
	await double_click(t, bag.slots[1])
	await _drag(t, gear.slot_views[body], bag.slots[2].get_global_rect().get_center())
	t.assert_true(gear.slot_views[body].stack == null and main.get_slot(1).instance_id == newer.instance_id \
		and main.get_slot(2) == null and bag._status.text.contains("first free slot"), "unequip drag chooses the first free slot instead of the hovered cell")
	await double_click(t, bag.slots[1])
	await click(t, bag.tab_buttons[InventoryWindow.Tab.CONSUMABLE])
	await double_click(t, bag.slots[0])
	t.assert_equal(main.count(&"berry"), 1, "double-click consumes one ordinary item")
	t.assert_true(player.survival.hunger > 45.0 and player.stats.value(&"move_speed") > 190.0, "consumption reuses hunger and buff processing")
	t.assert_true(SaveManager.save_game(path) and SaveManager.load_game(path), "equipped replacement round-trips through Save v5")
	SceneRouter.go_to_settlement()
	await _frames(t)
	t.assert_true(GameSession.player.equipment.equipped(body).instance_id == newer.instance_id and GameSession.player.stats.value(&"defense") == 2.0, "load preserves equipped instance and restores its stat once")
	await key(t, KEY_I)
	await key(t, KEY_P)

func _check_expanded_gear(t: Node, bag: InventoryWindow, gear: EquipmentWindow) -> void:
	var player := GameSession.player
	var neck := EquipmentDefinition.EquipmentSlot.ACCESSORY_1
	var stack := ItemStack.new(&"acorn_necklace", 1)
	stack.durability = 40
	player.inventory.add_stack(stack)
	var buff := EffectDefinition.new()
	buff.id = &"gui_buff"
	buff.target_stat = &"max_health"
	buff.operation = EffectDefinition.Operation.MULTIPLY
	buff.magnitude = 1.5
	buff.duration_seconds = 30.0
	player.effects.apply_effect(buff)
	await _frames(t)
	t.assert_equal(gear._stat_values.size(), 6, "equipment window displays all six player stats")
	t.assert_equal(gear._stat_values[&"max_health"].text, "150.0", "equipment window observes a live stat change")
	await click(t, bag.tab_buttons[InventoryWindow.Tab.EQUIPMENT])
	var view: ItemSlotView
	for slot in bag.slots:
		if slot.stack != null and slot.stack.item_id == stack.item_id:
			view = slot
			break
	t.assert_true(view != null, "new accessory appears in the equipment tab")
	if view == null:
		return
	await click(t, view)
	await _hover(t, Vector2(5, 5))
	t.assert_true(presenter.tooltip.visible and presenter.tooltip.body_label.text.contains("Equipped: Empty slot") \
		and presenter.tooltip.body_label.text.contains("+15.0") and _inside(presenter.tooltip), "selected accessory retains its buff-aware comparison inside the viewport")
	var before := player.equipment.to_dict()
	await _drag(t, view, gear.slot_views[EquipmentDefinition.EquipmentSlot.ACCESSORY_2].get_global_rect().get_center())
	t.assert_true(player.equipment.to_dict() == before and bag._status.text.contains("different equipment slot"), "drag rejects the wrong accessory slot")
	var sequence := PlayerItemReplicationService._next_local_sequence
	await _drag(t, view, gear.slot_views[neck].get_global_rect().get_center())
	t.assert_equal(PlayerItemReplicationService._next_local_sequence, sequence + 1, "equipment drop submits only the equip command")
	t.assert_true(gear.slot_views[neck].stack != null and gear._stat_values[&"max_health"].text == "165.0", "equipping the accessory matches its comparison and refreshes the stat panel")
	await double_click(t, gear.slot_views[neck])
	t.assert_true(gear.slot_views[neck].stack == null and gear._stat_values[&"max_health"].text == "150.0", "unequip restores the buffed value without the equipment bonus")
	player.effects.tick(buff.duration_seconds)
	await _frames(t)
	t.assert_equal(gear._stat_values[&"max_health"].text, "100.0", "stat panel follows actual buff expiration")
	var broken := ItemStack.new(&"acorn_necklace", 1)
	broken.durability = 0
	t.assert_true(player.inventory.add_stack(broken).success, "broken gear has a distinct inventory instance")
	await _frames(t)
	for cell in bag.slots:
		if cell.stack != null and cell.stack.item_id == broken.item_id and cell.stack.durability == 0:
			await double_click(t, cell)
			break
	t.assert_true(gear._durability[neck].text.contains("0 / 40") and gear._stat_values[&"max_health"].text == "100.0",
		"broken gear displays zero durability and contributes no stats")

func _check_slot_controls(t: Node, bag: InventoryWindow) -> void:
	var main := GameSession.player.inventory
	var protected := GameSession.player.protected_inventory
	var cells: Array[ItemStack] = []
	cells.resize(29)
	cells[0] = ItemStack.new(&"berry", 8)
	cells[1] = ItemStack.new(&"rusty_scrap", 2)
	cells[2] = ItemStack.new(&"return_seed", 1)
	cells[4] = ItemStack.new(&"berry", 3)
	cells[24] = ItemStack.new(&"berry", 5)
	t.assert_true(main.initialize_slots(cells, 29).success, "GUI fixture seeds sparse main bag")
	var protected_cells: Array[ItemStack] = []
	protected_cells.resize(protected.capacity)
	protected_cells[0] = ItemStack.new(&"berry", 2)
	t.assert_true(protected.initialize_slots(protected_cells).success, "GUI fixture seeds independent protected bag")
	await _frames(t)
	await click(t, bag.tab_buttons[InventoryWindow.Tab.CONSUMABLE])
	await click(t, bag.slots[0])
	await click(t, bag.slots[3])
	t.assert_equal(bag.selected_slot, -1, "real click on an empty cell clears selection")
	var actor := NetworkManager.authoritative_actor(1)
	var dodge_requests := [0]
	var count_dodge := func(_axis: float) -> void: dodge_requests[0] += 1
	actor.input.dodge_requested.connect(count_dodge)
	await _hover(t, bag.slots[0].get_global_rect().get_center())
	var shift := InputEventKey.new()
	shift.physical_keycode = KEY_SHIFT
	shift.location = KEY_LOCATION_LEFT
	shift.pressed = true
	t.assert_true(shift.is_action_pressed(&"dodge"), "physical Left Shift is also mapped to dodge")
	t.get_viewport().push_input(shift, true)
	t.assert_equal(dodge_requests[0], 0, "Shift over inventory is reserved for split instead of dodge")
	var shift_up := shift.duplicate() as InputEventKey
	shift_up.pressed = false
	t.get_viewport().push_input(shift_up, true)
	var before := main.to_slot_dict()
	var sequence := PlayerItemReplicationService._next_local_sequence
	t.assert_true(bag.slots[1].stack == null, "other category is hidden in place")
	await _drag(t, bag.slots[0], bag.slots[1].get_global_rect().get_center())
	t.assert_true(bag._status.text.contains("another tab") and main.to_slot_dict() == before, "hidden target refuses drop with an explanation")
	t.assert_equal(PlayerItemReplicationService._next_local_sequence, sequence, "hidden target never submits a command")
	await _drag(t, bag.slots[0], bag.title_bar.get_global_rect().get_center())
	t.assert_equal(main.to_slot_dict(), before, "releasing on the inventory title bar cancels the drag")
	var escape := func() -> void:
		var event := InputEventKey.new()
		event.keycode = KEY_ESCAPE
		event.physical_keycode = KEY_ESCAPE
		event.pressed = true
		t.get_viewport().push_input(event, true)
		var up := event.duplicate() as InputEventKey
		up.pressed = false
		t.get_viewport().push_input(up, true)
	await _drag(t, bag.slots[0], bag.slots[3].get_global_rect().get_center(), false, escape)
	t.assert_true(bag.visible and not t.get_tree().paused and main.to_slot_dict() == before, "Escape cancels a live drag before closing a window or pausing")
	t.get_tree().paused = false
	if not bag.visible:
		bag.show_window()
	await _drag(t, bag.slots[0], bag.slots[3].get_global_rect().get_center(), false, func() -> void:
		bag.tab_buttons[InventoryWindow.Tab.OTHER].grab_focus()
		var activate := InputEventAction.new()
		activate.action = &"ui_accept"
		activate.pressed = true
		t.get_viewport().push_input(activate, true)
		activate.pressed = false
		t.get_viewport().push_input(activate, true)
	)
	t.assert_true(bag.current_tab == InventoryWindow.Tab.OTHER and main.to_slot_dict() == before, "switching tabs with GUI input invalidates the active drag")
	await click(t, bag.tab_buttons[InventoryWindow.Tab.CONSUMABLE])
	await _drag(t, bag.slots[0], bag.slots[3].get_global_rect().get_center())
	t.assert_equal(PlayerItemReplicationService._next_local_sequence, sequence + 1, "slot drop submits only the move command")
	t.assert_true(main.get_slot(0) == null and main.get_slot(3) != null and bag.slots[3].stack != null, "GUI drag moves into a real empty slot")
	await _drag(t, bag.slots[3], bag.slots[2].get_global_rect().get_center())
	t.assert_true(main.get_slot(2) != null and main.get_slot(2).item_id == &"berry" and main.get_slot(3).item_id == &"return_seed", "GUI drag swaps different visible items")
	await _drag(t, bag.slots[4], bag.slots[2].get_global_rect().get_center())
	t.assert_true(main.get_slot(4) != null and main.get_slot(4).quantity == 1 and main.get_slot(2).quantity == 10, "GUI drag merges compatible stacks")
	before = main.to_slot_dict()
	await _drag(t, bag.slots[2], bag.slots[5].get_global_rect().get_center(), true)
	t.assert_true(bag._split_dialog.visible and main.to_slot_dict() == before, "Shift drag opens a quantity dialog without mutating the bag")
	if bag._split_dialog.visible:
		await click(t, bag._split_dialog.get_cancel_button())
	t.assert_true(not bag._split_dialog.visible and main.to_slot_dict() == before, "canceling split keeps the exact layout")
	await _drag(t, bag.slots[2], bag.slots[3].get_global_rect().get_center(), true)
	t.assert_true(not bag._split_dialog.visible and main.to_slot_dict() == before and bag._status.text.contains("empty slot"), "Shift drag rejects an occupied destination")
	await _drag(t, bag.slots[2], bag.slots[5].get_global_rect().get_center(), true)
	if bag._split_dialog.visible:
		bag._split_amount.text = "10"
		await click(t, bag._split_dialog.get_ok_button())
	t.assert_true(main.to_slot_dict() == before and bag._status.text.contains("1 to 9"), "split of the whole stack is rejected without clamping")
	await _drag(t, bag.slots[2], bag.slots[5].get_global_rect().get_center(), true)
	if bag._split_dialog.visible:
		bag._split_amount.text = "4"
		await click(t, bag._split_dialog.get_ok_button())
	t.assert_true(main.get_slot(5) != null and main.get_slot(5).quantity == 4 and main.get_slot(2).quantity == 6, "confirmed Shift drag splits the requested amount")
	await click(t, bag.get_node("%Next"))
	await _drag(t, bag.slots[0], bag.slots[1].get_global_rect().get_center())
	t.assert_true(bag.page == 1 and main.get_slot(24) == null and main.get_slot(25) != null and main.get_slot(25).quantity == 5, "second-page GUI cells map to real indices 24 and 25")
	await _drag(t, bag.slots[1], bag.slots[6].get_global_rect().get_center())
	t.assert_true(bag._status.text.contains("outside the bag") and main.get_slot(25) != null, "page padding is not inventory capacity")
	var main_before := main.to_slot_dict()
	var protected_before := protected.to_slot_dict()
	await _drag(t, bag.slots[1], bag.slots[1].get_global_rect().get_center(), false, func() -> void:
		bag._bag_picker.select(1)
		bag._bag_picker.item_selected.emit(1)
	)
	t.assert_true(bag._status.text.contains("same bag") and main.to_slot_dict() == main_before and protected.to_slot_dict() == protected_before, "a drag cannot cross bag boundaries")
	await _drag(t, bag.slots[0], bag.slots[1].get_global_rect().get_center())
	t.assert_true(protected.get_slot(0) == null and protected.get_slot(1) != null and protected.get_slot(1).quantity == 2 and main.to_slot_dict() == main_before, "protected slot indices are independent from main")
	await click(t, bag._sort)
	t.assert_true(protected.get_slot(0) != null and protected.get_slot(1) == null and main.to_slot_dict() == main_before, "Sort whole bag sorts the selected bag only")
	await click(t, bag._bag_picker)
	var popup := bag._bag_picker.get_popup()
	t.assert_true(popup.visible, "click opens the bag dropdown")
	if popup.visible:
		var first_option := Vector2(popup.position) + Vector2(popup.size.x * 0.5, 12.0)
		await _hover(t, first_option)
		_mouse(t, first_option, true)
		_mouse(t, first_option, false)
		await _frames(t)
	t.assert_equal(bag.inventory_kind, InventoryWindow.Bag.MAIN, "real dropdown click switches from protected to main bag")
	await click(t, bag._sort)
	t.assert_true(main.get_slot(25) == null and main.count(&"berry") == 16 and main.count(&"rusty_scrap") == 2, "whole main bag sort includes categories hidden by the tab")
	await _hover(t, Vector2(5, 5))
	t.get_viewport().push_input(shift, true)
	t.assert_equal(dodge_requests[0], 0, "Left Shift over the world cannot dodge while item windows are visible")
	t.get_viewport().push_input(shift_up, true)
	await click(t, bag.close_button)
	await click(t, presenter.equipment_window.close_button)
	await key(t, KEY_SHIFT)
	t.assert_equal(dodge_requests[0], 1, "Left Shift sends a gameplay input after both item windows close")
	actor.input.dodge_requested.disconnect(count_dodge)
	await key(t, KEY_I)
	await key(t, KEY_P)

func _check_delayed_owner_update(t: Node, bag: InventoryWindow) -> void:
	var original := presenter._service
	var delayed := DelayedUseService.new()
	presenter._service = delayed
	delayed.use_item_result.connect(presenter._on_item_result.bind(PlayerItemReplicationService.CommandType.USE_ITEM))
	var state := GameSession.get_local_player()
	var before := state.inventory.to_slot_dict()
	var revision := state.item_state_revision
	var target: ItemSlotView
	for view in bag.slots:
		if view.stack != null and view.stack.item_id == &"berry":
			target = view
			break
	t.assert_true(target != null, "delayed owner update has a visible berry fixture")
	if target != null:
		var index := bag._slot_index(bag.slots.find(target))
		await double_click(t, target)
		t.assert_true(bag._pending and delayed.submissions == 1, "real double-click waits for a use result")
		presenter._on_item_result(false, "Unrelated equipment result", PlayerItemReplicationService.CommandType.EQUIP)
		t.assert_true(bag._pending, "a different result type cannot release the current command")
		delayed.use_item_result.emit(true, "Used berry")
		t.assert_true(bag._pending and state.inventory.to_slot_dict() == before, "success alone keeps the request pending while the owner update is held")
		if bag._pending:
			await double_click(t, target)
			t.assert_equal(delayed.submissions, 1, "late owner update blocks another click against the previous layout")
		await click(t, bag.get_node("%Next"))
		t.assert_true(bag.page == 1 and bag._pending, "page navigation preserves the outstanding request")
		var snapshot := PlayerItemStateSnapshot.from_state(GameSession.get_local_player_id(), state)
		snapshot.revision = revision + 1
		snapshot.inventory[index].quantity -= 1
		t.assert_true(state.apply_item_network_mirror(snapshot), "held owner update can be applied to the bound model")
		await _frames(t)
		t.assert_true(not bag._pending and state.item_state_revision == revision + 1 and bag._status.text == "Used berry" and bag.page == 1, "owner update releases the acknowledged command and refreshes feedback")
		await click(t, bag.get_node("%Previous"))
		await double_click(t, target)
		t.assert_true(bag._pending and delayed.submissions == 2, "updated layout permits a new action")
		presenter._service = original
		app._leave_game()
		await _frames(t)
		delayed.use_item_result.emit(true, "Retired session result")
		t.assert_true(not bag.visible and not bag._pending and presenter._state == null and bag._status.text.is_empty(),
			"a late item result after Disconnect cannot alter menu state")
	else:
		presenter._service = original
	delayed.free()

func _check_world_drop(t: Node, bag: InventoryWindow, gear: EquipmentWindow) -> void:
	await click(t, app.new_game_button)
	await key(t, KEY_I)
	await key(t, KEY_P)
	var state := GameSession.get_local_player()
	var cells: Array[ItemStack] = []
	cells.resize(26)
	cells[0] = ItemStack.new(&"berry", 4)
	cells[1] = ItemStack.new(&"return_seed", 1)
	cells[24] = ItemStack.new(&"berry", 3)
	state.inventory.initialize_slots(cells, 26)
	await _frames(t)
	var ground := Vector2(5, 5)
	var before := state.inventory.to_slot_dict()
	var sequence := PlayerItemReplicationService._next_local_sequence
	await _drag(t, bag.slots[1], ground)
	t.assert_true(PlayerItemReplicationService._next_local_sequence == sequence + 1 \
		and state.inventory.to_slot_dict() == before and bag._status.text.contains("cannot be dropped"), "a world drop rejected by the server keeps the stack and shows feedback")

	sequence = PlayerItemReplicationService._next_local_sequence
	for destination in [Vector2(-5, 5), bag.slots[0].get_global_rect().get_center(),
			bag._status.get_global_rect().get_center(), gear.title_bar.get_global_rect().get_center(),
			app.multiplayer_panel.address_edit.get_global_rect().get_center()]:
		await _drag(t, bag.slots[0], destination)
	await _drag(t, bag.slots[0], ground, true)
	await _drag(t, bag.slots[0], ground, false, func() -> void:
		_parse_key(KEY_ESCAPE, true)
		_parse_key(KEY_ESCAPE, false)
	)
	var popup := ConfirmationDialog.new()
	popup.visible = false
	app.add_child(popup)
	await _drag(t, bag.slots[0], Vector2(55, 55), false, func() -> void:
		popup.popup(Rect2i(15, 15, 150, 90))
	)
	popup.hide()
	t.get_viewport().gui_cancel_drag()
	popup.queue_free()
	await _drag(t, bag.slots[0], ground, false, func() -> void: bag._change_page(1))
	t.assert_equal(bag.page, 1, "changing pages during a drag changes the visible page")
	await _drag(t, bag.slots[0], ground, false, func() -> void: bag.select_tab(InventoryWindow.Tab.OTHER))
	bag.select_tab(InventoryWindow.Tab.CONSUMABLE)
	await _drag(t, bag.slots[0], ground, false, func() -> void: bag.hide_window())
	bag.show_window()
	t.assert_true(PlayerItemReplicationService._next_local_sequence == sequence and state.inventory.to_slot_dict() == before,
		"outside viewport, slot, window chrome, other UI, modal, Shift, Escape, page, tab and close never submit a world drop")

	await _drag(t, bag.slots[0], ground, false, func() -> void: state.inventory.add_item(&"rusty_scrap", 1))
	t.assert_equal(PlayerItemReplicationService._next_local_sequence, sequence, "an owner revision change invalidates the old drag")
	state.inventory.initialize_slots(cells, 26)
	await _frames(t)
	await _drag(t, bag.slots[0], ground, false, func() -> void:
		t.assert_true(GameSession.begin_player_adventure(1, &"sewer_gate", &"sewer_region").success, "drop fixture enters Sewer")
		app._present_local_world_assignment()
	)
	t.assert_equal(PlayerItemReplicationService._next_local_sequence, sequence, "world change invalidates the old drag")

	var original := presenter._service
	var delayed := DelayedDropService.new()
	presenter._service = delayed
	delayed.slot_result.connect(presenter._on_slot_result, CONNECT_DEFERRED)
	await _drag(t, bag.slots[0], ground)
	var pending := presenter._pending_sequence
	t.assert_true(bag._pending and delayed.submissions == [Vector2i(InventoryWindow.Bag.MAIN, 0)] \
		and state.inventory.to_slot_dict() == before, "world drop waits for authority without editing the displayed stack")
	await _drag(t, bag.slots[0], ground)
	delayed.slot_result.emit(pending - 1, false, "Retired request")
	await _frames(t)
	t.assert_true(bag._pending and delayed.submissions.size() == 1, "pending drop blocks another drag and ignores unrelated results")
	delayed.slot_result.emit(pending, true, "Dropped item")
	await _frames(t)
	t.assert_true(bag._pending and state.inventory.to_slot_dict() == before, "successful response waits for the owner update")
	var snapshot := PlayerItemStateSnapshot.from_state(GameSession.get_local_player_id(), state)
	snapshot.revision += 1
	snapshot.inventory[0] = null
	t.assert_true(state.apply_item_network_mirror(snapshot), "delayed owner snapshot applies")
	await _frames(t)
	t.assert_true(not bag._pending and bag.slots[0].stack == null, "owner snapshot updates the slot and releases the drop")
	presenter._service = original

	var world := app.world_layer.get_child(0)
	var manager := world.get_node("LootSpawnManager") as LootSpawnManager
	var existing := manager.entity_ids()
	await click(t, bag.get_node("%Next"))
	await _drag(t, bag.slots[0], ground)
	t.assert_true(state.inventory.get_slot(24) == null and bag.slots[0].stack == null, "world drop removes the actual second-page slot")
	var dropped: LootActor
	for id in manager.entity_ids():
		if id not in existing:
			dropped = manager.get_loot(id)
	t.assert_true(dropped != null and dropped.stack.item_id == &"berry" and dropped.stack.quantity == 3,
		"the authoritative manager creates the complete dropped stack")

	state.inventory.add_item(&"berry", 1)
	await _frames(t)
	await click(t, bag.get_node("%Previous"))
	presenter._service = delayed
	await _drag(t, bag.slots[0], ground)
	pending = presenter._pending_sequence
	t.assert_true(bag._pending, "drop is pending before leaving the world")
	t.assert_true(GameSession.finish_player_adventure(1, AdventureSession.Result.NORMAL_ESCAPE).success, "pending-drop fixture leaves Sewer")
	app._present_local_world_assignment()
	delayed.slot_result.emit(pending, false, "Old world response")
	await _frames(t)
	t.assert_true(not bag._pending and bag._status.text.is_empty() and state.inventory.count(&"berry") == 1,
		"late drop result cannot change the new world's UI or inventory")
	presenter._service = original
	delayed.free()
	app._leave_game()
	await _frames(t)

static func _drag(t: Node, source: ItemSlotView, destination: Vector2, split: bool = false, during: Callable = Callable()) -> void:
	var origin := source.get_global_rect().get_center()
	await _hover(t, origin)
	_mouse(t, origin, true, split)
	var previous := origin
	for position: Vector2 in [origin + Vector2(15, 0), destination]:
		var motion := InputEventMouseMotion.new()
		motion.position = position
		motion.global_position = position
		motion.relative = position - previous
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		motion.shift_pressed = split
		t.get_viewport().push_input(motion, true)
		await t.get_tree().process_frame
		if previous == origin and during.is_valid():
			during.call()
			await _frames(t)
		previous = position
	_mouse(t, destination, false, split)
	await _frames(t)

static func _items() -> Dictionary:
	return {"bag": GameSession.player.inventory.to_array(), "protected": GameSession.player.protected_inventory.to_array(), "equipment": GameSession.player.equipment.to_dict()}

static func _inside(control: Control) -> bool:
	var rect := control.get_global_rect()
	return rect.position.x >= 0 and rect.position.y >= 0 and rect.end.x <= control.get_viewport_rect().end.x + 1 and rect.end.y <= control.get_viewport_rect().end.y + 1

static func _frames(t: Node) -> void:
	await t.get_tree().process_frame
	await t.get_tree().process_frame

static func key(t: Node, physical: Key, unicode: int = 0) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = physical
	event.keycode = physical
	event.unicode = unicode
	if physical == KEY_SHIFT:
		event.location = KEY_LOCATION_LEFT
	event.pressed = true
	t.get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	t.get_viewport().push_input(event, true)
	await _frames(t)

static func _hover(t: Node, position: Vector2, viewport: Viewport = null) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	(viewport if viewport != null else t.get_viewport()).push_input(motion, true)
	await _frames(t)

static func _mouse(t: Node, position: Vector2, pressed: bool, shift: bool = false, viewport: Viewport = null, twice: bool = false) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.shift_pressed = shift
	event.double_click = twice
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	(viewport if viewport != null else t.get_viewport()).push_input(event, true)

static func click(t: Node, control: Control) -> void:
	var center := control.get_global_rect().get_center()
	var viewport := control.get_viewport()
	if viewport is Window and viewport != t.get_viewport() and viewport.is_embedded():
		center += Vector2(viewport.position)
		viewport = t.get_viewport()
	await _hover(t, center, viewport)
	_mouse(t, center, true, false, viewport)
	await t.get_tree().process_frame
	_mouse(t, center, false, false, viewport)
	await _frames(t)

static func double_click(t: Node, control: Control) -> void:
	await click(t, control)
	var center := control.get_global_rect().get_center()
	_mouse(t, center, true, false, control.get_viewport(), true)
	_mouse(t, center, false, false, control.get_viewport())
	await _frames(t)

func _capture(t: Node) -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--inventory-ui-screenshot=") and DisplayServer.get_name() != "headless":
			presenter.tooltip.show_item(presenter.equipment_window.slot_views[0].stack, presenter.equipment_window.slot_views[0].definition)
			await t.get_tree().process_frame
			await RenderingServer.frame_post_draw
			t.get_viewport().get_texture().get_image().save_png(argument.trim_prefix("--inventory-ui-screenshot="))
