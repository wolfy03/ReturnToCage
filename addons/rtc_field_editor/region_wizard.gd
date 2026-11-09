@tool
extends ConfirmationDialog

const Scaffold := preload("region_scaffold.tscn")
const Placement := preload("placement.gd")
const Maintenance := preload("field_maintenance.gd")
const PUBLISH_LOCK := "res://.godot/rtc_field_sync/region_publish_lock"
const TEMPLATES := ["Empty Region", "Flat Ground", "Platform Region"]

signal region_created(path: String)

var catalog: RefCounted
var fields: Dictionary[String, Control] = {}
var _message: Label
var _review: ConfirmationDialog

func _ready() -> void:
	title = "New Region"
	get_ok_button().text = "Review files"
	dialog_hide_on_ok = false
	var box := VBoxContainer.new()
	add_child(box)
	_line(box, "id", "Region ID", "new_region")
	_line(box, "name", "Display Name", "New Region")
	_line(box, "description", "Description", "")
	_line(box, "scene", "Scene path", "res://world/adventure/new_region.tscn")
	_line(box, "resource", "RegionDefinition path", "res://data/content/regions/new_region.tres")
	var templates := OptionButton.new()
	for label in TEMPLATES:
		templates.add_item(label)
	_row(box, "template", "Template", templates)
	_spin(box, "danger", "Danger Level", 0, 10, 1)
	_line(box, "environment", "Environment .tres (optional)", "")
	_line(box, "entry", "Initial ENTRY ID", "new_region_entry")
	_line(box, "escape", "Initial ESCAPE ID", "new_region_exit")
	_spin(box, "slots", "Player Spawn Slots", 1, NetworkManager.MAX_PLAYERS, NetworkManager.MAX_PLAYERS)
	(fields.id as LineEdit).text_changed.connect(_suggest_paths)
	_message = Label.new()
	_message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_message)
	_review = ConfirmationDialog.new()
	_review.title = "Review region creation"
	add_child(_review)
	confirmed.connect(_preview)
	_review.confirmed.connect(_create)

func _row(box: VBoxContainer, key: String, label: String, control: Control) -> void:
	var row := HBoxContainer.new()
	box.add_child(row)
	var caption := Label.new()
	caption.text = label
	caption.custom_minimum_size.x = 195
	row.add_child(caption)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	fields[key] = control

func _line(box: VBoxContainer, key: String, label: String, value: String) -> void:
	var line := LineEdit.new()
	line.text = value
	_row(box, key, label, line)

func _spin(box: VBoxContainer, key: String, label: String, minimum: int, maximum: int, value: int) -> void:
	var spin := SpinBox.new()
	spin.min_value = minimum
	spin.max_value = maximum
	spin.value = value
	_row(box, key, label, spin)

func _suggest_paths(id: String) -> void:
	(fields.scene as LineEdit).text = "res://world/adventure/%s.tscn" % id
	(fields.resource as LineEdit).text = "res://data/content/regions/%s.tres" % id
	(fields.entry as LineEdit).text = id + "_entry"
	(fields.escape as LineEdit).text = id + "_exit"

func _values() -> Dictionary:
	var values := {}
	for key in fields:
		var control := fields[key]
		if control is LineEdit:
			values[key] = control.text.strip_edges()
		elif control is SpinBox:
			values[key] = int(control.value)
		else:
			values[key] = control.selected
	return values

func _preview() -> void:
	var values := _values()
	var issue := validate(values, catalog)
	_message.text = issue
	if not issue.is_empty():
		return
	_review.dialog_text = "%s [%s]\n%s • danger %d • %d slots\nENTRY %s • ESCAPE %s\nEnvironment: %s\n\n%s\n%s\n\nConnect a settlement exit and unlock the region separately." % [
		values.name, values.id, TEMPLATES[values.template], values.danger, values.slots, values.entry, values.escape,
		values.environment if not values.environment.is_empty() else "(none)", values.scene, values.resource]
	_review.set_meta("reviewed_values", values)
	_review.popup_centered(Vector2i(650, 280))

func _create() -> void:
	var values: Dictionary = _review.get_meta("reviewed_values")
	if values != _values():
		_message.text = "Values changed. Review again."
		return
	var issue := create_region(values, catalog)
	if not issue.is_empty():
		_message.text = issue
		return
	hide()
	region_created.emit(values.scene)

static func valid_id(value: String) -> bool:
	var regex := RegEx.new()
	regex.compile("^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
	return regex.search(value) != null

static func valid_path(path: String, base: String, extension: String) -> bool:
	if not path.begins_with(base + "/") or path != path.simplify_path() or path.contains("\\") or not path.ends_with("." + extension):
		return false
	var parent := path.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent):
		return false
	var pieces := path.trim_prefix("res://").split("/")
	var directory := "res://"
	for index in pieces.size():
		var piece := pieces[index]
		var stem := piece.get_basename() if index == pieces.size() - 1 else piece
		if not valid_id(stem) or stem in ["con", "nul", "prn", "aux", "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9", "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]:
			return false
		var handle := DirAccess.open(directory)
		if handle == null or handle.is_link(piece):
			return false
		directory = directory.path_join(piece)
	return true

static func occupied(path: String) -> bool:
	return FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path) or ResourceLoader.exists(path)

static func validate(values: Dictionary, catalog: RefCounted) -> String:
	if not valid_id(values.id) or values.name.is_empty():
		return "Use a snake_case region ID and a display name."
	if catalog.definitions.has(StringName(values.id)) or _id_on_disk("res://data/content", StringName(values.id)):
		return "Content ID already exists: %s" % values.id
	if not valid_id(values.entry) or not valid_id(values.escape) or values.entry == values.escape:
		return "ENTRY and ESCAPE need distinct snake_case IDs."
	if not valid_path(values.scene, "res://world/adventure", "tscn") or not valid_path(values.resource, "res://data/content/regions", "tres"):
		return "Use an existing project folder and a snake_case .tscn/.tres filename under the region directories."
	if occupied(values.scene) or occupied(values.resource):
		return "A destination already exists. Choose new paths."
	if values.template == 2 and not catalog.get_definition(&"ladder_default") is ClimbableDefinition:
		return "Platform Region requires the ladder definition."
	if values.template < 0 or values.template >= TEMPLATES.size() or values.slots < 1 or values.slots > NetworkManager.MAX_PLAYERS or values.danger < 0 or values.danger > 10:
		return "Invalid template, slot count, or danger level."
	if not values.environment.is_empty():
		if not values.environment.begins_with("res://") or not ResourceLoader.exists(values.environment) or not ResourceLoader.load(values.environment) is EnvironmentDefinition:
			return "Environment must reference an EnvironmentDefinition."
	return ""

static func _id_on_disk(folder: String, id: StringName) -> bool:
	for entry in ResourceLoader.list_directory(folder):
		var path := folder.path_join(entry)
		if entry.ends_with("/"):
			if _id_on_disk(path.trim_suffix("/"), id):
				return true
		elif entry.get_extension() in ["tres", "res"]:
			var resource := ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as ContentDefinition
			if resource != null and resource.id == id:
				return true
	return false

static func create_region(values: Dictionary, catalog: RefCounted) -> String:
	var issue := validate(values, catalog)
	if not issue.is_empty():
		return issue
	var root := Scaffold.instantiate() as Node2D
	root.name = values.id.to_pascal_case()
	root.scene_file_path = ""
	var region := RegionDefinition.new()
	region.id = StringName(values.id)
	region.display_name = values.name
	region.description = values.description
	region.scene_path = values.scene
	region.danger_level = values.danger
	region.environment_path = values.environment
	region.entry_point_ids = [StringName(values.entry)]
	region.escape_point_ids = [StringName(values.escape)]
	_populate(root, values, catalog)
	var errors := RegionDefinition.validate_field_nodes(region, root, catalog)
	var scene := PackedScene.new()
	var packed := scene.pack(root)
	root.free()
	if packed != OK or not errors.is_empty():
		return "Template validation failed. " + "; ".join(errors)
	return _publish_pair(scene, region, values.scene, values.resource)

static func _populate(root: Node2D, values: Dictionary, catalog: RefCounted) -> void:
	var points := root.get_node("RegionPoints")
	for kind in [RegionPoint.Kind.ENTRY, RegionPoint.Kind.ESCAPE]:
		var point := RegionPoint.new()
		point.name = "Entry" if kind == RegionPoint.Kind.ENTRY else "Escape"
		point.kind = kind
		point.point_id = StringName(values.entry if kind == RegionPoint.Kind.ENTRY else values.escape)
		point.position = Vector2(150 if kind == RegionPoint.Kind.ENTRY else 1050, 520)
		points.add_child(point)
		point.owner = root
	for index in values.slots:
		var slot := PlayerSpawnPoint.new()
		slot.name = "PlayerSpawnPoint%d" % index
		slot.spawn_index = index
		slot.position = Vector2(150 + index * 48, 520)
		root.add_child(slot)
		slot.owner = root
	if values.template == 0:
		return
	_platform(root, Vector2(600, 565), Vector2(1200, 60), false)
	if values.template == 2:
		_platform(root, Vector2(490, 444), Vector2(200, 20), true)
		_platform(root, Vector2(800, 365), Vector2(220, 20), true)
		var ladder := Placement.make_node({"kind": "climb", "id": &"ladder_default"}, root, catalog) as ClimbableArea2D
		if ladder != null:
			ladder.position = Vector2(490, 454)
			ladder.top_marker.position.y = -37
			root.get_node("Climbables").add_child(ladder)
			ladder.owner = root
			for child in ladder.get_children():
				child.owner = root

static func _platform(root: Node2D, center: Vector2, size: Vector2, one_way: bool) -> void:
	var platform := Placement.PLATFORM.instantiate() as FieldPlatform
	platform.position = center
	platform.size = size
	platform.one_way = one_way
	root.get_node("Terrain").add_child(platform, true)
	platform.owner = root

static func _publish_pair(scene: PackedScene, region: RegionDefinition, scene_path: String, resource_path: String, publisher: Callable = _publish_file) -> String:
	if region.scene_path != scene_path:
		return "RegionDefinition does not link to the destination scene."
	var stage_scene := Maintenance.stage_path("tscn")
	var stage_resource := Maintenance.stage_path("tres")
	if stage_scene.is_empty() or stage_resource.is_empty():
		return "Cannot prepare staging files."
	var error := ResourceSaver.save(scene, stage_scene)
	if error == OK:
		error = ResourceSaver.save(region, stage_resource)
	if error != OK:
		Maintenance.discard(stage_scene)
		Maintenance.discard(stage_resource)
		return "Cannot save staged files: %s." % error_string(error)
	var staged_scene := ResourceLoader.load(stage_scene, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
	var staged_region := ResourceLoader.load(stage_resource, "", ResourceLoader.CACHE_MODE_IGNORE) as RegionDefinition
	if staged_scene == null or not staged_scene.can_instantiate() or staged_region == null or staged_region.scene_path != region.scene_path:
		Maintenance.discard(stage_scene)
		Maintenance.discard(stage_resource)
		return "Staged scene or region could not be reloaded."
	for dependency in ResourceLoader.get_dependencies(stage_scene):
		if dependency.contains("res://addons/rtc_field_editor/"):
			Maintenance.discard(stage_scene)
			Maintenance.discard(stage_resource)
			return "Staged scene unexpectedly depends on editor assets."
	var manifest := Maintenance.stage_path("region_pending.json")
	var journal := FileAccess.open(manifest, FileAccess.WRITE)
	if journal == null:
		Maintenance.discard(stage_scene)
		Maintenance.discard(stage_resource)
		return "Cannot write creation recovery record."
	var scene_hash := FileAccess.get_sha256(stage_scene)
	var region_hash := FileAccess.get_sha256(stage_resource)
	journal.store_string(JSON.stringify({"scene": scene_path, "resource": resource_path, "staged_scene": stage_scene,
		"staged_resource": stage_resource, "scene_sha256": scene_hash, "resource_sha256": region_hash}))
	journal.flush()
	var journal_error := journal.get_error()
	journal.close()
	if journal_error != OK:
		Maintenance.discard(manifest)
		Maintenance.discard(stage_scene)
		Maintenance.discard(stage_resource)
		return "Cannot persist creation recovery record."
	var lock := ProjectSettings.globalize_path(PUBLISH_LOCK)
	if DirAccess.make_dir_absolute(lock) != OK:
		Maintenance.discard(manifest)
		Maintenance.discard(stage_scene)
		Maintenance.discard(stage_resource)
		return "Another region publication is active. If interrupted, inspect the recovery records before removing its lock."
	var scene_published := false
	if occupied(scene_path) or occupied(resource_path) or _id_on_disk("res://data/content", region.id):
		error = ERR_ALREADY_EXISTS
	else:
		error = publisher.call(stage_scene, scene_path)
		scene_published = error == OK
		if scene_published:
			error = publisher.call(stage_resource, resource_path)
	if error != OK and scene_published and FileAccess.get_sha256(scene_path) == scene_hash:
		Maintenance.discard(scene_path)
	Maintenance.discard(stage_scene)
	Maintenance.discard(stage_resource)
	DirAccess.remove_absolute(lock)
	if error != OK and scene_published and FileAccess.file_exists(scene_path):
		return "Publish failed; inspect the recovery record at %s." % manifest
	Maintenance.discard(manifest)
	return "" if error == OK else "Region creation failed: %s." % error_string(error)

static func _publish_file(stage: String, destination: String) -> Error:
	if occupied(destination):
		return ERR_ALREADY_EXISTS
	return DirAccess.rename_absolute(ProjectSettings.globalize_path(stage), ProjectSettings.globalize_path(destination))
