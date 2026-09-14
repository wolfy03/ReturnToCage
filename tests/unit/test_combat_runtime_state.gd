extends RefCounted
## Stamina ownership: PlayerRuntimeState.combat is the single canonical source,
## CombatComponent only references it. Behaviour (costs, regen, rejection) must
## match the previous component-owned implementation.

func run(t: Node) -> void:
	_test_model(t)
	await _test_actor_binding_attack_and_regen(t)
	await _test_respawn_and_transition(t)

func _test_model(t: Node) -> void:
	var combat := CombatRuntimeState.new()
	t.assert_equal(combat.stamina, 0.0, "fresh combat runtime starts empty until reset")
	combat.reset(100.0)
	t.assert_true(combat.stamina == 100.0 and combat.max_stamina == 100.0, "reset refills stamina to max")
	t.assert_true(combat.can_spend(8.0) and combat.spend(8.0) and combat.stamina == 92.0, "spend deducts an affordable cost")
	t.assert_true(not combat.can_spend(93.0) and not combat.spend(93.0) and combat.stamina == 92.0, "unaffordable spend is rejected without change")
	t.assert_true(not combat.spend(-1.0) and not combat.spend(NAN) and combat.stamina == 92.0, "invalid spend amounts are rejected")
	combat.regenerate(5.0)
	t.assert_equal(combat.stamina, 97.0, "regenerate adds the computed amount")
	combat.regenerate(50.0)
	t.assert_equal(combat.stamina, 100.0, "regenerate clamps to max_stamina")
	combat.regenerate(-10.0)
	t.assert_equal(combat.stamina, 100.0, "negative regeneration is ignored")
	combat.set_max_stamina(60.0)
	t.assert_true(combat.max_stamina == 60.0 and combat.stamina == 60.0, "lowering max clamps current stamina")
	combat.set_max_stamina(120.0)
	t.assert_true(combat.max_stamina == 120.0 and combat.stamina == 60.0, "raising max does not refill")
	combat.reset(-5.0)
	t.assert_true(combat.max_stamina == 0.0 and combat.stamina == 0.0, "negative max is clamped to zero")
	var runtime := PlayerRuntimeState.new(7)
	t.assert_true(runtime.combat != null, "player runtime state owns a combat runtime state")

func _spawn_settlement_player(t: Node, layer: Node) -> PlayerActor:
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "combat runtime fixture loads the settlement")
	await t.get_tree().process_frame
	return t.get_tree().get_first_node_in_group(&"player") as PlayerActor

func _test_actor_binding_attack_and_regen(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var peer_id := GameSession.get_local_peer_id()
	var runtime := GameSession.get_player_runtime(peer_id)
	var stats := GameSession.player.stats
	t.assert_true(actor != null and runtime != null and actor.combat.combat_runtime == runtime.combat, "CombatComponent references the PlayerRuntimeState combat state")
	t.assert_true(not "stamina" in actor.combat, "CombatComponent no longer owns a stamina field")
	t.assert_equal(runtime.combat.max_stamina, stats.value(&"max_stamina"), "max stamina comes from the max_stamina stat")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "new player starts with full stamina")
	t.assert_equal(actor.combat.current_stamina(), runtime.combat.stamina, "component getter reads the runtime state")

	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	actor.combat.stamina_regen_multiplier = 0.0
	var before := runtime.combat.stamina
	t.assert_true(actor.combat.attack(1.0), "attack succeeds with enough stamina")
	actor.combat._process(CombatTestFixtures.first_step(weapon).startup_seconds)
	actor.combat.stamina_regen_multiplier = 1.0
	t.assert_equal(runtime.combat.stamina, before - weapon.stamina_cost, "committing the attack spends stamina_cost from the runtime state")

	# Clear the in-flight attack so this case actually exercises the stamina
	# rejection rather than the action axis still being busy.
	actor.combat.abort_attack()
	runtime.combat.stamina = weapon.stamina_cost - 0.5
	var low := runtime.combat.stamina
	t.assert_true(not actor.combat.attack(1.0), "attack is rejected without enough stamina")
	t.assert_equal(runtime.combat.stamina, low, "rejected attack leaves stamina unchanged")
	t.assert_equal(actor.combat.phase_remaining(), 0.0, "rejected attack starts no attack timeline")

	actor.combat.abort_attack()
	runtime.combat.stamina = 50.0
	actor.combat.stamina_regen_multiplier = 1.0
	actor.combat._process(1.0)
	t.assert_true(is_equal_approx(runtime.combat.stamina, 50.0 + stats.value(&"stamina_regen")), "one second of regeneration adds stamina_regen")
	actor.combat.stamina_regen_multiplier = 0.5
	actor.combat._process(1.0)
	t.assert_true(is_equal_approx(runtime.combat.stamina, 50.0 + stats.value(&"stamina_regen") * 1.5), "survival multiplier scales regeneration")
	actor.combat.stamina_regen_multiplier = 1.0
	actor.combat._process(100.0)
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "regeneration never exceeds max stamina")
	stats.add_modifier(StatModifier.new(&"test:stamina", &"max_stamina", 20.0, 1.0))
	actor.combat._process(0.0)
	t.assert_equal(runtime.combat.max_stamina, 120.0, "max stamina follows stat modifiers")
	stats.remove_source(&"test:stamina")
	actor.combat._process(0.0)
	t.assert_true(runtime.combat.max_stamina == 100.0 and runtime.combat.stamina == 100.0, "removing the modifier clamps stamina back to the base max")

	var detached := CombatComponent.new()
	t.assert_true(not detached.can_spend_stamina(1.0) and not detached.spend_stamina(1.0) and detached.current_stamina() == 0.0, "unbound component denies stamina use instead of crashing")
	detached._process(1.0)
	detached.free()
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_respawn_and_transition(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var peer_id := GameSession.get_local_peer_id()
	var runtime := GameSession.get_player_runtime(peer_id)
	t.assert_true(actor != null and runtime != null, "respawn fixture spawns a player")
	runtime.combat.stamina = 10.0
	var context: AdventureContext = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(SceneRouter.go_to_adventure(context), "transition fixture enters the sewer")
	await t.get_tree().process_frame
	var adventure_actor := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(adventure_actor != actor and adventure_actor.combat.combat_runtime == runtime.combat, "new world actor binds the same runtime combat state")
	t.assert_true(runtime.combat.stamina >= 10.0 and runtime.combat.stamina < 20.0, "world transition without death keeps current stamina (plus one frame of regen)")

	var life := GameSession.get_player_life_id(peer_id)
	var result: RespawnResult = GameSession.handle_player_death(peer_id, adventure_actor.global_position, life)
	t.assert_true(result.success, "death resolves for the respawn fixture")
	t.assert_true(runtime.combat.stamina < 20.0, "death itself does not refill stamina")
	t.assert_true(SceneRouter.go_to_settlement(), "respawn returns to the settlement")
	await t.get_tree().process_frame
	var respawned := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(respawned != null and GameSession.get_player_life_id(peer_id) != life, "respawn arms a new life")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "respawn refills stamina to max")
	t.assert_true(respawned.combat.combat_runtime == runtime.combat, "respawned actor references the same runtime combat state")
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
