@tool
extends ConfirmationDialog

const Design := preload("level_design.gd")
const Maintenance := preload("field_maintenance.gd")

var editor: EditorPlugin
var catalog: RefCounted
var maintenance: RefCounted
var root: Node2D
var region: RegionDefinition
var analyze_requested: Callable
var report: Label
var body: VBoxContainer
var page: OptionButton
var _review: ConfirmationDialog
var _pending: Callable

func _ready() -> void:
	title = "Region Design"
	ok_button_text = "Close"
	var layout := VBoxContainer.new()
	add_child(layout)
	page = OptionButton.new()
	layout.add_child(page)
	for label in ["Region Connections", "Entry & Escape", "Spawn Safety & Diagnostics", "Environment", "Playtest"]:
		page.add_item(label)
	body = VBoxContainer.new()
	layout.add_child(body)
	report = Label.new()
	report.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(report)
	page.item_selected.connect(_refresh)
	_review = ConfirmationDialog.new()
	_review.title = "Review Resource change"
	add_child(_review)
	_review.canceled.connect(func() -> void: _pending = Callable())
	_review.confirmed.connect(func() -> void:
		var action := _pending
		_pending = Callable()
		if action.is_valid():
			action.call())

func show_region(scene: Node2D) -> void:
	root = scene
	region = Design.region_for(root, catalog)
	_refresh(page.selected)
	popup_centered(Vector2i(760, 490))

func _refresh(index: int) -> void:
	for child in body.get_children():
		body.remove_child(child)
		child.queue_free()
	report.text = ""
	if root == null:
		report.text = "Open an AdventureRegion scene."
		return
	_label(body, "%s — %s" % [region.id, region.display_name] if region != null else "RegionDefinition missing, duplicated, or ambiguous.")
	match index:
		0: _connections()
		1: _points()
		2: _diagnostics()
		3: _environment()
		4: _playtest()

func _connections() -> void:
	if region == null:
		return
	var targets := OptionButton.new()
	body.add_child(targets)
	for candidate in catalog.regions:
		if catalog.get_definition(candidate.id) != candidate:
			continue
		targets.add_item("%s [%s]" % [candidate.display_name, candidate.id])
		var index := targets.item_count - 1
		targets.set_item_metadata(index, candidate)
		if candidate == region:
			targets.select(index)
	var exits := OptionButton.new()
	body.add_child(exits)
	var details := _label(body, "")
	var entry := OptionButton.new()
	body.add_child(entry)
	var connect_button := _button(body, "Review link or ENTRY change")
	var remove_button := _button(body, "Review unlink selected region")
	for definition in catalog.definitions.values():
		if definition is SettlementExitDefinition and catalog.get_definition(definition.id) == definition:
			exits.add_item("%s [%s]" % [definition.display_name, definition.id])
			exits.set_item_metadata(exits.item_count - 1, definition)
	var linked := _label(body, "")
	var refresh := func(index: int) -> void:
		if index < 0 or targets.selected < 0:
			connect_button.disabled = true
			remove_button.disabled = true
			return
		var target: RegionDefinition = targets.get_item_metadata(targets.selected)
		var linked_ids := PackedStringArray()
		for option in exits.item_count:
			var candidate: SettlementExitDefinition = exits.get_item_metadata(option)
			if target.id in candidate.connected_region_ids:
				linked_ids.append(String(candidate.id))
		linked.text = "Connected exits: " + (", ".join(linked_ids) if not linked_ids.is_empty() else "none. Link an exit and configure unlocks before play.")
		entry.clear()
		for id in target.entry_point_ids:
			entry.add_item(String(id))
			entry.set_item_metadata(entry.item_count - 1, id)
		var exit: SettlementExitDefinition = exits.get_item_metadata(index)
		details.text = "Regions: %s | Shared ENTRY: %s\nDevelopment locked: %s | Flags: %s | Facilities: %s | Level: %s" % [exit.connected_region_ids, exit.entry_point_id, exit.development_locked, exit.required_flags, exit.required_facility_levels, exit.upgrade_level]
		var plan := Design.connections(exit, target, exit.entry_point_id, target.id in exit.connected_region_ids, catalog, root)
		details.text += "\n" + plan.get("error", "Existing links are consistent.")
		remove_button.disabled = not target.id in exit.connected_region_ids
		connect_button.disabled = entry.item_count == 0
		for item in entry.item_count:
			if entry.get_item_metadata(item) == exit.entry_point_id:
				entry.select(item)
	exits.item_selected.connect(refresh)
	targets.item_selected.connect(func(_index: int) -> void: refresh.call(exits.selected))
	refresh.call(exits.selected)
	for button in [connect_button, remove_button]:
		button.pressed.connect(func() -> void:
			var exit: SettlementExitDefinition = exits.get_item_metadata(exits.selected)
			var add: bool = button == connect_button
			var id: StringName = entry.get_item_metadata(entry.selected) if add else exit.entry_point_id
			var target: RegionDefinition = targets.get_item_metadata(targets.selected)
			var make_plan := Design.connections.bind(exit, target, id, add, catalog, root)
			var plan := make_plan.call() as Dictionary
			_review_fields(exit, plan, make_plan))

func _points() -> void:
	var points: Array[RegionPoint] = []
	RegionPoint.collect(root, points)
	var list := _list()
	for point in points:
		var entry := point.kind == RegionPoint.Kind.ENTRY
		var declared := region != null and point.point_id in (region.entry_point_ids if entry else region.escape_point_ids)
		var references := Design.references(point, region, catalog)
		_add_item(list, "%s %s | %s | %s" % ["ENTRY" if entry else "ESCAPE", point.point_id, point.global_position, root.get_path_to(point)],
			point, "Landing: %s | Declared: %s | References: %s" % [point.requires_landing, declared, references])
	_label(body, "Use Sync Region Points to review declaration changes. Existing saves may reference escape IDs.")

func _diagnostics() -> void:
	var list := _list()
	for issue in RegionDefinition.validate_field_nodes(region, root, catalog):
		_add_item(list, "Error | " + issue, root)
	if region == null:
		_add_item(list, "Error | Missing or ambiguous RegionDefinition", root)
	var results := Design.analyze(root)
	analyze_requested.call(results)
	for item in results:
		_add_item(list, "%s | %s | %s" % [item.severity, root.get_path_to(item.node), item.message], item.node)
	_add_item(list, "Info | Movement reachability and live actor collisions: Not evaluated", root)

func _environment() -> void:
	if region == null:
		return
	_label(body, "Current: " + (region.environment_path if not region.environment_path.is_empty() else "(fallback color)"))
	if environment_plan(region.environment_path).has("error"):
		_label(body, "Current environment file is missing or has the wrong type.")
	var search := LineEdit.new()
	search.placeholder_text = "Search environment presets"
	body.add_child(search)
	var choices := OptionButton.new()
	body.add_child(choices)
	var preview := _label(body, "")
	var show_details := func(_index: int) -> void:
		var path: String = choices.get_item_metadata(choices.selected)
		var env := ResourceLoader.load(path) as EnvironmentDefinition if not path.is_empty() and ResourceLoader.exists(path) else null
		preview.text = "Fallback: %s | Reference size: %s | Layers: %d" % [env.fallback_color, env.reference_size, env.layers.size()] if env != null else "Region fallback color: %s" % region.environment_loading_color
	var refill := func(query: String) -> void:
		choices.clear()
		choices.add_item("(Region fallback)")
		choices.set_item_metadata(0, "")
		var paths: PackedStringArray = catalog.environments.duplicate()
		paths.sort()
		for path in paths:
			if not query.strip_edges().is_empty() and not path.to_lower().contains(query.strip_edges().to_lower()):
				continue
			choices.add_item(path)
			choices.set_item_metadata(choices.item_count - 1, path)
			if path == region.environment_path:
				choices.select(choices.item_count - 1)
		show_details.call(choices.selected)
	choices.item_selected.connect(show_details)
	search.text_changed.connect(refill)
	refill.call("")
	_button(body, "Review environment change").pressed.connect(func() -> void:
		var path: String = choices.get_item_metadata(choices.selected)
		var make_plan := environment_plan.bind(path)
		_review_fields(region, make_plan.call(), make_plan))

static func environment_plan(path: String) -> Dictionary:
	if not path.is_empty() and (not ResourceLoader.exists(path) or not ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) is EnvironmentDefinition):
		return {"error": "Missing or invalid EnvironmentDefinition."}
	return {"environment_path": path}

func _playtest() -> void:
	if region == null:
		return
	var errors := RegionDefinition.validate_field_nodes(region, root, catalog)
	if not errors.is_empty() or not FileAccess.file_exists(root.scene_file_path) or not Maintenance.disk_matches(region):
		_label(body, "Save the scene and fix validation or Resource conflicts before testing.\n" + "\n".join(errors))
		return
	var command := 'python tools/playtest_region.py --godot "%s" --region %s' % [OS.get_executable_path(), region.id]
	_label(body, "Save the scene, then run this isolated runtime probe from the project directory. It uses GameSession and SceneRouter and exits with the result.")
	_label(body, command)
	_button(body, "Copy playtest command").pressed.connect(func() -> void: DisplayServer.clipboard_set(command))

func _review_fields(resource: ContentDefinition, plan: Dictionary, recheck: Callable) -> void:
	if plan.has("error"):
		report.text = plan.error
		return
	if not Maintenance.disk_matches(resource):
		report.text = "Resource differs from disk. Reload and review again."
		return
	var hash := FileAccess.get_sha256(resource.resource_path)
	var lines := PackedStringArray([resource.resource_path])
	for key in plan:
		lines.append("%s: %s → %s" % [key, resource.get(key), plan[key]])
	var scene := root
	_review.dialog_text = "\n".join(lines)
	_pending = func() -> void:
		if not is_instance_valid(scene) or scene != EditorInterface.get_edited_scene_root() or recheck.call() != plan:
			report.text = "Scene or references changed. Review again."
			return
		maintenance.apply_fields(scene, resource, plan, hash, editor.get_undo_redo(), _notice)
	_review.popup_centered(Vector2i(640, 200))

func _notice(message: String) -> void:
	if visible:
		_refresh(page.selected)
	report.text = message

func _list() -> ItemList:
	var list := ItemList.new()
	list.custom_minimum_size.y = 270
	body.add_child(list)
	list.item_selected.connect(func(index: int) -> void:
		var node: Node = list.get_item_metadata(index)
		if is_instance_valid(node) and node.is_inside_tree():
			var selection := EditorInterface.get_selection()
			selection.clear()
			selection.add_node(node)
			EditorInterface.inspect_object(node)
		report.text = list.get_item_tooltip(index))
	return list

func _add_item(list: ItemList, text: String, node: Node, tip := "") -> void:
	list.add_item(text)
	list.set_item_metadata(list.item_count - 1, node)
	list.set_item_tooltip(list.item_count - 1, tip if not tip.is_empty() else text)

func _label(parent: Node, value: String) -> Label:
	var label := Label.new()
	label.text = value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label

func _button(parent: Node, value: String) -> Button:
	var button := Button.new()
	button.text = value
	parent.add_child(button)
	return button
