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
	t.assert_true(SaveManager.save_game(path), "UI fixture writes unchanged Save v4")
	t.assert_true(SaveManager.load_game(path), "existing Save loader restores UI fixture")
	await _frames(t)
	t.assert_true(presenter._state == GameSession.player, "Load rebinds presenter to restored model")
	await key(t, KEY_I)
	await key(t, KEY_P)
	t.assert_true(bag.visible and gear.visible, "Load Game permits I/P windows")
	await click(t, bag.close_button)
	t.assert_true(not bag.visible, "close button receives real GUI input")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	NetworkManager.leave_game()
	app.get_parent().remove_child(app)
	app.queue_free()
	SceneRouter.register_world_layer(null)
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

static func _hover(t: Node, position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	t.get_viewport().push_input(motion, true)
	await _frames(t)

static func _mouse(t: Node, position: Vector2, pressed: bool) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.global_position = position
	event.button_index = MOUSE_BUTTON_LEFT
	event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
	event.pressed = pressed
	t.get_viewport().push_input(event, true)

static func click(t: Node, control: Control) -> void:
	var center := control.get_global_rect().get_center()
	await _hover(t, center)
	_mouse(t, center, true)
	await t.get_tree().process_frame
	_mouse(t, center, false)
	await _frames(t)

func _capture(t: Node) -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--inventory-ui-screenshot=") and DisplayServer.get_name() != "headless":
			presenter.tooltip.show_item(presenter.equipment_window.slot_views[0].stack, presenter.equipment_window.slot_views[0].definition)
			await t.get_tree().process_frame
			await RenderingServer.frame_post_draw
			t.get_viewport().get_texture().get_image().save_png(argument.trim_prefix("--inventory-ui-screenshot="))
