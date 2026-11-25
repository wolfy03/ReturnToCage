extends Node
## Read-only probe for the Monster Editor data contract.
##
## Dumps what the game actually ships for every EnemyDefinition - stats, actor
## scene structure, state timings, collision shapes, animation profile and loot -
## and runs each actor for a moment as a headless authority. Python compares the
## result with the .rtcmonster example documents, so the contract is checked
## against real Godot resources instead of a mock.
##
## It writes exactly one file: the JSON path given after `--`. It never saves a
## resource and never touches user:// state.
##
##   godot --headless --path . res://tools/monster_bridge/contract_probe.tscn -- <output.json>

const Inspector := preload("res://tools/monster_bridge/monster_inspector.gd")
const PROTOCOL := 1
const RUN_FRAMES := 150

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 1 or not args[0].ends_with(".json"):
		push_error("contract_probe needs one argument: the output .json path")
		get_tree().quit(2)
		return
	var result := Inspector.environment()
	result["protocol"] = PROTOCOL
	result["content_errors"] = Array(ContentRegistry.validate_all())
	result["items"] = Inspector.item_ids()
	result["enemies"] = {}
	var definitions := Inspector.enemy_definitions()
	for definition in definitions:
		var entry := Inspector.describe(definition)
		entry["run"] = await _run(definition)
		result.enemies[String(definition.id)] = entry
	var file := FileAccess.open(args[0], FileAccess.WRITE)
	if file == null:
		push_error("contract_probe cannot write %s" % args[0])
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("MONSTER CONTRACT PROBE PASS (%d enemies)" % definitions.size())
	get_tree().quit(0)

## Runs the real actor scene as an authority with no player and no floor: it must
## instantiate, run its state machine and stay free of presentation nodes.
func _run(definition: EnemyDefinition) -> Dictionary:
	var report := {"instantiated": false, "states_seen": [], "presenter_in_server_mode": false,
		"presenter_in_presentation_mode": false, "max_health": 0.0}
	if definition.actor_scene == null:
		return report
	var holder := Node2D.new()
	add_child(holder)
	for presentation in [false, true]:
		var actor := definition.actor_scene.instantiate() as EnemyAgent
		if actor == null:
			break
		actor.setup_enemy(definition, 1, true, &"", presentation)
		if not presentation:
			actor.state_changed.connect(func(id: StringName) -> void: report.states_seen.append(String(id)))
		holder.add_child(actor)
		report.instantiated = true
		if presentation:
			await get_tree().process_frame
			report.presenter_in_presentation_mode = actor.animation_presenter != null
		else:
			for frame in RUN_FRAMES:
				await get_tree().physics_frame
			report.presenter_in_server_mode = actor.animation_presenter != null
			report.max_health = actor.health.max_health
		holder.remove_child(actor)
		actor.free()
	remove_child(holder)
	holder.free()
	return report
