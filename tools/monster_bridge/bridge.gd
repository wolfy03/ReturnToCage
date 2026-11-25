extends Node
## Read-only bridge between the Monster Editor and the game.
##
##   godot --headless --path <project> res://tools/monster_bridge/bridge.tscn -- --request <request.json>
##
## The request names an operation and where to write the result:
##
##   {"protocol": 1, "request_id": "...", "operation": "inspect_monsters" | "import_monster",
##    "monster_id": "...", "result_path": "<absolute path>.json"}
##
## The result repeats protocol, request_id and operation, so the editor can tell
## that the file answers the question it asked. This script writes exactly that
## one file. It never saves a resource and never changes the project.

const Inspector := preload("res://tools/monster_bridge/monster_inspector.gd")
const PROTOCOL := 1
const OPERATIONS := ["inspect_monsters", "import_monster"]

var _request: Dictionary = {}

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2 or args[0] != "--request":
		push_error("monster bridge needs: --request <request.json>")
		get_tree().quit(2)
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(args[1]))
	if not parsed is Dictionary or not parsed.get("result_path") is String or not parsed.get("request_id") is String \
			or not parsed.get("operation") is String:
		push_error("monster bridge request is malformed")
		get_tree().quit(2)
		return
	_request = parsed
	if int(_request.get("protocol", 0)) != PROTOCOL:
		_finish({}, "PROTOCOL_MISMATCH", "bridge speaks protocol %d" % PROTOCOL)
	elif not _request.operation in OPERATIONS:
		_finish({}, "UNKNOWN_OPERATION", String(_request.operation))
	elif _request.operation == "inspect_monsters":
		_finish(_inspect_monsters())
	else:
		_import_monster(String(_request.get("monster_id", "")))

func _inspect_monsters() -> Dictionary:
	var monsters: Array[Dictionary] = []
	for definition in Inspector.enemy_definitions():
		var actor := definition.actor_scene.instantiate() as EnemyAgent if definition.actor_scene != null else null
		var row := {
			"monster_id": String(definition.id),
			"display_name": definition.display_name,
			"definition_path": definition.resource_path,
			"actor_scene_path": definition.actor_scene.resource_path if definition.actor_scene != null else "",
			"agent_script": (actor.get_script() as Script).resource_path if actor != null else "",
			"has_animation_profile": actor != null and not actor.animation_profile_path.is_empty(),
			"loot_table_id": String(definition.loot_table_id),
			"definition_errors": Array(definition.validate_definition(ContentRegistry)),
		}
		if actor != null:
			actor.free()
		monsters.append(row)
	return {"monsters": monsters, "content_errors": Array(ContentRegistry.validate_all())}

func _import_monster(monster_id: String) -> void:
	var definition := ContentRegistry.get_definition(StringName(monster_id)) as EnemyDefinition
	if definition == null:
		_finish({}, "UNKNOWN_MONSTER", monster_id)
		return
	_finish({"monster_id": monster_id, "monster": Inspector.describe(definition), "items": Inspector.item_ids()})

func _finish(data: Dictionary, error_code: String = "", message: String = "") -> void:
	var result := Inspector.environment()
	result["protocol"] = PROTOCOL
	result["request_id"] = _request.get("request_id", "")
	result["operation"] = _request.get("operation", "")
	result["project_path"] = ProjectSettings.globalize_path("res://")
	result["status"] = "PASS" if error_code.is_empty() else "FAIL"
	result["error_code"] = error_code
	result["message"] = message
	result["data"] = data
	var file := FileAccess.open(String(_request.result_path), FileAccess.WRITE)
	if file == null:
		push_error("monster bridge cannot write %s" % _request.result_path)
		get_tree().quit(1)
		return
	file.store_string(JSON.stringify(result, "  "))
	file.close()
	print("MONSTER BRIDGE %s %s" % [result.operation, result.status])
	get_tree().quit(0 if error_code.is_empty() else 3)
