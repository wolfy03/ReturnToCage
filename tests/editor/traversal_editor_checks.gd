@tool
extends RefCounted

static func run(plugin: EditorPlugin) -> void:
	var before_failures: int = plugin.get("_failures")
	var root: Node2D = plugin.call("_field_root")
	var dialog: ConfirmationDialog = plugin.get("_region_design")
	var controller: Node = plugin.get("_traversal")
	var visualization: RefCounted = plugin.get("_visualization")
	# STEP 6 intentionally leaves an external resource edit. Explicitly reload it,
	# just as the UI asks the author to review external changes before analysis.
	var catalog: RefCounted = plugin.get("_catalog")
	var linked: RegionDefinition = preload("res://addons/rtc_field_editor/level_design.gd").region_for(root, catalog)
	if linked != null:
		var fresh := ResourceLoader.load(linked.resource_path, "", ResourceLoader.CACHE_MODE_REPLACE) as RegionDefinition
		var definitions: Dictionary = catalog.get("definitions")
		definitions[fresh.id] = fresh
		var regions: Array = catalog.get("regions")
		for index in regions.size():
			if regions[index].id == fresh.id:
				regions[index] = fresh
	dialog.call("show_region", root)
	var page: OptionButton = dialog.get("page")
	page.select(5)
	page.item_selected.emit(5)
	await plugin.get_tree().process_frame
	var body: VBoxContainer = dialog.get("body")
	var button := body.get_child(1).get_child(0) as Button
	plugin.call("_check", button.text == "Analyze Traversal", "Traversal page opens without replacing STEP 6 pages")
	await _click(dialog, button)
	plugin.call("_check", controller.get("running"), "GUI analysis click launches isolated verifier")
	await _finished(plugin, controller)
	var data: Dictionary = controller.get("report")
	plugin.call("_check", not data.is_empty(), "editor receives checked physics report: " + str(controller.get("message")))
	if not data.is_empty():
		plugin.call("_check", data.routes.size() == data.starts.size() * data.escapes.size(), "no slot omitted from editor reachability results")
		var enabled: Array[bool] = visualization.get("enabled")
		enabled.resize(15)
		for index in range(8, 15):
			enabled[index] = true
		visualization.set("enabled", enabled)
		plugin.update_overlays()
		await plugin.get_tree().process_frame
		var list: ItemList
		for child in body.get_children():
			if child is ItemList:
				list = child
		if list != null and list.item_count > 0:
			if DisplayServer.get_name() == "headless":
				list.select(0)
				list.item_selected.emit(0)
			else:
				await _click(dialog, list, list.get_item_rect(0).get_center())
			plugin.call("_check", EditorInterface.get_selection().get_selected_nodes().has(list.get_item_metadata(0)), "traversal result selects authored terrain")
		var terrain := root.get_node("Terrain").get_child(0) as Node2D
		var previous := terrain.position
		terrain.position.x += 32
		await plugin.get_tree().create_timer(0.3).timeout
		plugin.call("_check", controller.get("report").is_empty(), "direct geometry edit invalidates cached physics evidence")
		terrain.position = previous
	dialog.call("_refresh", 5)
	body = dialog.get("body")
	button = body.get_child(1).get_child(0)
	await _click(dialog, button)
	controller.call("cancel")
	await _finished(plugin, controller)
	plugin.call("_check", controller.get("report").is_empty(), "cancelled job never imports successful racing output")
	dialog.call("_refresh", 5)
	body = dialog.get("body")
	await _click(dialog, body.get_child(1).get_child(0))
	await _finished(plugin, controller)
	plugin.call("_check", not controller.get("report").is_empty(), "reanalysis after edit/cancel succeeds: " + str(controller.get("message")))
	var transient := Node2D.new()
	root.get_node("Terrain").add_child(transient)
	plugin.call("_check", controller.get("report").is_empty(), "direct node insertion invalidates cached topology without waiting for save")
	transient.free()
	var path := root.scene_file_path
	var packed := PackedScene.new()
	plugin.call("_check", packed.pack(root) == OK and ResourceSaver.save(packed, path) == OK, "analyzed scene saves through normal PackedScene")
	var loaded := (ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	plugin.call("_check", not loaded.has_meta("traversal") and loaded.find_children("*", "PlayerActor", true, false).is_empty(), "no analysis actors or overlay data serialized into scene")
	loaded.free()
	dialog.hide()
	plugin.call("_check", EditorInterface.close_scene() == OK, "close analyzed scene tab")
	await plugin.get_tree().process_frame
	EditorInterface.open_scene_from_path(path)
	for frame in 120:
		await plugin.get_tree().process_frame
		var reopened: Node2D = plugin.call("_field_root")
		if reopened != null and reopened.scene_file_path == path and reopened != root:
			break
	var reopened: Node2D = plugin.call("_field_root")
	plugin.call("_check", reopened != null and reopened != root and controller.get("report").is_empty(), "reopen invalidates old evidence and preserves scene structure")
	dialog.call("show_region", reopened)
	page.select(5)
	page.item_selected.emit(5)
	body = dialog.get("body")
	await _click(dialog, body.get_child(1).get_child(0))
	await _finished(plugin, controller)
	plugin.call("_check", not controller.get("report").is_empty(), "saved and reopened scene can be verified again")
	dialog.hide()
	controller.call("clear")
	plugin.call("_check", controller.get("report").is_empty(), "clear releases editor analysis")
	print("TRAVERSAL EDITOR GUI ", "PASS" if plugin.get("_failures") == before_failures else "FAIL", " mode=", DisplayServer.get_name(), " input=", "injected Window mouse events" if DisplayServer.get_name() != "headless" else "button signal")

static func _click(window: Window, button: Control, local := Vector2.INF) -> void:
	if DisplayServer.get_name() == "headless":
		if button is Button:
			button.pressed.emit()
	else:
		window.grab_focus()
		await window.get_tree().create_timer(0.15).timeout
		var at := button.get_global_rect().get_center() if not local.is_finite() else button.global_position + local
		window.warp_mouse(at)
		await window.get_tree().process_frame
		var motion := InputEventMouseMotion.new()
		motion.window_id = window.get_window_id()
		motion.position = at
		motion.global_position = motion.position
		Input.parse_input_event(motion)
		await window.get_tree().process_frame
		for pressed in [true, false]:
			var event := InputEventMouseButton.new()
			event.window_id = window.get_window_id()
			event.button_index = MOUSE_BUTTON_LEFT
			event.pressed = pressed
			event.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed else 0
			event.position = at
			event.global_position = event.position
			Input.parse_input_event(event)
			await window.get_tree().process_frame

static func _finished(plugin: EditorPlugin, controller: Node) -> void:
	var deadline := Time.get_ticks_msec() + 45000
	while controller.get("running") and Time.get_ticks_msec() < deadline:
		await plugin.get_tree().process_frame
	plugin.call("_check", not controller.get("running"), "bounded asynchronous analysis completes without blocking editor")
