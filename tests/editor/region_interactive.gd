extends "res://tests/editor/field_runtime_probe.gd"

var _layer: Node2D

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or args[0] != "--region":
		get_tree().quit(1)
		return
	var region := ContentRegistry.get_definition(StringName(args[1])) as RegionDefinition
	if region == null or region.entry_point_ids.is_empty() or not region.validate_definition(ContentRegistry).is_empty():
		print("INTERACTIVE REGION FAIL: missing or invalid region")
		get_tree().quit(1)
		return
	var context := _create_context(region)
	if context == null:
		print("INTERACTIVE REGION FAIL: " + GameSession.last_message)
		get_tree().quit(1)
		return
	_layer = Node2D.new()
	add_child(_layer)
	SceneRouter.register_world_layer(_layer)
	if not SceneRouter.go_to_adventure(context):
		get_tree().quit(1)
		return
	get_tree().auto_accept_quit = false
	get_tree().root.close_requested.connect(_close)
	var hud := CanvasLayer.new()
	add_child(hud)
	var help := Label.new()
	help.position = Vector2(12, 12)
	help.text = "%s | A/D move | Space jump | W/S climb | E interact | Close window to finish isolated playtest" % region.display_name
	help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(help)
	print("INTERACTIVE REGION READY ", region.id)
	if "--smoke" in args:
		await _input_smoke()

func _close() -> void:
	SceneRouter.clear_presented_world()
	SceneRouter.register_world_layer(null)
	GameSession.start_new_game()
	print("INTERACTIVE REGION CLOSED")
	get_tree().quit()

func _input_smoke() -> void:
	for frame in 12:
		await get_tree().physics_frame
	var scene := _layer.get_child(0)
	var manager := scene.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var actor := manager.get_actor(GameSession.get_local_peer_id())
	if actor == null:
		get_tree().quit(1)
		return
	var before := actor.global_position
	Input.action_press("move_right")
	for frame in 16:
		await get_tree().physics_frame
	Input.action_release("move_right")
	var moved := actor.global_position.x > before.x + 5
	for frame in 12:
		await get_tree().physics_frame
	before = actor.global_position
	var jump := InputEventAction.new()
	jump.action = &"jump"
	jump.pressed = true
	Input.parse_input_event(jump)
	for frame in 6:
		await get_tree().physics_frame
	jump = InputEventAction.new()
	jump.action = &"jump"
	Input.parse_input_event(jump)
	var jumped := actor.global_position.y < before.y - 5
	var climbed := false
	var climbs := scene.find_children("*", "Area2D", true, false)
	for node in climbs:
		if node is ClimbableArea2D and node.definition != null and not node.definition.requires_interaction:
			# Only this fixture positioning is synthetic. Entry and ascent use
			# the actual Area2D overlaps, input actions and movement component.
			actor.global_position = node.global_position
			actor.velocity = Vector2.ZERO
			for frame in 5:
				await get_tree().physics_frame
			before = actor.global_position
			Input.action_press("move_up")
			for frame in 8:
				await get_tree().physics_frame
			climbed = actor.movement.mode == MovementComponent.Mode.CLIMB and actor.global_position.y < before.y - 2
			Input.action_release("move_up")
			break
	print("INTERACTIVE INPUT movement=", moved, " jump=", jumped, " climb=", climbed)
	if not moved or not jumped or not climbed:
		get_tree().quit(1)
		return
	for target in scene.get_children():
		if target is EscapePoint2D:
			actor.movement.exit_climb()
			actor.global_position = target.global_position
			var interact := InputEventAction.new()
			interact.action = &"interact"
			interact.pressed = true
			for frame in 3:
				await get_tree().physics_frame
			Input.parse_input_event(interact)
			for frame in 4:
				await get_tree().physics_frame
			if not GameSession.is_local_player_in_adventure():
				print("INTERACTIVE REGION SMOKE PASS")
				_close()
				return
	get_tree().quit(1)
