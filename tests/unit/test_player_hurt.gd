extends RefCounted
## Stage-6 player hit-stun regressions. HURT is a scene-local combat action;
## locomotion and DamageContext knockback remain independent systems.

func run(t: Node) -> void:
	_test_component_lifecycle_and_refresh(t)
	await _test_attack_interruptions_and_controls(t)
	await _test_world_transition(t)
	await _test_lethal_without_hurt(t)
	await _test_death_and_respawn(t)

func _test_component_lifecycle_and_refresh(t: Node) -> void:
	var action := CombatActionController.new()
	var combat := CombatComponent.new()
	var movement := MovementComponent.new()
	var hurt := PlayerHurtComponent.new()
	combat.action = action
	hurt.configure(null, action, combat, movement)
	var events: Array[Array] = []
	action.state_changed.connect(func(previous: int, current: int) -> void: events.append([previous, current]))

	t.assert_true(not hurt.is_active() and hurt.remaining == 0.0, "a fresh hurt component is inactive")
	t.assert_true(hurt.begin_hurt(), "begin_hurt accepts IDLE")
	t.assert_true(action.is_hurt() and hurt.is_active(), "begin_hurt enters the HURT combat action")
	t.assert_equal(hurt.remaining, hurt.duration_seconds, "begin_hurt starts the authored duration")
	t.assert_true(movement.controls_locked, "begin_hurt locks player controls")
	hurt.physics_tick(hurt.duration_seconds - 0.01)
	t.assert_true(hurt.is_active() and hurt.remaining > 0.0, "HURT remains active just before its duration")
	var event_count := events.size()
	t.assert_true(hurt.begin_hurt(), "a valid re-hit refreshes HURT")
	t.assert_equal(events.size(), event_count, "HURT refresh emits no HURT-to-HURT state signal")
	t.assert_equal(hurt.remaining, hurt.duration_seconds, "a re-hit refreshes the full duration")
	t.assert_true(movement.controls_locked, "controls remain locked after refresh")
	hurt.physics_tick(hurt.duration_seconds + 0.01)
	t.assert_true(not hurt.is_active() and action.is_idle(), "duration completion transitions HURT to IDLE")
	t.assert_true(not movement.controls_locked and hurt.remaining == 0.0, "duration completion clears timer and control lock")

	hurt.begin_hurt()
	hurt.reset()
	t.assert_true(not hurt.is_active() and action.is_idle(), "reset clears HURT")
	t.assert_true(not movement.controls_locked and hurt.remaining == 0.0, "reset clears timer and controls")

	hurt.free()
	movement.free()
	combat.free()
	action.free()

func _test_attack_interruptions_and_controls(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var attack := weapon.attack_definition
	actor.combat.stamina_regen_multiplier = 0.0

	# STARTUP: no commit, no stamina spend, and one direct ATTACK_STARTUP -> HURT.
	var transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: transitions.append([previous, current]))
	var startup_stamina := runtime.combat.stamina
	t.assert_true(actor.combat.attack(1.0), "startup interruption fixture begins an attack")
	actor.velocity = Vector2.ZERO
	t.assert_true(_damage(actor, Vector2.ZERO), "zero-knockback direct damage is accepted")
	t.assert_true(actor.combat_action.is_hurt(), "zero-knockback direct damage enters HURT")
	t.assert_equal(transitions[transitions.size() - 1], [CombatActionController.State.ATTACK_STARTUP, CombatActionController.State.HURT], "startup transitions directly to HURT without transient IDLE")
	t.assert_equal(runtime.combat.stamina, startup_stamina, "startup interruption spends no stamina")
	_assert_attack_cleared(t, actor, "startup interruption")
	t.assert_equal(actor.velocity, Vector2.ZERO, "zero-knockback HURT does not alter velocity")
	var rejected_stamina := runtime.combat.stamina
	t.assert_true(not actor.combat.attack(1.0), "HURT rejects direct combat attacks")
	t.assert_equal(runtime.combat.stamina, rejected_stamina, "a HURT-rejected attack changes no stamina")
	var network_rejection := actor.network_combat._server_execute_attack(actor.peer_id, 600)
	t.assert_true(not network_rejection.success, "the authoritative network attack path rejects HURT")
	_finish_hurt(actor)
	t.assert_true(not actor.network_combat._server_execute_attack(actor.peer_id, 600).success, "a sequence rejected during HURT is still consumed")

	# ACTIVE: commit remains spent and the live melee hitbox drops immediately.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "active interruption fixture begins an attack")
	actor.combat._process(attack.startup_seconds)
	var active_stamina := runtime.combat.stamina
	t.assert_true(actor.combat.hitbox.active, "melee hitbox is live before active interruption")
	t.assert_true(_damage(actor, Vector2.ZERO), "active interruption damage is accepted")
	t.assert_true(actor.combat_action.is_hurt(), "active damage enters HURT")
	t.assert_equal(runtime.combat.stamina, active_stamina, "active interruption does not refund committed stamina")
	_assert_attack_cleared(t, actor, "active interruption")
	_finish_hurt(actor)

	# RECOVERY: committed stamina remains spent and pending data is discarded.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "recovery interruption fixture begins an attack")
	actor.combat._process(attack.startup_seconds + attack.active_seconds)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "fixture reaches recovery")
	var recovery_stamina := runtime.combat.stamina
	t.assert_true(_damage(actor, Vector2.ZERO), "recovery interruption damage is accepted")
	t.assert_true(actor.combat_action.is_hurt(), "recovery damage enters HURT")
	t.assert_equal(runtime.combat.stamina, recovery_stamina, "recovery interruption does not refund stamina")
	_assert_attack_cleared(t, actor, "recovery interruption")
	_finish_hurt(actor)

	_test_hurt_input_lock(t, actor)
	_finish_hurt(actor)
	_test_interaction_and_item_lock(t, actor)
	_finish_hurt(actor)

	# Explicit non-reaction damage can carry impulse without interrupting combat.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "non-reaction fixture begins startup")
	var impulse_only := DamageContext.new(1.0, &"test", actor, &"hostile", Vector2(100.0, -30.0))
	impulse_only.causes_hurt = false
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(impulse_only), "non-reaction impulse damage is accepted")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "causes_hurt=false does not interrupt startup")
	t.assert_equal(actor.velocity, Vector2(100.0, -30.0), "causes_hurt=false remains independent from physical impulse")
	actor.combat.abort_attack()

	# Periodic and starvation damage reduce HP but do not start or refresh HURT.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "periodic fixture begins startup")
	var periodic_health := actor.health.current_health
	t.assert_true(actor.health.receive_periodic_damage(1.0), "periodic damage is accepted")
	t.assert_true(actor.health.current_health < periodic_health, "periodic damage reduces HP")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "periodic damage does not interrupt startup")
	actor.combat.abort_attack()
	actor.health.invulnerable_remaining = 0.0
	var starvation_health := actor.health.current_health
	actor._on_survival_changed(0.0, 0.0, 3, 3)
	t.assert_true(actor.health.current_health < starvation_health, "starvation damage reduces HP")
	t.assert_true(actor.combat_action.is_idle() and not actor.hurt.is_active(), "starvation damage does not enter HURT")

	await _test_projectile_interruption(t, actor)

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_hurt_input_lock(t: Node, actor: PlayerActor) -> void:
	# Move clear of the floor first so the next locomotion tick deterministically
	# exercises AIR gravity rather than CharacterBody2D's cached floor contact.
	actor.global_position += Vector2(0.0, -100.0)
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()
	actor.velocity = Vector2.ZERO
	actor.input.move_axis = -1.0
	actor.input.vertical_axis = 0.0
	t.assert_true(_damage(actor, Vector2(100.0, -30.0)), "knockback control-lock damage is accepted")
	t.assert_true(actor.hurt.is_active() and actor.movement.controls_locked, "direct hit activates HURT control lock")
	var before := actor.global_position
	actor.movement.physics_tick(0.016)
	t.assert_true(actor.velocity.x > 90.0 and actor.global_position.x > before.x, "horizontal input does not erase knockback velocity or displacement")
	var vertical_before_gravity := actor.velocity.y
	actor.movement.physics_tick(0.016)
	t.assert_true(actor.movement.mode == MovementComponent.Mode.AIR and actor.velocity.y > vertical_before_gravity, "gravity continues during airborne HURT")

	actor.velocity.y = 0.0
	actor.movement.request_jump()
	t.assert_equal(actor.velocity.y, 0.0, "jump is ignored during HURT")

	var climbable := ClimbableArea2D.new()
	climbable.definition = ClimbableDefinition.new()
	climbable.definition.drop_on_damage = false
	climbable.global_position = actor.global_position
	actor.movement.climb_area = climbable
	actor.movement.mode = MovementComponent.Mode.CLIMB
	actor.input.vertical_axis = 1.0
	actor.velocity = Vector2.ZERO
	actor.movement._climb_tick(0.016)
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.CLIMB, "zero-knockback HURT may coexist with CLIMB")
	t.assert_equal(actor.velocity.y, 0.0, "vertical climb input is ignored during HURT")
	actor.movement.exit_climb()
	climbable.free()
	actor.input.move_axis = 0.0
	actor.input.vertical_axis = 0.0
	t.assert_true(MovementComponent.Mode.keys().size() == 3 \
		and MovementComponent.Mode.keys().has("GROUND") and MovementComponent.Mode.keys().has("AIR") \
		and MovementComponent.Mode.keys().has("CLIMB"), "HURT does not enter the locomotion enum")

func _test_interaction_and_item_lock(t: Node, actor: PlayerActor) -> void:
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(_damage(actor, Vector2.ZERO), "interaction lock fixture enters HURT")
	var target := InteractionTarget.new()
	target.interaction_priority = 999
	target.global_position = actor.global_position
	actor.get_parent().add_child(target)
	actor.interaction._targets.append(target)
	var activations: Array[int] = []
	target.activated.connect(func(_who: Node) -> void: activations.append(1))
	var berries_before := actor.player_state().inventory.count(&"berry")
	actor._on_interact()
	actor._on_quick_item()
	t.assert_true(not actor.consume_item(&"berry"), "authoritative direct item use is rejected during HURT")
	t.assert_true(activations.is_empty(), "interaction does not execute during HURT")
	t.assert_equal(actor.player_state().inventory.count(&"berry"), berries_before, "quick item does not execute during HURT")
	t.assert_equal(actor.return_channel, 0.0, "HURT cannot start a return channel")
	_finish_hurt(actor)
	actor.hurt.reset()
	actor.interaction._targets.clear()
	actor.interaction._targets.append(target)
	actor.interaction.current_target = target
	actor._on_interact()
	t.assert_equal(activations.size(), 1, "interaction is available after HURT ends")
	t.assert_true(actor.consume_item(&"berry"), "quick item use is available after HURT ends")
	t.assert_equal(actor.player_state().inventory.count(&"berry"), berries_before - 1, "post-HURT quick item consumes exactly one item")
	actor.interaction._targets.erase(target)
	target.queue_free()

func _test_projectile_interruption(t: Node, actor: PlayerActor) -> void:
	var source := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var weapon := source.duplicate(true) as WeaponDefinition
	weapon.id = &"test_hurt_projectile"
	weapon.attack_mode = WeaponDefinition.AttackMode.PROJECTILE
	weapon.attack_scene = load("res://tests/fixtures/projectile_attack.tscn") as PackedScene
	weapon.attack_definition = source.attack_definition.duplicate() as AttackDefinition
	weapon.attack_definition.range = 180.0
	ContentRegistry._definitions[weapon.id] = weapon
	var stack := ItemStack.new(weapon.id, 1)
	stack.durability = weapon.max_durability
	var previous := actor.player_state().equipment.equip(stack)
	var runtime := GameSession.get_player_runtime(actor.peer_id)

	runtime.combat.stamina = runtime.combat.max_stamina
	var before := _projectile_count(actor.get_parent())
	t.assert_true(actor.combat.attack(1.0), "projectile startup interruption begins")
	t.assert_true(_damage(actor, Vector2.ZERO), "projectile startup interruption damage is accepted")
	t.assert_equal(_projectile_count(actor.get_parent()), before, "startup interruption spawns no projectile")
	_finish_hurt(actor)

	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "projectile active interruption begins")
	actor.combat._process(weapon.attack_definition.startup_seconds)
	var projectile := _first_projectile(actor.get_parent())
	t.assert_true(projectile != null, "projectile exists after ACTIVE commit")
	var projectile_origin := projectile.global_position
	var committed_stamina := runtime.combat.stamina
	t.assert_true(_damage(actor, Vector2.ZERO), "projectile active interruption damage is accepted")
	t.assert_true(actor.combat_action.is_hurt(), "projectile owner enters HURT")
	t.assert_equal(runtime.combat.stamina, committed_stamina, "projectile interruption does not refund stamina")
	t.assert_true(is_instance_valid(projectile) and _projectile_count(actor.get_parent()) == before + 1, "an already spawned projectile survives owner HURT")
	projectile._physics_process(0.016)
	t.assert_true(is_instance_valid(projectile) and projectile.global_position != projectile_origin, "surviving projectile continues its flight")
	_assert_attack_cleared(t, actor, "projectile active interruption")

	for child in actor.get_parent().get_children():
		if child is ProjectileAttack:
			child.queue_free()
	actor.player_state().equipment.unequip(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	if previous != null:
		actor.player_state().equipment.equip(previous)
	ContentRegistry._definitions.erase(weapon.id)
	_finish_hurt(actor)

func _test_world_transition(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	t.assert_true(_damage(actor, Vector2.ZERO), "world-transition fixture enters HURT")
	t.assert_true(actor.hurt.is_active(), "old actor is HURT before transition")
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var stamina_before := runtime.combat.stamina
	var context := GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(SceneRouter.go_to_adventure(context), "HURT actor can be replaced by a world transition")
	await t.get_tree().process_frame
	var replacement := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(replacement != null and replacement != actor, "world transition creates a new player actor")
	t.assert_true(replacement.combat_action.is_idle() and not replacement.hurt.is_active(), "new world actor starts IDLE without HURT")
	t.assert_true(not replacement.movement.controls_locked, "new world actor starts with controls unlocked")
	t.assert_equal(runtime.combat.stamina, stamina_before, "scene-local HURT does not replace persistent stamina")
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_lethal_without_hurt(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: transitions.append([previous, current]))
	t.assert_true(actor.health.receive_damage(DamageContext.new(9999.0, &"test", actor, &"hostile")), "an IDLE lethal hit is accepted")
	t.assert_true(actor.is_death_handled(), "an IDLE lethal hit enters the existing death lifecycle")
	t.assert_true(not actor.hurt.is_active() and actor.hurt.remaining == 0.0, "an IDLE lethal hit never starts HURT")
	t.assert_true(transitions.is_empty(), "an IDLE lethal hit emits no transient HURT transition")
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_death_and_respawn(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	t.assert_true(_damage(actor, Vector2.ZERO), "death fixture enters HURT")
	t.assert_true(actor.hurt.is_active(), "HURT is active before lethal damage")
	actor.health.invulnerable_remaining = 0.0
	var lethal_transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: lethal_transitions.append([previous, current]))
	t.assert_true(actor.health.receive_damage(DamageContext.new(9999.0, &"test", actor, &"hostile")), "lethal damage is accepted during HURT")
	t.assert_true(actor.is_death_handled(), "lethal damage enters the existing death lifecycle")
	t.assert_true(not actor.hurt.is_active() and actor.hurt.remaining == 0.0, "death clears active HURT and its timer")
	t.assert_true(actor.combat_action.is_idle() and not actor.movement.controls_locked, "death resets combat action and HURT control lock")
	t.assert_equal(lethal_transitions, [[CombatActionController.State.HURT, CombatActionController.State.IDLE]], "lethal damage creates no transient new HURT state")

	for frame in 75:
		await t.get_tree().physics_frame
	var respawned := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(respawned != null and respawned != actor, "death creates a replacement player actor")
	t.assert_true(respawned.combat_action.is_idle() and not respawned.hurt.is_active(), "respawned actor starts IDLE without HURT")
	t.assert_true(not respawned.movement.controls_locked, "respawned actor starts with controls unlocked")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _spawn_settlement_player(t: Node, layer: Node) -> PlayerActor:
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "player HURT fixture loads the settlement")
	await t.get_tree().process_frame
	return t.get_tree().get_first_node_in_group(&"player") as PlayerActor

func _damage(actor: PlayerActor, knockback: Vector2) -> bool:
	actor.health.invulnerable_remaining = 0.0
	return actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile", knockback))

func _finish_hurt(actor: PlayerActor) -> void:
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)

func _assert_attack_cleared(t: Node, actor: PlayerActor, context: String) -> void:
	t.assert_true(not actor.combat.hitbox.active, "%s leaves the hitbox inactive" % context)
	t.assert_true(actor.combat._pending_weapon == null and actor.combat._pending_attack == null \
		and actor.combat._pending_context == null, "%s clears pending attack data" % context)
	t.assert_equal(actor.combat.phase_remaining(), 0.0, "%s clears phase time" % context)

func _projectile_count(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is ProjectileAttack:
			count += 1
	return count

func _first_projectile(parent: Node) -> ProjectileAttack:
	for child in parent.get_children():
		if child is ProjectileAttack:
			return child
	return null
