extends RefCounted

const REMOTE_PLAYER_ID := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const PLACEHOLDER_PLAYER_ID := &"player_cccccccccccccccccccccccccccccccc"
const PERSONAL_QUEST_ID := &"_test_save_v4_personal"

func run(t: Node) -> void:
	var local_id := NetworkManager.local_profile_player_id()
	t.assert_true(LocalPlayerProfile.is_valid_player_id(local_id), "Save v4 tests use the persistent local profile identity")
	var definition := _register_personal_quest()
	GameSession.start_new_game()
	var remote := GameSession.attach_player(42, REMOTE_PLAYER_ID)
	remote.set_health(37.0)
	remote.inventory.initialize([ItemStack.new(&"berry", 4)])
	remote.protected_inventory.initialize([_instance(&"leaf_vest", "remote_protected_vest", 45)])
	var personal := GameSession.progression.ensure_personal_progression(REMOTE_PLAYER_ID)
	var quest := QuestState.new(PERSONAL_QUEST_ID)
	quest.initialize(definition)
	quest.progress[0] = 1
	personal.quest_states[PERSONAL_QUEST_ID] = quest
	GameSession.start_quest(&"sewer_supplies", local_id)
	GameSession.detach_player(42)

	var path := "user://save_v4_round_trip_test.json"
	t.assert_true(SaveManager.save_game(path), "Save v4 writes an authoritative offline session")
	var saved := _read_json(path)
	t.assert_equal(saved.get("format_version"), 4.0, "Save v4 writer emits format version 4")
	t.assert_true(saved.has("shared") and saved.has("players") and not saved.has("game_state"), "Save v4 root separates shared and player records")
	t.assert_true(saved["players"].has(String(local_id)) and saved["players"].has(String(REMOTE_PLAYER_ID)), "attached and detached canonical players are saved by player_id")
	t.assert_true(not _contains_key(saved, "peer_id"), "Save v4 persists no transient peer identity")

	GameSession.start_new_game()
	t.assert_true(SaveManager.load_game(path), "Save v4 loads through detached staging")
	t.assert_equal(GameSession.players.size(), 1, "persistent load attaches only the local profile player")
	t.assert_equal(GameSession.persistent_player_count(), 2, "persistent load restores remote records as detached canonical state")
	var restored := GameSession.get_persistent_player(REMOTE_PLAYER_ID)
	t.assert_true(restored != null and restored.health == 37.0, "detached remote health survives Save v4")
	t.assert_equal(restored.inventory.count(&"berry"), 4, "detached remote inventory survives Save v4")
	t.assert_equal(restored.protected_inventory.stacks()[0].instance_id, "remote_protected_vest", "protected inventory survives Save v4")
	t.assert_equal(GameSession.progression.get_personal_progression(REMOTE_PLAYER_ID).quest_states[PERSONAL_QUEST_ID].progress[0], 1, "personal quest state survives Save v4")
	t.assert_true(GameSession.progression.shared_quest_states.has(&"sewer_supplies"), "shared PARTY quest state survives Save v4")

	var legacy := {"format_version": 3, "game_state": GameSession.export_state()}
	var migrated := SaveManager.migrate(legacy)
	t.assert_equal(migrated.get("format_version"), 4, "Save v3 migrates to Save v4")
	t.assert_true(migrated["players"].has(String(local_id)), "v3 migration assigns the local profile identity")
	t.assert_equal(migrated["players"][String(local_id)]["personal_progression"]["quests"], [], "v3 migration invents no personal quest progress")

	var missing_local := GameSession.export_persistent_state()
	missing_local["players"].erase(String(local_id))
	t.assert_true(not GameSession.prepare_persistent_restore(missing_local).fatal_error.is_empty(), "Save v4 without the local profile player is rejected")
	var malformed_id := GameSession.export_persistent_state()
	malformed_id["players"]["invalid"] = malformed_id["players"][String(local_id)].duplicate(true)
	t.assert_true(not GameSession.prepare_persistent_restore(malformed_id).fatal_error.is_empty(), "malformed persistent player ID is rejected")

	var duplicate := GameSession.export_persistent_state()
	var duplicate_stack := _instance(&"leaf_vest", "global_duplicate", 45).to_dict()
	duplicate["players"][String(local_id)]["player_state"]["player_inventory"] = [duplicate_stack]
	duplicate["players"][String(REMOTE_PLAYER_ID)]["player_state"]["protected_inventory"] = [duplicate_stack]
	var duplicate_snapshot := GameSession.prepare_persistent_restore(duplicate)
	t.assert_true(not duplicate_snapshot.fatal_error.is_empty(), "cross-player item instance duplication is a fatal Save v4 error")
	var shared_duplicate := GameSession.export_persistent_state()
	shared_duplicate["shared"]["settlement"]["settlement_storage"] = [duplicate_stack]
	shared_duplicate["players"][String(local_id)]["player_state"]["protected_inventory"] = [duplicate_stack]
	t.assert_true(not GameSession.prepare_persistent_restore(shared_duplicate).fatal_error.is_empty(), "shared/player item instance duplication is a fatal Save v4 error")
	var before := GameSession.export_persistent_state()
	duplicate["format_version"] = 4
	duplicate["saved_at"] = "test"
	_write_json(path, duplicate)
	t.assert_true(not SaveManager.load_game(path), "invalid staged Save v4 does not apply")
	t.assert_equal(GameSession.export_persistent_state(), before, "failed Save v4 load is atomic")

	_test_client_remote_cleanup(t)
	ContentRegistry._definitions.erase(PERSONAL_QUEST_ID)
	_cleanup(path)
	GameSession.start_new_game()

func _test_client_remote_cleanup(t: Node) -> void:
	var placeholder := GameSession.attach_player(77, PLACEHOLDER_PLAYER_ID)
	t.assert_true(placeholder != null, "client cleanup fixture creates a remote placeholder")
	NetworkManager._set_identity(77, PLACEHOLDER_PLAYER_ID)
	NetworkManager.players[77] = NetworkPlayerInfo.new(77, PLACEHOLDER_PLAYER_ID, "Remote", true)
	NetworkManager._client_remove_peer(77)
	t.assert_true(not GameSession.has_player(77), "client peer removal clears the active attachment")
	t.assert_true(not GameSession.has_persistent_player(PLACEHOLDER_PLAYER_ID), "client peer removal discards the remote placeholder registry state")

func _register_personal_quest() -> QuestDefinition:
	var objective := QuestObjectiveDefinition.new()
	objective.type = QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM
	objective.target_id = &"berry"
	objective.required_amount = 2
	var definition := QuestDefinition.new()
	definition.id = PERSONAL_QUEST_ID
	definition.title = "Save v4 personal fixture"
	definition.scope = QuestDefinition.Scope.PERSONAL
	definition.objectives = [objective]
	ContentRegistry._definitions[PERSONAL_QUEST_ID] = definition
	return definition

func _instance(item_id: StringName, instance_id: String, durability: int) -> ItemStack:
	var stack := ItemStack.new(item_id, 1)
	stack.instance_id = instance_id
	stack.durability = durability
	return stack

func _contains_key(value: Variant, key: String) -> bool:
	if value is Dictionary:
		for child_key in value:
			if String(child_key) == key or _contains_key(value[child_key], key):
				return true
	elif value is Array:
		for child in value:
			if _contains_key(child, key):
				return true
	return false

func _read_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	var parser := JSON.new()
	return parser.data if file != null and parser.parse(file.get_as_text()) == OK and parser.data is Dictionary else {}

func _write_json(path: String, data: Dictionary) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(JSON.stringify(data))
	file.close()

func _cleanup(path: String) -> void:
	for suffix in ["", ".tmp", ".bak"]:
		var absolute := ProjectSettings.globalize_path(path + suffix)
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(absolute)
