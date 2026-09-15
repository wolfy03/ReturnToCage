extends RefCounted
## Stage-5 spatial combat and authoritative knockback regressions. Timing remains
## covered by test_attack_timeline.gd; this suite exercises authored rectangle
## geometry and DamageContext impulses through the real actor damage paths.

func run(t: Node) -> void:
	_test_hitbox_geometry(t)
	_test_impulse_boundaries(t)
	await _test_authoritative_actor_knockback(t)

func _test_hitbox_geometry(t: Node) -> void:
	var hitbox := HitboxComponent.new()
	var collision := CollisionShape2D.new()
	collision.name = "CollisionShape2D"
	hitbox.add_child(collision)
	t.add_child(hitbox)

	t.assert_true(hitbox.configure_geometry(Vector2(52.0, 30.0), Vector2(26.0, 0.0), 1.0), "right-facing twig geometry configures")
	var shape := collision.shape as RectangleShape2D
	t.assert_equal(shape.size, Vector2(52.0, 30.0), "right-facing geometry keeps positive authored size")
	t.assert_equal(hitbox.position, Vector2(26.0, 0.0), "right-facing geometry uses the authored offset")

	t.assert_true(hitbox.configure_geometry(Vector2(52.0, 30.0), Vector2(26.0, 0.0), -1.0), "left-facing twig geometry configures")
	shape = collision.shape as RectangleShape2D
	t.assert_equal(shape.size, Vector2(52.0, 30.0), "left-facing geometry does not negate width")
	t.assert_equal(hitbox.position, Vector2(-26.0, 0.0), "left-facing geometry mirrors only offset x")

	t.assert_true(hitbox.configure_geometry(Vector2(70.0, 20.0), Vector2(31.0, -4.0), 1.0), "custom right-facing geometry configures")
	t.assert_equal((collision.shape as RectangleShape2D).size, Vector2(70.0, 20.0), "custom rectangle size reaches CollisionShape2D")
	t.assert_equal(hitbox.position, Vector2(31.0, -4.0), "custom right-facing y offset stays authored")
	t.assert_true(hitbox.configure_geometry(Vector2(70.0, 20.0), Vector2(31.0, -4.0), -1.0), "custom left-facing geometry configures")
	t.assert_equal(hitbox.position, Vector2(-31.0, -4.0), "custom left-facing geometry mirrors x but not y")
	t.assert_true(not hitbox.configure_geometry(Vector2(NAN, 20.0), Vector2.ZERO, 1.0), "runtime geometry rejects non-finite size")
	t.assert_true(not hitbox.configure_geometry(Vector2(20.0, 20.0), Vector2(INF, 0.0), 1.0), "runtime geometry rejects non-finite offset")

	hitbox.free()

func _test_impulse_boundaries(t: Node) -> void:
	var body := CharacterBody2D.new()
	var movement := MovementComponent.new()
	body.add_child(movement)
	movement.body = body
	body.velocity = Vector2(5.0, -2.0)
	t.assert_true(movement.apply_external_impulse(Vector2(10.0, -3.0)), "player movement accepts a finite impulse")
	t.assert_equal(body.velocity, Vector2(15.0, -5.0), "player external impulse is additive")
	t.assert_true(movement.apply_external_impulse(Vector2.ZERO), "zero player knockback is a valid no-op")
	t.assert_equal(body.velocity, Vector2(15.0, -5.0), "zero player knockback leaves velocity unchanged")
	for invalid_impulse: Vector2 in [Vector2(NAN, 0.0), Vector2(0.0, INF), Vector2(-INF, 0.0)]:
		var before := body.velocity
		t.assert_true(not movement.apply_external_impulse(invalid_impulse), "player movement rejects non-finite impulse %s" % invalid_impulse)
		t.assert_equal(body.velocity, before, "rejected player impulse leaves velocity unchanged")
	body.free()

	var enemy := EnemyAgent.new()
	enemy.velocity = Vector2(-4.0, 6.0)
	t.assert_true(enemy.apply_external_impulse(Vector2(14.0, -9.0)), "enemy accepts a finite impulse")
	t.assert_equal(enemy.velocity, Vector2(10.0, -3.0), "enemy external impulse is additive")
	var enemy_before := enemy.velocity
	t.assert_true(not enemy.apply_external_impulse(Vector2(INF, 0.0)), "enemy rejects a non-finite impulse")
	t.assert_equal(enemy.velocity, enemy_before, "rejected enemy impulse leaves velocity unchanged")
	enemy.free()

func _test_authoritative_actor_knockback(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "knockback fixture loads the settlement")
	await t.get_tree().process_frame
	var actor := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var attack := CombatTestFixtures.first_step(weapon)
	actor.combat.stamina_regen_multiplier = 0.0
	_test_attack_start_snapshot(t, actor, weapon)

	var right_enemy: EnemyAgent = await _spawn_enemy(t, actor, 101, Vector2(26.0, 0.0))
	right_enemy.velocity = Vector2.ZERO
	actor.facing = 1.0
	t.assert_true(actor.combat.attack(actor.facing), "right-facing melee attack starts")
	t.assert_equal(actor.combat._pending_context.knockback, Vector2(120.0, -40.0), "right-facing knockback is snapshotted at attack start")
	actor.combat.physics_tick(attack.startup_seconds)
	t.assert_equal(right_enemy.current_state_id, &"hurt", "melee damage still enters enemy hurt state")
	t.assert_equal(right_enemy.velocity, Vector2(120.0, -40.0), "right-facing melee applies the authored impulse")
	var right_before := right_enemy.global_position
	await t.get_tree().physics_frame
	t.assert_true(right_enemy.global_position.x > right_before.x and right_enemy.global_position.y < right_before.y, "right-facing knockback produces actual enemy displacement")
	actor.combat.abort_attack()
	right_enemy.queue_free()
	await t.get_tree().process_frame

	var left_enemy: EnemyAgent = await _spawn_enemy(t, actor, 102, Vector2(-26.0, 0.0))
	left_enemy.velocity = Vector2.ZERO
	actor.facing = -1.0
	t.assert_true(actor.combat.attack(actor.facing), "left-facing melee attack starts")
	t.assert_equal(actor.combat._pending_context.knockback, Vector2(-120.0, -40.0), "left-facing attack mirrors snapshot x only")
	actor.combat.physics_tick(attack.startup_seconds)
	t.assert_equal(left_enemy.current_state_id, &"hurt", "left-facing melee still enters enemy hurt state")
	t.assert_equal(left_enemy.velocity, Vector2(-120.0, -40.0), "left-facing melee mirrors only the authored impulse x")
	var left_before := left_enemy.global_position
	await t.get_tree().physics_frame
	t.assert_true(left_enemy.global_position.x < left_before.x and left_enemy.global_position.y < left_before.y, "left-facing knockback produces actual enemy displacement")
	actor.combat.abort_attack()
	left_enemy.queue_free()
	await t.get_tree().process_frame

	# Knockback and HURT are independent: a non-reaction impulse preserves the
	# running attack while still moving the player.
	actor.velocity = Vector2.ZERO
	actor.health.invulnerable_remaining = 0.0
	actor.facing = 1.0
	t.assert_true(actor.combat.attack(actor.facing), "player attack starts before incoming knockback")
	var player_health_before := actor.health.current_health
	var impulse_only := DamageContext.new(1.0, &"test", actor, &"hostile", Vector2(100.0, -30.0))
	impulse_only.causes_hurt = false
	t.assert_true(actor.health.receive_damage(impulse_only), "player accepts non-reaction knockback damage")
	t.assert_equal(actor.velocity, Vector2(100.0, -30.0), "player receives the exact additive DamageContext impulse")
	t.assert_true(actor.health.current_health < player_health_before, "player knockback damage still reduces HP")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "causes_hurt=false keeps attack startup independent from knockback")
	var player_before := actor.global_position
	actor.input.move_axis = 0.0
	actor.input.vertical_axis = 0.0
	actor.movement.physics_tick(0.016)
	t.assert_true(actor.global_position.x > player_before.x and actor.global_position.y < player_before.y, "player knockback produces actual displacement")
	actor.combat.physics_tick(attack.total_seconds())
	t.assert_true(actor.combat_action.is_idle(), "attack timeline completes normally after non-reaction knockback")

	actor.health.invulnerable_remaining = 0.0
	actor.velocity = Vector2(12.0, -7.0)
	var zero_velocity_before := actor.velocity
	var zero_health_before := actor.health.current_health
	var zero_without_reaction := DamageContext.new(1.0, &"test", actor, &"hostile", Vector2.ZERO)
	zero_without_reaction.causes_hurt = false
	t.assert_true(actor.health.receive_damage(zero_without_reaction), "zero-knockback damage is accepted")
	t.assert_true(actor.health.current_health < zero_health_before, "zero-knockback damage reduces HP")
	t.assert_equal(actor.velocity, zero_velocity_before, "zero-knockback damage does not change velocity")

	var climbable := ClimbableArea2D.new()
	climbable.definition = ClimbableDefinition.new()
	climbable.definition.drop_on_damage = false
	actor.movement.climb_area = climbable
	actor.movement.mode = MovementComponent.Mode.CLIMB
	actor.velocity = Vector2.ZERO
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile", Vector2.ZERO)), "climbing player accepts zero-knockback damage")
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.CLIMB, "zero knockback respects drop_on_damage false")
	t.assert_equal(actor.velocity, Vector2.ZERO, "zero knockback leaves climbing velocity unchanged")
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile", Vector2(100.0, -30.0))), "climbing player accepts knockback damage")
	t.assert_true(actor.movement.mode != MovementComponent.Mode.CLIMB, "non-zero knockback exits climb even when ordinary damage would not")
	t.assert_equal(actor.velocity, Vector2(100.0, -30.0), "climb exit happens before the impulse is applied")
	climbable.free()

	actor.velocity = Vector2.ZERO
	actor.simulation_enabled = false
	actor._on_damaged(DamageContext.new(1.0, &"test", actor, &"hostile", Vector2(100.0, -30.0)))
	t.assert_equal(actor.velocity, Vector2.ZERO, "presentation actors do not apply knockback locally")
	actor.simulation_enabled = true

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_attack_start_snapshot(t: Node, actor: PlayerActor, source_weapon: WeaponDefinition) -> void:
	var weapon := source_weapon.duplicate(true) as WeaponDefinition
	weapon.id = &"test_knockback_snapshot"
	ContentRegistry._definitions[weapon.id] = weapon
	var stack := ItemStack.new(weapon.id, 1)
	stack.durability = weapon.max_durability
	var previous := actor.player_state().equipment.equip(stack)

	t.assert_true(actor.combat.attack(1.0), "snapshot fixture starts an attack")
	var expected := actor.combat._pending_context.knockback
	CombatTestFixtures.first_step(weapon).knockback = Vector2.ZERO
	t.assert_equal(actor.combat._pending_context.knockback, expected, "an in-flight attack keeps its start-time knockback snapshot")
	actor.combat.abort_attack()
	actor.player_state().equipment.unequip(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	if previous != null:
		actor.player_state().equipment.equip(previous)
	ContentRegistry._definitions.erase(weapon.id)

func _spawn_enemy(t: Node, actor: PlayerActor, entity_id: int, offset: Vector2) -> EnemyAgent:
	var definition := ContentRegistry.get_definition(&"sewer_beetle") as EnemyDefinition
	var enemy := definition.actor_scene.instantiate() as EnemyAgent
	enemy.setup_enemy(definition, entity_id, true, actor.world_id)
	actor.get_parent().add_child(enemy)
	await t.get_tree().process_frame
	enemy.global_position = actor.global_position + offset
	enemy.health.max_health = 1000.0
	enemy.health.current_health = 1000.0
	enemy.health.invulnerability_seconds = 0.0
	await t.get_tree().physics_frame
	return enemy
