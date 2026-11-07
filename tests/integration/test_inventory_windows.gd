extends RefCounted

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
	t.assert_equal(bag.slots.size(), 24, "inventory always renders 6 by 4 presentation cells")
	t.assert_equal(bag.get_node("%Grid").columns, 6, "inventory has six columns")
	t.assert_equal(gear.slot_views.size(), 2, "equipment layout connects exactly existing MAIN_HAND and BODY")
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
	t.assert_true(GameSession.begin_player_adventure(1, &"sewer_gate", &"sewer_region").success, "world fixture enters Sewer")
	app._present_local_world_assignment()
	await _frames(t)
	t.assert_true(presenter.get_instance_id() == instance and bag.visible and gear.visible, "open windows survive local world presentation replacement")
	var old := GameSession.player
	app._leave_game()
	await _frames(t)
	t.assert_true(not bag.visible and not gear.visible and not presenter.tooltip.visible, "Disconnect closes both windows and tooltip")
	t.assert_true(presenter._state == null and bag.slots[0].stack == null, "menu releases old owner models and item snapshots")
	t.assert_true(not old.inventory.changed.is_connected(presenter.queue_refresh), "retired models release presenter signals")
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
	await key(t, KEY_I)
	await key(t, KEY_P)
	t.assert_true(bag.visible and gear.visible, "Load Game permits I/P windows")
	await _check_item_actions(t, bag, gear, path)
	await _check_slot_controls(t, bag)
	await click(t, bag.close_button)
	t.assert_true(not bag.visible, "close button receives real GUI input")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	NetworkManager.leave_game()
	app.get_parent().remove_child(app)
	app.queue_free()
	SceneRouter.register_world_layer(null)
	await _frames(t)

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
		and main.get_slot(2) == null, "unequip drag chooses the first free slot instead of the hovered cell")
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
	var before := main.to_slot_dict()
	var sequence := PlayerItemReplicationService._next_local_sequence
	t.assert_true(bag.slots[1].stack == null, "other category is hidden in place")
	await _drag(t, bag.slots[0], bag.slots[1].get_global_rect().get_center())
	t.assert_true(bag._status.text.contains("another tab") and main.to_slot_dict() == before, "hidden target refuses drop with an explanation")
	t.assert_equal(PlayerItemReplicationService._next_local_sequence, sequence, "hidden target never submits a command")
	await _drag(t, bag.slots[0], Vector2(5, 5))
	t.assert_equal(main.to_slot_dict(), before, "releasing outside the grid cancels the drag")
	await _drag(t, bag.slots[0], bag.slots[3].get_global_rect().get_center())
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
	bag._bag_picker.select(0)
	bag._bag_picker.item_selected.emit(0)
	await click(t, bag._sort)
	t.assert_true(main.get_slot(25) == null and main.count(&"berry") == 16 and main.count(&"rusty_scrap") == 2, "whole main bag sort includes categories hidden by the tab")
	await _hover(t, Vector2(5, 5))
	t.get_viewport().push_input(shift, true)
	t.assert_equal(dodge_requests[0], 1, "Left Shift outside inventory still sends the gameplay input")
	actor.input.dodge_requested.disconnect(count_dodge)

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

static func key(t: Node, physical: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = physical
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
