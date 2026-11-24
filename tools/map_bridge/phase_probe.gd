extends "res://tools/map_bridge/bridge.gd"
## Test-only staging probe. Production requests always use bridge.tscn.

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 3 or args[0] != "--phase" or args[1] not in ["load", "inventory", "contract", "collision", "session"]:
		get_tree().quit(2)
		return
	var phase := args[1]
	request = JSON.parse_string(FileAccess.get_file_as_string(args[2]))
	print("RTC_BRIDGE VALIDATION_STARTED ", phase)
	if phase == "session":
		GameSession.start_new_game()
		print("RTC_BRIDGE SESSION_INITIALIZED")
		_finish({})
		return
	region = load(request.region_path) as RegionDefinition
	if region == null:
		_finish({}, "RESOURCE_MISSING: probe region")
		return
	scene = ResourceLoader.load(region.scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	if scene == null or not scene.can_instantiate():
		_finish({}, "RESOURCE_MISSING: probe scene")
		return
	scene_root = scene.instantiate() as Node2D
	if scene_root == null:
		_finish({}, "RESOURCE_MISSING: probe scene instance")
		return
	print("RTC_BRIDGE SCENE_LOADED")
	if phase == "load":
		_finish({})
		return
	if phase == "collision":
		# The production collision probe includes activation of the authority scene.
		# Session alone has a separate phase. No inventory or semantic comparison runs here.
		var issue := await _runtime_collision()
		_finish({}, issue)
		return
	var data := Contract.inventory(scene_root, String(region.id))
	if data.has("error"):
		_finish({}, "INVALID_DOCUMENT: " + data.error)
		return
	print("RTC_BRIDGE INVENTORY_PASS")
	if phase == "inventory":
		_finish(data)
		return
	var state := _summary(data, Contract.connections(scene, scene_root))
	if not _same_json(state.scene_state, request.expected.scene_state):
		_finish({}, "EXPORT_FAILED: probe contract differs")
		return
	print("RTC_BRIDGE CONTRACT_PASS")
	_finish(state)
