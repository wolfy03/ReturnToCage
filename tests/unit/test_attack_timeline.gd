extends RefCounted
## Attack timing: AttackDefinition supplies startup/active/recovery, and the
## attack commits exactly once, on entering ATTACK_ACTIVE. No phase duration is
## hard-coded anywhere and there is no separate weapon cooldown.

func run(t: Node) -> void:
	_test_definition_validation(t)
	_test_weapon_validation(t)
	await _test_phase_durations_and_commit(t)
	await _test_large_delta(t)
	await _test_projectile_commits_once(t)

func _valid_definition() -> AttackDefinition:
	var definition := AttackDefinition.new()
	definition.startup_seconds = 0.10
	definition.active_seconds = 0.12
	definition.recovery_seconds = 0.33
	return definition

func _test_definition_validation(t: Node) -> void:
	var definition := _valid_definition()
	t.assert_true(definition.validation_errors().is_empty(), "a positive finite definition validates")
	t.assert_true(is_equal_approx(definition.total_seconds(), 0.55), "total_seconds sums the three phases")
	# A plain Resource, not registry content: it has no content id of its own.
	t.assert_true(not "id" in definition, "AttackDefinition is a plain Resource, not a ContentDefinition")

	for invalid in [NAN, INF, -INF, 0.0, -0.5]:
		for field in ["startup_seconds", "active_seconds", "recovery_seconds"]:
			var broken := _valid_definition()
			broken.set(field, invalid)
			var errors := broken.validation_errors(&"test_weapon")
			t.assert_true(not errors.is_empty(), "%s = %s is rejected" % [field, invalid])
			t.assert_true(String(errors[0]).begins_with("test_weapon: "), "validation errors carry the owner id")

func _test_weapon_validation(t: Node) -> void:
	var weapon := WeaponDefinition.new()
	weapon.id = &"test_timing_weapon"
	weapon.display_name = "Timing test"
	t.assert_true(not weapon.validate_definition(ContentRegistry).is_empty(), "a weapon without an attack definition is invalid")
	weapon.attack_definition = _valid_definition()
	t.assert_true(weapon.validate_definition(ContentRegistry).is_empty(), "a weapon with valid timing passes")
	weapon.attack_definition.active_seconds = 0.0
	t.assert_true(not weapon.validate_definition(ContentRegistry).is_empty(), "invalid nested timing fails the weapon")

	var shipped := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	t.assert_true(shipped != null and shipped.attack_definition != null, "the shipped weapon carries an attack definition")
	t.assert_true(shipped.attack_definition.validation_errors(shipped.id).is_empty(), "the shipped weapon timing is valid")
	t.assert_true(is_equal_approx(shipped.attack_definition.total_seconds(), 0.55), "twig_sword keeps its 0.55s attack cadence")
	t.assert_true(not "attack_cooldown" in shipped, "the legacy weapon cooldown field is gone")

func _spawn_settlement_player(t: Node, layer: Node) -> PlayerActor:
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "attack timeline fixture loads the settlement")
	await t.get_tree().process_frame
	return t.get_tree().get_first_node_in_group(&"player") as PlayerActor

func _test_phase_durations_and_commit(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(GameSession.get_local_peer_id())
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var timing := weapon.attack_definition
	var commits: Array[int] = []
	actor.combat.attacked.connect(func() -> void: commits.append(1))
	# Regeneration runs in the same _process; freeze it so the spend is exact.
	actor.combat.stamina_regen_multiplier = 0.0

	t.assert_true(not "cooldown_remaining" in actor.combat, "the component no longer keeps a separate cooldown")
	t.assert_true(actor.combat.attack(1.0), "the attack request is accepted")
	t.assert_true(is_equal_approx(actor.combat.phase_remaining(), timing.startup_seconds), "the wind-up uses startup_seconds")
	t.assert_equal(commits.size(), 0, "nothing commits during the wind-up")

	# Part-way through the wind-up nothing has happened yet.
	actor.combat._process(timing.startup_seconds * 0.5)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the wind-up is still running one frame early")
	t.assert_equal(actor.combat.hitbox.remaining, 0.0, "the hitbox is not armed before the active phase")
	t.assert_equal(commits.size(), 0, "no commit before the active phase")

	var stamina_before := runtime.combat.stamina
	actor.combat._process(timing.startup_seconds * 0.5)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_ACTIVE, "the wind-up hands over to the active phase")
	t.assert_equal(commits.size(), 1, "entering the active phase commits the attack exactly once")
	t.assert_true(is_equal_approx(actor.combat.hitbox.remaining, timing.active_seconds), "the melee hitbox window is the weapon's active_seconds")
	t.assert_equal(runtime.combat.stamina, stamina_before - weapon.stamina_cost, "stamina is spent on commit")
	t.assert_true(absf(actor.combat.phase_remaining() - timing.active_seconds) < 0.001, "the active phase uses active_seconds")

	var armed_window := actor.combat.hitbox.remaining
	actor.combat._process(timing.active_seconds)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the active phase hands over to recovery")
	t.assert_equal(commits.size(), 1, "the attack does not re-commit when the active phase ends")
	t.assert_true(actor.combat.hitbox.remaining <= armed_window, "the hitbox is not re-armed after the active phase")
	t.assert_true(absf(actor.combat.phase_remaining() - timing.recovery_seconds) < 0.001, "recovery uses recovery_seconds")
	t.assert_equal(runtime.combat.stamina, stamina_before - weapon.stamina_cost, "recovery does not spend stamina again")

	actor.combat._process(timing.recovery_seconds * 0.5)
	t.assert_true(not actor.combat.attack(1.0), "a new attack is refused while recovery is still running")
	actor.combat._process(timing.recovery_seconds * 0.5)
	t.assert_true(actor.combat_action.is_idle(), "the attack ends at idle")
	t.assert_true(actor.combat.phase_remaining() <= 0.0, "no phase time is left after the attack")
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "a new attack is accepted once the cycle completed")
	actor.combat.abort_attack()
	t.assert_true(actor.combat_action.is_idle() and actor.combat.phase_remaining() == 0.0, "abort clears both the state and the timer")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_large_delta(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var timing := weapon.attack_definition
	var commits: Array[int] = []
	var events: Array[Array] = []
	actor.combat.attacked.connect(func() -> void: commits.append(1))
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: events.append([previous, current]))

	# One frame longer than the whole timeline must still walk every phase once.
	t.assert_true(actor.combat.attack(1.0), "the large-delta fixture starts an attack")
	actor.combat._process(timing.total_seconds() + 1.0)
	t.assert_true(actor.combat_action.is_idle(), "an oversized delta still finishes the attack at idle")
	t.assert_equal(commits.size(), 1, "an oversized delta commits the attack exactly once")
	t.assert_equal(events.size(), 4, "an oversized delta still walks all four transitions")
	t.assert_true(actor.combat.phase_remaining() <= 0.0, "no phase time survives an oversized delta")

	# A delta that straddles a phase boundary must carry the surplus forward
	# instead of stretching the attack.
	events.clear()
	commits.clear()
	t.assert_true(actor.combat.attack(1.0), "the overflow fixture starts a second attack")
	actor.combat._process(timing.startup_seconds + timing.active_seconds * 0.5)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_ACTIVE, "a straddling delta lands inside the active phase")
	t.assert_true(absf(actor.combat.phase_remaining() - timing.active_seconds * 0.5) < 0.001, "the surplus is carried into the next phase")
	t.assert_equal(commits.size(), 1, "a straddling delta commits once")
	actor.combat.abort_attack()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_projectile_commits_once(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var weapon := WeaponDefinition.new()
	weapon.id = &"test_timeline_projectile"
	weapon.display_name = "Timeline projectile"
	weapon.attack_mode = WeaponDefinition.AttackMode.PROJECTILE
	weapon.attack_range = 180.0
	weapon.attack_definition = _valid_definition()
	weapon.attack_scene = load("res://tests/fixtures/projectile_attack.tscn") as PackedScene
	t.assert_true(weapon.validate_definition(ContentRegistry).is_empty(), "the projectile fixture is valid content")

	# Drive the strategy through the same timeline the component uses, counting
	# how many projectiles reach the world.
	var parent := actor.get_parent()
	var before := _projectile_count(parent)
	var strategy := ProjectileAttackStrategy.new()
	var context := DamageContext.new(5.0, &"physical", actor, &"player")
	t.assert_true(strategy.execute(weapon, context, actor, actor.combat.hitbox, 1.0), "the projectile strategy executes on commit")
	t.assert_equal(_projectile_count(parent), before + 1, "entering the active phase spawns exactly one projectile")
	for child in parent.get_children():
		if child is ProjectileAttack:
			child.queue_free()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _projectile_count(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is ProjectileAttack:
			count += 1
	return count
