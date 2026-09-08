extends RefCounted

func run(t: Node) -> void:
	GameSession.start_new_game()
	t.assert_true(GameSession.set_phase(GameSession.Phase.MENU), "settlement can return to menu")
	var before: Dictionary = GameSession.export_state()
	t.assert_true(not GameSession.set_phase(GameSession.Phase.RESPAWNING), "menu cannot enter respawn")
	t.assert_true(not GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ZERO).success, "menu death rejected explicitly")
	t.assert_equal(GameSession.export_state(), before, "invalid menu death does not mutate possessions")
	GameSession.start_new_game()
	var start: ContentDefinition = ContentRegistry.get_definition(GameSession.DEFAULT_START_ID)
	ContentRegistry._definitions.erase(GameSession.DEFAULT_START_ID)
	before = GameSession.export_state()
	t.assert_true(not GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ZERO).success, "missing start content returns failure instead of dereference")
	t.assert_equal(GameSession.export_state(), before, "missing death configuration leaves state unchanged")
	t.assert_equal(GameSession.phase, GameSession.Phase.SETTLEMENT, "failed death does not half-transition phase")
	t.assert_true(not GameSession.player.effects.paused, "failed death does not pause effects")
	ContentRegistry._definitions[GameSession.DEFAULT_START_ID] = start
	var life: int = GameSession.arm_player_life(GameSession.get_local_peer_id())
	GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(not GameSession.set_phase(GameSession.Phase.ADVENTURE), "adventure cannot re-enter adventure")
	var result: RespawnResult = GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ZERO, life)
	t.assert_true(result.success and GameSession.last_death_result == result, "death caches result")
	t.assert_true(GameSession.player.effects.paused, "death pauses active effects")
	t.assert_true(not GameSession.set_phase(GameSession.Phase.ADVENTURE), "respawn cannot enter adventure")
	t.assert_true(GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ONE, life) == result, "duplicate death returns cached result")
	GameSession.complete_respawn(GameSession.get_local_peer_id())
	t.assert_true(not GameSession.player.effects.paused, "completed respawn resumes effects")
	t.assert_true(GameSession.last_death_result == result, "completion retains duplicate guard until actor arm")
	var next_life: int = GameSession.arm_player_life(GameSession.get_local_peer_id())
	t.assert_true(next_life != life and GameSession.last_death_result == null, "new actor advances life and clears result")
	before = GameSession.export_state()
	t.assert_true(not GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ZERO, life).success, "late retired life death ignored")
	t.assert_equal(GameSession.export_state(), before, "late death cannot harm current life")
	var layer := Node.new()
	t.add_child(layer)
	SceneRouter.register_world_layer(layer)
	SceneRouter.go_to_settlement()
	await t.get_tree().process_frame
	var old_actor := layer.get_child(0).get_node("Player") as PlayerActor
	# Hold the old actor outside the tree to simulate an unusually late signal.
	old_actor.get_parent().remove_child(old_actor)
	SceneRouter.go_to_settlement()
	await t.get_tree().process_frame
	var health: float = GameSession.player.health
	old_actor._on_health_changed(0.0, 100.0)
	old_actor._on_died(DamageContext.new())
	t.assert_equal(GameSession.player.health, health, "retired actor health signal cannot trigger a new death")
	t.assert_equal(GameSession.phase, GameSession.Phase.SETTLEMENT, "late actor callback leaves current phase intact")
	old_actor.free()
	GameSession.handle_player_death(GameSession.get_local_peer_id(), Vector2.ZERO)
	SceneRouter.register_world_layer(null)
	t.assert_true(not SceneRouter.go_to_settlement(), "unavailable world reports transition failure")
	t.assert_true(not GameSession.player.effects.paused, "failed scene transition does not retain stale pause flag")
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "respawn retries after world becomes available")
	t.assert_true(GameSession.last_death_result == null and not GameSession.player.effects.paused, "retry arms a clean life")
	GameSession.player.effects.paused = true
	GameSession.start_new_game()
	t.assert_true(not GameSession.player.effects.paused, "new game always resets pause")
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
