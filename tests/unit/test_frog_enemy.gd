extends RefCounted
## Runs the real frog in the real Forest Trail with a real PlayerActor.

func run(t: Node) -> void:
	var definition := ContentRegistry.get_definition(&"frog") as EnemyDefinition
	t.assert_true(definition != null and definition.validate_definition(ContentRegistry).is_empty(), "frog definition validates")
	_test_snapshot_states(t, definition)
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	SceneRouter.register_world_layer(layer)
	var context: AdventureContext = GameSession.request_adventure_from_exit(&"forest_gate", &"forest_region")
	t.assert_true(context != null and SceneRouter.go_to_adventure(context), "frog fixture enters the forest through the gate")
	await _frames(t, 6)
	var player := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	var frog: FrogAgent
	var kinds: Dictionary[StringName, int] = {}
	for node in t.get_tree().get_nodes_in_group(&"enemy"):
		var enemy := node as EnemyAgent
		kinds[enemy.definition.id] = int(kinds.get(enemy.definition.id, 0)) + 1
		if enemy is FrogAgent and frog == null:
			frog = enemy
		else:
			enemy.queue_free()
	t.assert_true(int(kinds.get(&"frog", 0)) >= 1 and int(kinds.get(&"sewer_beetle", 0)) >= 1, "the forest spawns frogs and beetles")
	t.assert_true(player != null and frog != null, "frog fixture has a player and a frog")
	if player == null or frog == null:
		await _teardown(t, layer)
		return
	await _frames(t, 2)
	var history: Array[StringName] = []
	var airborne_launches: Array[int] = [0]
	var hits: Array[int] = [0]
	var attacks: Array[int] = [0]
	frog.state_changed.connect(func(id: StringName) -> void:
		history.append(id)
		if id == &"hop" and frog.velocity.y < 0.0 and history.size() >= 2 and history[history.size() - 2] != &"prepare":
			airborne_launches[0] += 1
		if id == &"attack":
			attacks[0] += 1
	)
	player.health.damaged.connect(func(_context: DamageContext) -> void: hits[0] += 1)
	var origin := frog.patrol_origin
	var hollow := layer.get_child(0).get_node("Terrain/FrogHollow") as FieldPlatform
	var left := hollow.global_position.x - hollow.size.x / 2.0
	var right := hollow.global_position.x + hollow.size.x / 2.0

	# Patrol: short hops inside the patrol area, never off the terrain, never a jump from mid-air.
	var min_x := frog.global_position.x
	var max_x := frog.global_position.x
	var highest := 0.0
	var prepared_in_air := false
	for index in 420:
		await t.get_tree().physics_frame
		min_x = minf(min_x, frog.global_position.x)
		max_x = maxf(max_x, frog.global_position.x)
		highest = maxf(highest, origin.y - frog.global_position.y)
		if frog.current_state_id == &"prepare" and not frog.is_grounded():
			prepared_in_air = true
	t.assert_true(history.has(&"patrol") and history.has(&"prepare") and history.has(&"hop"), "frog patrols by hopping")
	t.assert_true(max_x - min_x > 30.0, "patrol hops actually move the frog")
	t.assert_true(min_x >= origin.x - frog.patrol_radius - 8.0 and max_x <= origin.x + frog.patrol_radius + 8.0, "patrol stays inside the patrol radius")
	t.assert_true(min_x > left and max_x < right, "patrol stays on its terrain")
	t.assert_true(highest > 8.0 and highest < 60.0, "patrol hops are real, bounded jumps")
	t.assert_true(not prepared_in_air and airborne_launches[0] == 0, "every hop starts from a grounded crouch")
	t.assert_true(not history.has(&"chase") and not history.has(&"attack"), "an undisturbed frog never chases")

	# Detection, chase and the leap attack.
	history.clear()
	player.health.invulnerability_seconds = 0.0
	player.global_position = Vector2(frog.global_position.x - 170.0, frog.global_position.y - 8.0)
	player.velocity = Vector2.ZERO
	var start_health := player.health.current_health
	for index in 420:
		await t.get_tree().physics_frame
		if attacks[0] >= 2 and frog.current_state_id == &"chase":
			break
	t.assert_true(history.find(&"alert") >= 0 and history.find(&"chase") > history.find(&"alert"), "the frog is alerted before it chases")
	t.assert_true(history.has(&"attack") and attacks[0] >= 2, "the frog closes in and attacks")
	t.assert_true(hits[0] >= 1 and hits[0] <= attacks[0], "a leap damages the player at most once")
	t.assert_true(player.health.current_health < start_health, "the leap attack deals damage through the existing damage path")
	var second_attack := history.rfind(&"attack")
	var first_attack := history.find(&"attack")
	t.assert_true(second_attack > first_attack + 1, "the attack cooldown separates two attacks")
	t.assert_true(frog.attack_cooldown_remaining > 0.0, "the cooldown runs after an attack")

	# Losing the target: return home instead of chasing forever.
	history.clear()
	player.health.god_mode = true
	player.global_position = Vector2(200.0, 518.0)
	player.velocity = Vector2.ZERO
	for index in 480:
		await t.get_tree().physics_frame
		if history.has(&"return") and (frog.current_state_id == &"idle" or frog.current_state_id == &"patrol"):
			break
	t.assert_true(history.has(&"return"), "the frog returns when the player is gone")
	t.assert_true(frog.current_state_id == &"idle" or frog.current_state_id == &"patrol", "the frog settles back into idle or patrol")
	t.assert_true(absf(frog.global_position.x - frog.patrol_origin.x) <= frog.patrol_radius + 8.0, "the frog is home again")

	# Edge and wall sensing at the hollow rim.
	var speed := frog.effect_stats.value(&"move_speed")
	t.assert_true(frog.can_hop_toward(signf(origin.x - frog.global_position.x + 0.01), speed * frog.patrol_speed_scale, frog.patrol_hop_lift), "open ground allows a hop")
	t.assert_true(not frog.can_hop_toward(0.0, speed, frog.chase_hop_lift), "no direction means no hop")
	var overlook := layer.get_child(0).get_node("Terrain/Overlook") as FieldPlatform
	frog.set_physics_process(false)
	frog.global_position = Vector2(overlook.global_position.x - overlook.size.x / 2.0 + 12.0, overlook.global_position.y - overlook.size.y / 2.0 - 11.0)
	await t.get_tree().physics_frame
	t.assert_true(not frog.can_hop_toward(-1.0, speed, frog.chase_hop_lift), "a platform edge above a long drop blocks the hop")
	t.assert_true(frog.can_hop_toward(1.0, speed * frog.patrol_speed_scale, frog.patrol_hop_lift), "the same platform still allows a hop inward")
	frog.global_position = origin
	frog.velocity = Vector2.ZERO
	frog.set_physics_process(true)
	await _frames(t, 20)

	# Hurt, then death: no more movement or attacks, loot and removal through the existing path.
	history.clear()
	var attacks_before: int = attacks[0]
	frog.health.invulnerability_seconds = 0.0
	frog.health.receive_damage(DamageContext.new(2.0, &"physical", player, &"player", Vector2(160.0, -40.0)))
	t.assert_equal(frog.current_state_id, &"hurt", "damage puts the frog in hurt")
	await _frames(t, 40)
	t.assert_true(history.has(&"hurt") and frog.current_state_id != &"hurt", "the frog recovers from hurt")
	t.assert_true(absf(frog.velocity.x) < 1.0 or frog.current_state_id == &"hop", "knockback is braked on the ground")
	history.clear()
	frog.health.receive_damage(DamageContext.new(9999.0, &"physical", player, &"player", Vector2.ZERO))
	t.assert_equal(frog.current_state_id, &"dead", "lethal damage kills the frog")
	t.assert_equal(Vector2i(frog.collision_layer, frog.collision_mask), Vector2i.ZERO, "a dead frog stops colliding")
	var dead_position := frog.global_position
	await _frames(t, 10)
	t.assert_true(is_instance_valid(frog) and frog.global_position == dead_position and frog.velocity == Vector2.ZERO, "a dead frog stops moving")
	t.assert_equal(history.count(&"dead"), 1, "death is entered once")
	await _frames(t, 40)
	t.assert_true(not is_instance_valid(frog), "the dead frog is removed by the spawn manager")
	t.assert_equal(attacks[0], attacks_before, "a dying frog does not attack")
	await _teardown(t, layer)

func _test_snapshot_states(t: Node, definition: EnemyDefinition) -> void:
	var frog := definition.actor_scene.instantiate() as FrogAgent
	t.assert_true(frog != null, "frog scene root is a FrogAgent")
	if frog == null:
		return
	var expected := {
		"Idle": EnemyRuntimeSnapshot.State.IDLE, "Patrol": EnemyRuntimeSnapshot.State.IDLE,
		"Alert": EnemyRuntimeSnapshot.State.IDLE, "Chase": EnemyRuntimeSnapshot.State.IDLE,
		"Return": EnemyRuntimeSnapshot.State.IDLE, "Prepare": EnemyRuntimeSnapshot.State.MOVING,
		"Hop": EnemyRuntimeSnapshot.State.MOVING, "Attack": -1, "Hurt": -1, "Dead": -1,
	}
	for state_name in expected:
		var state := frog.get_node_or_null("States/" + state_name) as EnemyState
		t.assert_true(state != null and state.snapshot_state() == expected[state_name], "frog state %s maps onto the existing snapshot states" % state_name)
	t.assert_equal(NetworkEnemyComponent._state_value(&"attack"), EnemyRuntimeSnapshot.State.ATTACKING, "attack keeps the default snapshot mapping")
	t.assert_true(frog.hop_reach(150.0, 340.0) > 60.0 and frog.chase_hop_lift * frog.chase_hop_lift / (2.0 * EnemyAgent.GRAVITY) < 69.0, "frog hops stay below the player's jump height")
	frog.free()

func _frames(t: Node, count: int) -> void:
	for index in count:
		await t.get_tree().physics_frame

func _teardown(t: Node, layer: Node) -> void:
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
