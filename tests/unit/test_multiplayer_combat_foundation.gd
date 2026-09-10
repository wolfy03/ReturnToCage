extends RefCounted

const PLAYER_TWO: StringName = &"player_22222222222222222222222222222222"
const PLAYER_THREE: StringName = &"player_33333333333333333333333333333333"

func run(t: Node) -> void:
	var command := PlayerAttackCommand.new(4)
	t.assert_true(command.is_valid_after(3), "new attack sequence is accepted")
	t.assert_true(not command.is_valid_after(4), "duplicate attack sequence is rejected")
	t.assert_true(not PlayerAttackCommand.new(-1).is_valid_after(-1), "malformed attack sequence is rejected")
	t.assert_true(not NetworkProtocol.valid_command_sender(7, 8, true), "attack sender cannot spoof another player actor")

	var registry := NetworkEntityRegistry.new()
	var first := Node.new()
	var second := Node.new()
	var first_id := registry.register_entity(first)
	var second_id := registry.register_entity(second)
	t.assert_true(first_id > 0 and second_id > first_id, "network entity ids are server-issued and monotonic")
	t.assert_true(registry.get_entity(first_id) == first, "entity registry resolves stable identity")
	registry.unregister_entity(first_id)
	t.assert_true(not registry.has_entity(first_id), "entity unregister removes identity")
	first.free()
	second.free()
	registry.free()

	var manager := EnemySpawnManager.new()
	var spawn_registry := NetworkEntityRegistry.new()
	manager._registry = spawn_registry
	var production := ContentRegistry.get_definition(&"sewer_beetle") as EnemyDefinition
	var alternate := EnemyDefinition.new()
	alternate.id = &"test_alternate_enemy"
	alternate.display_name = "Alternate Enemy"
	alternate.actor_scene = preload("res://tests/fixtures/alternate_enemy.tscn")
	var actor_a := manager._instantiate_enemy_actor(production)
	var actor_b := manager._instantiate_enemy_actor(alternate)
	t.assert_true(actor_a != null and not actor_a.has_node("FixtureMarker"), "enemy definition A resolves its own actor scene")
	t.assert_true(actor_b != null and actor_b.has_node("FixtureMarker"), "enemy definition B resolves a different actor scene")
	actor_a.free()
	actor_b.free()
	var missing_scene := EnemyDefinition.new()
	missing_scene.id = &"missing_scene_enemy"
	missing_scene.display_name = "Missing Scene"
	t.assert_true(not missing_scene.validate_definition(ContentRegistry).is_empty(), "enemy definition rejects a missing actor scene")
	t.assert_equal(manager._spawn_definition(missing_scene, Vector2.ZERO, false), 0, "missing actor scene cannot spawn")
	var invalid_scene := EnemyDefinition.new()
	invalid_scene.id = &"invalid_scene_enemy"
	invalid_scene.display_name = "Invalid Scene"
	invalid_scene.actor_scene = preload("res://tests/fixtures/invalid_enemy_actor.tscn")
	t.assert_true(not invalid_scene.validate_definition(ContentRegistry).is_empty(), "enemy definition rejects a non-EnemyAgent scene root")
	t.assert_equal(manager._spawn_definition(invalid_scene, Vector2.ZERO, false), 0, "invalid actor scene cannot spawn")
	t.assert_equal(manager.spawn_enemy(&"missing_enemy", Vector2.ZERO, false), 0, "unknown enemy id cannot spawn")
	t.assert_equal(spawn_registry.entity_count(), 0, "invalid enemy definitions do not contaminate the entity registry")
	var marker := Node.new()
	t.assert_equal(spawn_registry.register_entity(marker), 1, "invalid enemy definitions do not consume entity ids")
	marker.free()
	manager.free()
	spawn_registry.free()
	for definition in ContentRegistry.all_definitions():
		if definition is EnemyDefinition:
			var enemy_root := (definition as EnemyDefinition).actor_scene.instantiate()
			t.assert_true(enemy_root is EnemyAgent, "registered enemy actor scene root inherits EnemyAgent: %s" % definition.id)
			enemy_root.free()

	var valid_enemy := {
		"entity_id": 9, "enemy_id": "sewer_beetle", "position": Vector2.ONE,
		"velocity": Vector2.ZERO, "facing": 1.0, "health": 12.0,
		"max_health": 24.0, "state": EnemyRuntimeSnapshot.State.MOVING, "sequence": 2,
	}
	t.assert_true(EnemyRuntimeSnapshot.from_payload(valid_enemy).error_message.is_empty(), "validated enemy snapshot is accepted")
	valid_enemy["health"] = NAN
	t.assert_true(not EnemyRuntimeSnapshot.from_payload(valid_enemy).error_message.is_empty(), "NaN enemy health is rejected")
	valid_enemy["health"] = 12.0
	valid_enemy["enemy_id"] = "missing_enemy"
	t.assert_true(not EnemyRuntimeSnapshot.from_payload(valid_enemy).error_message.is_empty(), "unknown enemy snapshot is rejected")

	var loot_payload := {"entity_id": 5, "position": Vector2.ZERO, "stack": ItemStack.new(&"rusty_scrap", 2).to_dict()}
	t.assert_true(LootEntitySnapshot.from_payload(loot_payload).error_message.is_empty(), "validated loot snapshot is accepted")
	loot_payload["entity_id"] = -1
	t.assert_true(not LootEntitySnapshot.from_payload(loot_payload).error_message.is_empty(), "negative loot entity id is rejected")
	loot_payload["entity_id"] = 5
	loot_payload["stack"] = ItemStack.new(&"missing_item", 2).to_dict()
	t.assert_true(not LootEntitySnapshot.from_payload(loot_payload).error_message.is_empty(), "unknown loot item is rejected")

	var table := ContentRegistry.get_definition(&"sewer_beetle_loot") as LootTableDefinition
	var rng_a := RandomNumberGenerator.new(); rng_a.seed = 1234
	var rng_b := RandomNumberGenerator.new(); rng_b.seed = 1234
	var roll_a := LootRollService.roll(table, Callable(ContentRegistry, "get_item"), 1.0, rng_a)
	var roll_b := LootRollService.roll(table, Callable(ContentRegistry, "get_item"), 1.0, rng_b)
	t.assert_true(roll_a.size() == 1 and roll_b.size() == 1, "server loot table produces one validated roll")
	t.assert_equal(roll_a[0].to_dict(), roll_b[0].to_dict(), "server loot roll is deterministic for a supplied seed")

	var session := AdventureSession.new(AdventureContext.new(), Callable(ContentRegistry, "get_item"))
	var player_a := session.get_player_adventure(1)
	var player_b := session.register_player(2, Callable(ContentRegistry, "get_item"))
	player_b.unsecured_loot.add_item(&"rusty_scrap", 1)
	t.assert_equal(player_a.unsecured_loot.count(&"rusty_scrap"), 0, "personal adventure loot does not leak to another peer")
	t.assert_equal(player_b.unsecured_loot.count(&"rusty_scrap"), 1, "personal adventure loot belongs to the collecting peer")
	player_a.unsecured_loot.add_item(&"rusty_scrap", 5)
	player_b.unsecured_loot.add_item(&"rusty_scrap", 5)
	var adventure := AdventureState.new()
	adventure.active_session = session
	var player_state := PlayerState.new(Callable(ContentRegistry, "get_item"))
	var start := GameSession.get_start_definition()
	player_state.reset(start, ContentRegistry)
	var settlement := SettlementState.new(Callable(ContentRegistry, "get_item"))
	settlement.reset(start, ContentRegistry)
	DeathResolutionService.resolve(player_state, settlement, adventure, ContentRegistry.get_definition(&"normal") as DifficultyDefinition,
		Vector2.ZERO, start.respawn_policy, start.survival_config, "test", Callable(ContentRegistry, "get_item"), false, player_b, 2)
	t.assert_equal(player_a.unsecured_loot.count(&"rusty_scrap"), 5, "one player death leaves another player's unsecured loot unchanged")
	t.assert_true(player_b.unsecured_loot.count(&"rusty_scrap") < 6, "death loss policy applies only to the dead player's unsecured loot")

	# Disconnect is an explicit forfeiture policy until reconnect persistence exists.
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var persistent_player_b := GameSession.attach_player(2, PLAYER_TWO)
	GameSession.attach_player(3, PLAYER_THREE)
	var live_context := GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	t.assert_true(live_context != null, "disconnect policy fixture starts an adventure")
	var live_session := GameSession.adventure.active_session
	var live_a := live_session.get_player_adventure(1)
	var live_b := live_session.get_player_adventure(2)
	var live_c := live_session.get_player_adventure(3)
	live_a.unsecured_loot.add_item(&"rusty_scrap", 1)
	live_b.unsecured_loot.add_item(&"rusty_scrap", 5)
	live_c.unsecured_loot.add_item(&"rusty_scrap", 2)
	var storage_before_disconnect := GameSession.settlement.storage.count(&"rusty_scrap")
	GameSession.detach_player(2)
	t.assert_true(live_session.get_player_adventure(2) == null, "disconnect discards only that peer's PlayerAdventureState")
	t.assert_equal(live_a.unsecured_loot.count(&"rusty_scrap"), 1, "disconnect preserves peer A unsecured loot")
	t.assert_equal(live_c.unsecured_loot.count(&"rusty_scrap"), 2, "disconnect preserves peer C unsecured loot")
	t.assert_equal(GameSession.settlement.storage.count(&"rusty_scrap"), storage_before_disconnect, "disconnect does not secure forfeited loot into settlement storage")
	var reattached_player_b := GameSession.attach_player(2, PLAYER_TWO)
	t.assert_true(reattached_player_b == persistent_player_b, "adventure rejoin reuses PlayerState while recreating expedition participation")
	var rejoined_b := live_session.get_player_adventure(2)
	t.assert_true(rejoined_b != null and rejoined_b != live_b, "rejoin creates a fresh PlayerAdventureState")
	t.assert_equal(rejoined_b.unsecured_loot.count(&"rusty_scrap"), 0, "rejoin does not restore forfeited unsecured loot")
	GameSession.detach_player(2)
	GameSession.detach_player(3)
	GameSession.adventure.active_session = null
	GameSession.set_phase(GameSession.Phase.SETTLEMENT)
