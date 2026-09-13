extends RefCounted
## Attack timing: AttackDefinition supplies startup/active/recovery, and the
## attack commits exactly once, on entering ATTACK_ACTIVE. CombatComponent is the
## only owner of phase duration — the hitbox has no timer of its own and is live
## only while the attack is in ACTIVE. No phase duration is hard-coded anywhere
## and there is no separate weapon cooldown.

func run(t: Node) -> void:
	_test_definition_validation(t)
	_test_weapon_validation(t)
	await _test_phase_durations_and_commit(t)
	await _test_large_delta(t)
	await _test_hitbox_lifecycle_and_abort(t)
	await _test_large_delta_still_hits(t)
	await _test_death_during_active(t)
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
	t.assert_true(not actor.combat.hitbox.active, "the hitbox is not live before the active phase")
	t.assert_equal(commits.size(), 0, "no commit before the active phase")

	var stamina_before := runtime.combat.stamina
	actor.combat._process(timing.startup_seconds * 0.5)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_ACTIVE, "the wind-up hands over to the active phase")
	t.assert_equal(commits.size(), 1, "entering the active phase commits the attack exactly once")
	t.assert_true(actor.combat.hitbox.active, "entering the active phase makes the hitbox live")
	t.assert_true(not "remaining" in actor.combat.hitbox, "the hitbox keeps no duration timer of its own")
	t.assert_equal(runtime.combat.stamina, stamina_before - weapon.stamina_cost, "stamina is spent on commit")
	t.assert_true(absf(actor.combat.phase_remaining() - timing.active_seconds) < 0.001, "the active phase uses active_seconds")

	actor.combat._process(timing.active_seconds)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the active phase hands over to recovery")
	t.assert_equal(commits.size(), 1, "the attack does not re-commit when the active phase ends")
	t.assert_true(not actor.combat.hitbox.active, "leaving the active phase takes the hitbox down")
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
	var timing := _valid_definition()
	var weapon := _register_projectile_weapon(timing)
	var replaced := _equip(weapon.id)
	var parent := actor.get_parent()
	var before := _projectile_count(parent)

	# Drive the real CombatComponent timeline, not the strategy directly.
	t.assert_true(actor.combat.attack(1.0), "the projectile attack request is accepted")
	t.assert_equal(_projectile_count(parent), before, "no projectile spawns when the wind-up starts")
	actor.combat._process(timing.startup_seconds * 0.5)
	t.assert_equal(_projectile_count(parent), before, "no projectile spawns during the wind-up")

	actor.combat._process(timing.startup_seconds * 0.5)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_ACTIVE, "the projectile attack reaches the active phase")
	t.assert_equal(_projectile_count(parent), before + 1, "entering the active phase spawns exactly one projectile")

	actor.combat._process(timing.active_seconds * 0.5)
	t.assert_equal(_projectile_count(parent), before + 1, "no extra projectile spawns during the active phase")
	actor.combat._process(timing.active_seconds)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the projectile attack reaches recovery")
	t.assert_equal(_projectile_count(parent), before + 1, "no extra projectile spawns on entering recovery")
	actor.combat._process(timing.recovery_seconds)
	t.assert_true(actor.combat_action.is_idle(), "the projectile attack ends at idle")
	t.assert_equal(_projectile_count(parent), before + 1, "one whole attack cycle spawns exactly one projectile")

	for child in parent.get_children():
		if child is ProjectileAttack:
			child.queue_free()
	_restore_equipment(replaced, weapon.id)
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

## Registers a throwaway weapon so the real attack path can resolve it, exactly
## like any other equipped item. Removed again by [method _restore_equipment].
func _register_projectile_weapon(timing: AttackDefinition) -> WeaponDefinition:
	var weapon := WeaponDefinition.new()
	weapon.id = &"test_timeline_projectile"
	weapon.display_name = "Timeline projectile"
	weapon.category = ItemDefinition.ItemCategory.WEAPON
	weapon.max_stack = 1
	weapon.max_durability = 10
	weapon.equipment_slot = EquipmentDefinition.EquipmentSlot.MAIN_HAND
	weapon.attack_mode = WeaponDefinition.AttackMode.PROJECTILE
	weapon.attack_range = 180.0
	weapon.stamina_cost = 1.0
	weapon.attack_definition = timing
	weapon.attack_scene = load("res://tests/fixtures/projectile_attack.tscn") as PackedScene
	ContentRegistry._definitions[weapon.id] = weapon
	return weapon

func _equip(item_id: StringName) -> ItemStack:
	var stack := ItemStack.new(item_id, 1)
	stack.durability = 10
	return GameSession.player.equipment.equip(stack)

func _restore_equipment(previous: ItemStack, temporary_id: StringName) -> void:
	GameSession.player.equipment.unequip(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	if previous != null:
		GameSession.player.equipment.equip(previous)
	ContentRegistry._definitions.erase(temporary_id)

## Puts a real enemy in reach of the player's hitbox. Contact invulnerability is
## removed so that a second hit would actually land — only the hitbox's own
## per-attack target list may prevent it.
func _spawn_enemy_in_range(t: Node, actor: PlayerActor) -> EnemyAgent:
	var definition := ContentRegistry.get_definition(&"sewer_beetle") as EnemyDefinition
	var enemy := definition.actor_scene.instantiate() as EnemyAgent
	enemy.setup_enemy(definition, 1, true, actor.world_id)
	actor.get_parent().add_child(enemy)
	await t.get_tree().process_frame
	enemy.set_physics_process(false)
	enemy.global_position = actor.global_position + Vector2(26.0, 0.0)
	enemy.health.invulnerability_seconds = 0.0
	# Deep health pool so repeated fixtures measure damage rather than a death,
	# and no contact invulnerability, so only the hitbox's per-attack target list
	# can stop a second hit.
	enemy.health.max_health = 1000.0
	enemy.health.current_health = 1000.0
	await t.get_tree().physics_frame
	return enemy

func _test_hitbox_lifecycle_and_abort(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(GameSession.get_local_peer_id())
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var timing := weapon.attack_definition
	actor.combat.stamina_regen_multiplier = 0.0

	t.assert_true(not actor.combat.hitbox.active, "the hitbox is inactive while idle")

	# Abort during the wind-up: nothing was ever committed.
	var stamina_before := runtime.combat.stamina
	t.assert_true(actor.combat.attack(1.0), "the abort fixture starts an attack")
	t.assert_true(not actor.combat.hitbox.active, "the hitbox is inactive during the wind-up")
	actor.combat.abort_attack()
	t.assert_true(actor.combat_action.is_idle(), "aborting the wind-up returns to idle")
	t.assert_equal(actor.combat.phase_remaining(), 0.0, "aborting the wind-up clears the phase timer")
	t.assert_true(not actor.combat.hitbox.active, "aborting the wind-up leaves the hitbox inactive")
	t.assert_equal(runtime.combat.stamina, stamina_before, "aborting the wind-up spends no stamina")

	# Abort during the active phase: the hitbox goes down immediately and the
	# stamina already committed is not refunded.
	t.assert_true(actor.combat.attack(1.0), "the abort fixture starts a second attack")
	actor.combat._process(timing.startup_seconds)
	t.assert_true(actor.combat.hitbox.active, "the hitbox is live during the active phase")
	var stamina_committed := runtime.combat.stamina
	t.assert_equal(stamina_committed, stamina_before - weapon.stamina_cost, "the active phase committed the stamina")
	actor.combat.abort_attack()
	t.assert_true(actor.combat_action.is_idle(), "aborting the active phase returns to idle")
	t.assert_true(not actor.combat.hitbox.active, "aborting the active phase takes the hitbox down immediately")
	t.assert_equal(runtime.combat.stamina, stamina_committed, "aborting after commit does not refund stamina")
	actor.combat.abort_attack()
	t.assert_true(actor.combat_action.is_idle() and not actor.combat.hitbox.active, "abort is safe to call again")

	# Abort during recovery, where the hitbox is already down.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the abort fixture starts a third attack")
	actor.combat._process(timing.startup_seconds + timing.active_seconds)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the third attack reaches recovery")
	t.assert_true(not actor.combat.hitbox.active, "the hitbox is inactive during recovery")
	actor.combat.abort_attack()
	t.assert_true(actor.combat_action.is_idle() and not actor.combat.hitbox.active, "aborting recovery is safe")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_large_delta_still_hits(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(GameSession.get_local_peer_id())
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var timing := weapon.attack_definition
	var enemy: EnemyAgent = await _spawn_enemy_in_range(t, actor)
	actor.facing = 1.0
	# Survival updates can reset this during the awaited frames above, so freeze
	# regeneration only once the fixture is fully in place.
	actor.combat.stamina_regen_multiplier = 0.0
	var commits: Array[int] = []
	actor.combat.attacked.connect(func() -> void: commits.append(1))

	# One frame swallows the whole timeline. The attack must still land, exactly
	# once, instead of being committed and then silently disappearing.
	var enemy_health_before := enemy.health.current_health
	var stamina_before := runtime.combat.stamina
	t.assert_true(actor.combat.attack(1.0), "the oversized-delta fixture starts an attack")
	actor.combat._process(timing.total_seconds() + 1.0)
	t.assert_equal(commits.size(), 1, "an oversized delta commits exactly once")
	t.assert_equal(runtime.combat.stamina, stamina_before - weapon.stamina_cost, "an oversized delta spends stamina exactly once")
	t.assert_true(actor.combat_action.is_idle(), "an oversized delta ends the attack at idle")
	t.assert_true(not actor.combat.hitbox.active, "an oversized delta leaves the hitbox inactive")
	var expected_damage := weapon.base_damage + GameSession.player.stats.value(&"attack_power")
	t.assert_true(enemy.health.current_health < enemy_health_before, "an oversized delta still lands the melee hit")
	t.assert_true(is_equal_approx(enemy_health_before - enemy.health.current_health, expected_damage), "the oversized-delta hit lands exactly once")

	# A delta that covers most of startup plus active must behave the same way.
	runtime.combat.stamina = runtime.combat.max_stamina
	var second_before := enemy.health.current_health
	t.assert_true(actor.combat.attack(1.0), "the fixture starts a second oversized attack")
	actor.combat._process(timing.startup_seconds + timing.active_seconds)
	t.assert_equal(commits.size(), 2, "the second oversized delta commits once more")
	t.assert_true(is_equal_approx(second_before - enemy.health.current_health, expected_damage), "the second oversized hit also lands exactly once")
	actor.combat.abort_attack()

	enemy.queue_free()
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_death_during_active(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var timing := weapon.attack_definition
	var enemy: EnemyAgent = await _spawn_enemy_in_range(t, actor)
	actor.facing = 1.0
	actor.combat.stamina_regen_multiplier = 0.0

	t.assert_true(actor.combat.attack(1.0), "the death fixture starts an attack")
	actor.combat._process(timing.startup_seconds)
	t.assert_true(actor.combat.hitbox.active, "the attack is live before the player dies")
	var health_after_hit := enemy.health.current_health

	actor._on_died(DamageContext.new(999.0, &"test", actor, &"environment"))
	t.assert_true(actor.combat_action.is_idle(), "dying mid-attack returns the action axis to idle")
	t.assert_true(not actor.combat.hitbox.active, "dying mid-attack takes the hitbox down immediately")
	t.assert_equal(actor.combat.phase_remaining(), 0.0, "dying mid-attack clears the phase timer")

	# A dead player's hitbox must not keep dealing damage.
	var second_enemy: EnemyAgent = await _spawn_enemy_in_range(t, actor)
	actor.combat.hitbox._sweep_overlaps_now()
	t.assert_equal(second_enemy.health.current_health, second_enemy.health.max_health, "a dead player's hitbox deals no further damage")
	t.assert_equal(enemy.health.current_health, health_after_hit, "the original target takes no extra damage after death")

	enemy.queue_free()
	second_enemy.queue_free()
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
