extends Node
## Narrow shutdown reproduction, deliberately independent of Field Editor code.

func _ready() -> void:
	_run.call_deferred()

func _run() -> void:
	var mode := "physics"
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--native-probe="):
			mode = argument.get_slice("=", 1)
	if mode not in ["physics", "player"]:
		get_tree().quit(1)
		return
	var world := Node2D.new()
	add_child(world)
	var body := StaticBody2D.new()
	var collision := CollisionShape2D.new()
	var rectangle := RectangleShape2D.new()
	rectangle.size = Vector2(500, 40)
	collision.shape = rectangle
	body.add_child(collision)
	body.position = Vector2(100, 160)
	world.add_child(body)
	var actor: PlayerActor
	if mode == "player":
		GameSession.start_new_game()
		actor = (load("res://gameplay/actors/player/player.tscn") as PackedScene).instantiate()
		actor.setup_player(GameSession.get_local_peer_id(), true, false)
		actor.position = Vector2(100, 100)
		world.add_child(actor)
		actor.input.configure_input(false, true)
	for frame in 5:
		await get_tree().physics_frame
	if actor != null:
		actor.movement.exit_climb()
		actor.queue_free()
		await get_tree().process_frame
		actor = null
	world.queue_free()
	await get_tree().physics_frame
	await get_tree().process_frame
	print("NATIVE LIFECYCLE PASS mode=", mode)
	get_tree().quit()
