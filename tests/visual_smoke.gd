extends Node
## Engine-driven rendered smoke test, not a manual play session.
var failures: int = 0

func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Visual smoke requires a rendering display")
		get_tree().quit(1)
		return
	var boot: Node = load("res://core/boot.tscn").instantiate()
	add_child(boot)
	await frames(3)
	boot.get_node("%NewGameButton").pressed.emit()
	await frames(8)
	var settlement: Node = boot.get_node("%WorldLayer").get_child(0)
	await wait_for_environment(settlement)
	await capture("settlement")
	var hud: CanvasLayer = get_tree().get_first_node_in_group(&"hud")
	check(hud.load_button.get_global_rect().end.x <= get_viewport().get_visible_rect().end.x, "HUD fits viewport")
	GameSession.set_difficulty(&"survival")
	var context: AdventureContext = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	SceneRouter.go_to_adventure(context)
	await frames(5)
	var player: PlayerActor = get_tree().get_first_node_in_group(&"player")
	var region: Node = boot.get_node("%WorldLayer").get_child(0)
	var ladder: ClimbableArea2D = region.get_node("EmergencyLadder")
	player.health.god_mode = true
	player.global_position = ladder.bottom()
	player.velocity = Vector2.ZERO
	await frames(4)
	Input.action_press(&"move_up")
	await frames(180)
	Input.action_release(&"move_up")
	await frames(10)
	check(player.is_on_floor() and player.global_position.y <= ladder.top().y + 3.0, "rendered climb reaches landing")
	check(hud.save_button.disabled and hud.load_button.disabled, "rendered expedition HUD locked")
	await capture("ladder_top")
	player._on_interact()
	await frames(8)
	check(GameSession.phase == GameSession.Phase.SETTLEMENT, "rendered ladder escape returns to settlement")
	print("VISUAL SMOKE %s: %d failures; images: %s" % ["PASS" if failures == 0 else "FAIL", failures, ProjectSettings.globalize_path("user://validation")])
	get_tree().quit(0 if failures == 0 else 1)

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://validation"))
	var image: Image = get_viewport().get_texture().get_image()
	check(image.save_png("user://validation/%s.png" % name) == OK, "save rendered screenshot")

func check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func frames(count: int) -> void:
	for index in count:
		await get_tree().physics_frame
	await get_tree().process_frame

func wait_for_environment(world: Node, max_frames: int = 300) -> void:
	var presenter := world.get_node_or_null("EnvironmentPresenter") as EnvironmentPresenter
	check(presenter != null, "visible world owns an environment presenter")
	if presenter == null:
		return
	for frame in max_frames:
		if not presenter.is_loading():
			break
		await get_tree().process_frame
	check(not presenter.is_loading() and presenter.layer_count() > 0, "settlement background finishes loading before capture")
