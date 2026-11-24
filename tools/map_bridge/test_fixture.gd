extends Node
## Runs exclusively in cloned integration test projects.
const ShutdownGuard := preload("res://tools/map_bridge/shutdown_guard.gd")
const Analysis := preload("res://addons/rtc_field_editor/traversal_analysis.gd")
const FIXTURE_SCENE := "res://world/adventure/sewer_region.tscn"
const FIXTURE_REGION := "res://data/content/regions/sewer_region.tres"
const TEXTURE := "res://assets/backgrounds/clouds_far_atlas_2048x1152.png"

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or args[0] not in ["decorate", "traversal"]:
		get_tree().quit(2)
		return
	var source := load(FIXTURE_SCENE) as PackedScene
	var field := source.instantiate() as Node2D
	var ok: bool
	if args[0] == "traversal":
		ok = _prepare_traversal(source, field)
	else:
		ok = _decorate(field)
	ShutdownGuard.retain_scripts()
	field.free()
	get_tree().quit(0 if ok else 1)

func _prepare_traversal(source: PackedScene, field: Node2D) -> bool:
	var region := ContentRegistry.get_definition(&"sewer_region") as RegionDefinition
	var token := "04b3c107b96e4759b76dd552e737c4ab"
	var folder := "res://.godot/rtc_traversal/" + token
	if DirAccess.make_dir_recursive_absolute(folder) != OK:
		return false
	var scene := folder.path_join("scene.tscn")
	if ResourceSaver.save(source, scene) != OK:
		return false
	var file := FileAccess.open(folder.path_join("request.json"), FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"token": token, "region": String(region.id), "scene": scene,
		"output": folder.path_join("result.json"), "fingerprint": Analysis.fingerprint(field, region),
		"fps": Analysis.model().physics_fps}))
	file.close()
	return true

func _decorate(field: Node2D) -> bool:
	var visuals := Node2D.new()
	visuals.name = "Decorations"
	visuals.position = Vector2(120, -30)
	visuals.rotation_degrees = 15
	field.add_child(visuals)
	visuals.owner = field
	var group := Node2D.new()
	group.name = "Nested"
	group.position = Vector2(100, 100)
	group.rotation_degrees = 20
	visuals.add_child(group)
	group.owner = field
	for node_name in ["Editable", "Reflected"]:
		var decoration := FieldDecoration.new()
		decoration.name = node_name
		decoration.position = Vector2(160, 240)
		decoration.scale = Vector2(-0.1 if node_name == "Reflected" else 0.1, 0.2)
		decoration.asset_path = TEXTURE
		group.add_child(decoration)
		decoration.owner = field
	var scene := PackedScene.new()
	if scene.pack(field) != OK or ResourceSaver.save(scene, FIXTURE_SCENE) != OK:
		return false
	return ResourceSaver.set_uid(FIXTURE_SCENE, ResourceUID.create_id()) == OK \
		and ResourceSaver.set_uid(FIXTURE_REGION, ResourceUID.create_id()) == OK
