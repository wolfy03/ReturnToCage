extends RefCounted
## Stage-7 dodge regressions. A dodge is a scene-local combat action with an
## authored i-frame window; stamina, damage and locomotion stay with their
## existing owners, and the client only ever sends an intent.

func run(t: Node) -> void:
	_test_definition(t)
	_test_action_transitions(t)
	_test_control_lock_ownership(t)
	_test_command_validation(t)
	_test_input_direction_snapshot(t)
	await _test_dodge_finish_velocity(t)
	await _test_direction_priority(t)
	await _test_actual_ground_requirement(t)
	await _test_return_channel_policy(t)
	await _test_dodge_timeline_and_stamina(t)
	await _test_iframes(t)
	await _test_hurt_interrupt(t)
	await _test_locomotion_boundaries(t)
	await _test_authoritative_guards(t)
	await _test_network_intent(t)
	await _test_death_and_world_transition(t)

func _valid_definition() -> DodgeDefinition:
	var definition := DodgeDefinition.new()
	definition.duration_seconds = 0.30
	definition.iframe_start_seconds = 0.0
	definition.iframe_end_seconds = 0.18
	definition.speed = 420.0
	definition.stamina_cost = 20.0
	return definition

func _test_definition(t: Node) -> void:
	var definition := _valid_definition()
	t.assert_true(definition.validation_errors().is_empty(), "a positive finite dodge definition validates")
	t.assert_true(is_equal_approx(definition.iframe_duration(), 0.18), "iframe_duration spans the authored window")
	# A plain Resource, not registry content: it has no content id of its own.
	t.assert_true(not "id" in definition, "DodgeDefinition is a plain Resource, not a ContentDefinition")

	t.assert_true(definition.is_invulnerable_at(0.0), "the window opens on the first dodge frame")
	t.assert_true(definition.is_invulnerable_at(0.179), "the window covers everything before its end")
	t.assert_true(not definition.is_invulnerable_at(0.18), "the window end is exclusive")
	t.assert_true(not definition.is_invulnerable_at(0.29), "the dodge recovery tail is punishable")
	t.assert_true(not definition.is_invulnerable_at(NAN), "a non-finite elapsed time is never invulnerable")

	for invalid in [NAN, INF, -INF, 0.0, -0.5]:
		for field in ["duration_seconds", "iframe_end_seconds", "speed"]:
			var broken := _valid_definition()
			broken.set(field, invalid)
			var errors := broken.validation_errors(&"test_dodge")
			t.assert_true(not errors.is_empty(), "%s = %s is rejected" % [field, invalid])
			t.assert_true(String(errors[0]).begins_with("test_dodge: "), "validation errors carry the owner id")
	for invalid in [NAN, INF, -INF, -0.5]:
		var broken_start := _valid_definition()
		broken_start.iframe_start_seconds = invalid
		t.assert_true(not broken_start.validation_errors().is_empty(), "iframe_start_seconds = %s is rejected" % invalid)
		var broken_cost := _valid_definition()
		broken_cost.stamina_cost = invalid
		t.assert_true(not broken_cost.validation_errors().is_empty(), "stamina_cost = %s is rejected" % invalid)

	var inverted := _valid_definition()
	inverted.iframe_start_seconds = 0.20
	t.assert_true(not inverted.validation_errors().is_empty(), "an i-frame window that ends before it starts is rejected")
	var overrun := _valid_definition()
	overrun.iframe_end_seconds = 0.40
	t.assert_true(not overrun.validation_errors().is_empty(), "i-frames may not outlast the dodge itself")
	var free_dodge := _valid_definition()
	free_dodge.stamina_cost = 0.0
	t.assert_true(free_dodge.validation_errors().is_empty(), "a zero stamina cost is a valid authoring choice")

	var shipped := load("res://data/combat/player_dodge.tres") as DodgeDefinition
	t.assert_true(shipped != null, "the shipped player dodge resource loads")
	t.assert_true(shipped.validation_errors(&"player_dodge").is_empty(), "the shipped player dodge timing is valid")

func _test_action_transitions(t: Node) -> void:
	var action := CombatActionController.new()
	t.assert_true(action.is_idle() and not action.is_dodging(), "a fresh action axis is idle, not dodging")
	t.assert_true(CombatActionController.is_allowed_transition(CombatActionController.State.IDLE, CombatActionController.State.DODGE), "IDLE may enter DODGE")
	t.assert_true(CombatActionController.is_allowed_transition(CombatActionController.State.DODGE, CombatActionController.State.IDLE), "DODGE may return to IDLE")
	t.assert_true(CombatActionController.is_allowed_transition(CombatActionController.State.DODGE, CombatActionController.State.HURT), "DODGE may be interrupted by HURT")
	# Recovery gained a dodge cancel in stage 8; startup, the live phase and
	# hit-stun are still commitment.
	t.assert_true(CombatActionController.is_allowed_transition(CombatActionController.State.ATTACK_RECOVERY, CombatActionController.State.DODGE), "recovery may be cancelled into DODGE")
	for forbidden in [
		CombatActionController.State.ATTACK_STARTUP,
		CombatActionController.State.ATTACK_ACTIVE,
		CombatActionController.State.HURT,
	]:
		t.assert_true(not CombatActionController.is_allowed_transition(forbidden, CombatActionController.State.DODGE), "state %d cannot be cancelled into DODGE" % forbidden)
	t.assert_true(not CombatActionController.is_allowed_transition(CombatActionController.State.DODGE, CombatActionController.State.ATTACK_STARTUP), "a dodge cannot be cancelled straight into an attack")

	t.assert_true(action.enter_dodge() and action.is_dodging(), "enter_dodge applies the transition")
	t.assert_true(not action.enter_dodge(), "enter_dodge only ever starts a neutral dodge from IDLE")
	t.assert_true(not action.is_attacking() and not action.is_hurt(), "DODGE counts as neither attacking nor hurt")
	t.assert_true(not action.begin_attack(), "an attack is refused while dodging")
	t.assert_true(action.finish_dodge() and action.is_idle(), "finish_dodge returns to IDLE")
	t.assert_true(not action.finish_dodge(), "finish_dodge from IDLE changes nothing")

	t.assert_true(MovementComponent.Mode.keys().size() == 3 \
		and MovementComponent.Mode.keys().has("GROUND") and MovementComponent.Mode.keys().has("AIR") \
		and MovementComponent.Mode.keys().has("CLIMB"), "DODGE does not enter the locomotion enum")
	action.free()

func _test_control_lock_ownership(t: Node) -> void:
	var movement := MovementComponent.new()
	t.assert_true(not movement.controls_locked and movement.control_lock_count() == 0, "a fresh movement component holds no locks")
	t.assert_true(not movement.set_control_lock(&"", true), "an unnamed lock source is rejected")
	t.assert_true(not movement.controls_locked, "a rejected lock leaves controls free")

	t.assert_true(movement.set_control_lock(MovementComponent.CONTROL_LOCK_DODGE, true), "the dodge may take a lock")
	t.assert_true(movement.set_control_lock(MovementComponent.CONTROL_LOCK_HURT, true), "hit-stun may take a lock at the same time")
	t.assert_equal(movement.control_lock_count(), 2, "locks from different owners are additive")
	movement.set_control_lock(MovementComponent.CONTROL_LOCK_DODGE, false)
	t.assert_true(movement.controls_locked and movement.has_control_lock(MovementComponent.CONTROL_LOCK_HURT), "releasing the dodge lock does not release hit-stun")
	t.assert_true(not movement.has_control_lock(MovementComponent.CONTROL_LOCK_DODGE), "the released source is gone")
	movement.set_control_lock(MovementComponent.CONTROL_LOCK_HURT, false)
	t.assert_true(not movement.controls_locked and movement.control_lock_count() == 0, "releasing the last owner frees controls")
	movement.set_control_lock(MovementComponent.CONTROL_LOCK_DODGE, true)
	movement.set_control_lock(MovementComponent.CONTROL_LOCK_DODGE, true)
	t.assert_equal(movement.control_lock_count(), 1, "one owner never stacks its own lock")
	movement.free()

func _test_command_validation(t: Node) -> void:
	t.assert_true(PlayerDodgeCommand.new(1, 1.0).is_valid_after(0), "a forward sequence is accepted")
	t.assert_true(not PlayerDodgeCommand.new(1, 1.0).is_valid_after(1), "a duplicate sequence is rejected")
	t.assert_true(not PlayerDodgeCommand.new(0, 1.0).is_valid_after(4), "a stale sequence is rejected")
	t.assert_true(not PlayerDodgeCommand.new(-1, 1.0).is_valid_after(-2), "a negative sequence is rejected")
	# Sequence validity is deliberately independent from the payload, so the host
	# can consume the number before rejecting a malformed direction.
	t.assert_true(PlayerDodgeCommand.new(2, 7.5).is_valid_after(1), "a malformed direction still occupies its sequence")
	for valid_direction in [1.0, -1.0]:
		t.assert_true(PlayerDodgeCommand.new(1, valid_direction).has_valid_direction(), "direction %s is accepted" % valid_direction)
	for invalid_direction in [0.0, 0.5, -0.5, 2.0, -2.0, 12.0, NAN, INF, -INF]:
		t.assert_true(not PlayerDodgeCommand.new(1, invalid_direction).has_valid_direction(), "direction %s is rejected rather than normalised" % invalid_direction)
	# The host multiplies this number by the authored dodge speed, so "almost a
	# facing" is not the contract. The comparison must be exact, not approximate.
	for near_miss in [0.999999, -0.999999, 1.000001, -1.000001]:
		t.assert_true(not PlayerDodgeCommand.new(1, near_miss).has_valid_direction(), "direction %s is rejected by exact validation" % near_miss)
	t.assert_true(InputMap.has_action(&"dodge"), "the dodge input action is defined in project.godot")

func _test_input_direction_snapshot(t: Node) -> void:
	# The dodge edge carries the horizontal intent sampled at the button press.
	# Reading the cached axis instead would describe the previous frame on exactly
	# the tick a player turns and dodges together.
	var input := PlayerInputComponent.new()
	var captured: Array[float] = []
	input.dodge_requested.connect(func(direction: float) -> void: captured.append(direction))
	var event := InputEventAction.new()
	event.action = &"dodge"
	event.pressed = true

	input._unhandled_input(event)
	t.assert_equal(captured, [0.0] as Array[float], "no horizontal input reports no direction")

	captured.clear()
	Input.action_press(&"move_left")
	input._unhandled_input(event)
	Input.action_release(&"move_left")
	t.assert_equal(captured, [-1.0] as Array[float], "a held left input reports -1 at the dodge edge")

	captured.clear()
	Input.action_press(&"move_right")
	input._unhandled_input(event)
	Input.action_release(&"move_right")
	t.assert_equal(captured, [1.0] as Array[float], "a held right input reports +1 at the dodge edge")

	# The cached axis is deliberately not consulted: it still says the old value.
	captured.clear()
	input.move_axis = 1.0
	Input.action_press(&"move_left")
	input._unhandled_input(event)
	Input.action_release(&"move_left")
	t.assert_equal(captured, [-1.0] as Array[float], "the dodge edge ignores the stale cached axis")

	captured.clear()
	input.local_input_enabled = false
	input._unhandled_input(event)
	t.assert_true(captured.is_empty(), "a disabled input component emits no dodge intent")
	input.free()

func _test_dodge_finish_velocity(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	runtime.combat.stamina = runtime.combat.max_stamina

	# A finished dodge must not leave its authored speed behind to coast away
	# under normal deceleration.
	t.assert_true(actor.dodge.try_begin(1.0), "the finish-velocity fixture starts a dodge")
	t.assert_true(is_equal_approx(actor.velocity.x, definition.speed), "the dodge drives the authored roll speed")
	actor.dodge.physics_tick(definition.duration_seconds)
	t.assert_true(not actor.dodge.is_active() and actor.combat_action.is_idle(), "the dodge finished at IDLE")
	t.assert_equal(actor.velocity.x, 0.0, "a finished dodge clears its own horizontal velocity")
	t.assert_true(not actor.movement.controls_locked and not actor.health.evasion_invulnerable, "a finished dodge releases its lock and i-frames")

	# A dodge that rolled off a ledge keeps the fall it earned: only x is cleared.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.dodge.try_begin(1.0), "the ledge-finish fixture starts a dodge")
	actor.global_position += Vector2(0.0, -140.0)
	actor.velocity.y = 0.0
	actor.movement.physics_tick(0.016)
	actor.movement.physics_tick(0.016)
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.AIR, "the ledge fixture is airborne mid-dodge")
	var falling := actor.velocity.y
	t.assert_true(falling > 0.0, "gravity accumulated during the airborne dodge")
	actor.dodge.physics_tick(definition.duration_seconds)
	t.assert_true(not actor.dodge.is_active(), "the airborne dodge still finishes on time")
	t.assert_equal(actor.velocity.x, 0.0, "an airborne finish clears horizontal velocity")
	t.assert_equal(actor.velocity.y, falling, "an airborne finish leaves vertical velocity untouched")

	# Hit-stun is a different ending: it must never swallow the knockback that
	# caused it.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.health.current_health = actor.health.max_health
	t.assert_true(actor.dodge.try_begin(1.0), "the interrupt-velocity fixture starts a dodge")
	actor.dodge.physics_tick(definition.iframe_end_seconds + 0.01)
	actor.velocity = Vector2.ZERO
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile", Vector2(-150.0, -60.0))), "the vulnerable tail is hit")
	t.assert_true(actor.hurt.is_active() and not actor.dodge.is_active(), "the hit interrupts the dodge into hit-stun")
	t.assert_equal(actor.velocity, Vector2(-150.0, -60.0), "an interrupted dodge preserves the knockback impulse")
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	actor.hurt.reset()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_direction_priority(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var submitted: Array[float] = []
	actor.network_dodge.dodge_presented.connect(func(
		_peer_id: int, _sequence: int, direction: float, _duration: float
	) -> void: submitted.append(direction))

	# No horizontal intent falls back to the actor's current facing.
	for facing in [1.0, -1.0]:
		await _settle(t, actor)
		runtime.combat.stamina = runtime.combat.max_stamina
		actor.facing = facing
		submitted.clear()
		actor.network_dodge._on_dodge_requested(0.0)
		t.assert_true(actor.dodge.is_active(), "a facing-only dodge starts with facing %s" % facing)
		t.assert_equal(actor.dodge.direction, facing, "no horizontal input falls back to facing %s" % facing)
		t.assert_equal(submitted, [facing] as Array[float], "the submitted command carries the fallback facing %s" % facing)
		actor.dodge.reset()

	# Current horizontal intent beats a facing that is about to change.
	for intent in [1.0, -1.0]:
		await _settle(t, actor)
		runtime.combat.stamina = runtime.combat.max_stamina
		actor.facing = -intent
		submitted.clear()
		actor.network_dodge._on_dodge_requested(intent)
		t.assert_true(actor.dodge.is_active(), "an input-directed dodge starts toward %s" % intent)
		t.assert_equal(actor.dodge.direction, intent, "current horizontal input overrides the stale facing")
		t.assert_equal(actor.facing, intent, "a committed dodge turns the actor to match")
		t.assert_equal(submitted, [intent] as Array[float], "only a canonical direction crosses the wire")
		actor.dodge.reset()

	# A malformed local signal is refused at the network boundary too: it never
	# turns into a command, and it never quietly becomes the actor's facing.
	for malformed in [0.5, -0.5, 0.999999, 2.0, NAN, INF]:
		await _settle(t, actor)
		runtime.combat.stamina = runtime.combat.max_stamina
		actor.facing = 1.0
		submitted.clear()
		actor.network_dodge._on_dodge_requested(malformed)
		t.assert_true(not actor.dodge.is_active(), "a malformed local dodge signal %s submits nothing" % malformed)
		t.assert_true(submitted.is_empty(), "a malformed local dodge signal %s produces no presentation" % malformed)
		t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "a malformed local dodge signal spends no stamina")

	# A facing that is itself unusable is not replaced with an invented one.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.facing = NAN
	submitted.clear()
	actor.network_dodge._on_dodge_requested(0.0)
	t.assert_true(not actor.dodge.is_active() and submitted.is_empty(), "an unusable facing produces no fallback dodge")
	actor.facing = 1.0

	# A raw axis value never becomes a roll: the component rejects it outright
	# rather than rounding it into a usable direction.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	var stamina_before := runtime.combat.stamina
	for raw in [0.5, -0.5, 0.999999, -0.999999, 2.0]:
		t.assert_true(not actor.dodge.try_begin(raw), "a non-canonical direction %s is rejected, not rounded" % raw)
	t.assert_true(actor.combat_action.is_idle(), "rejected directions leave the action axis idle")
	t.assert_equal(runtime.combat.stamina, stamina_before, "rejected directions spend no stamina")
	t.assert_true(not actor.dodge.try_begin(NAN) and not actor.dodge.try_begin(INF), "non-finite directions are rejected")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_actual_ground_requirement(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	runtime.combat.stamina = runtime.combat.max_stamina

	t.assert_true(actor.is_on_floor() and actor.movement.mode == MovementComponent.Mode.GROUND, "the fixture actor really is standing on the world")
	t.assert_true(actor.dodge.try_begin(1.0), "a genuinely grounded actor may dodge")
	actor.dodge.reset()

	# `movement.mode` is written once per physics tick, so it can still say GROUND
	# for an actor that has already left the floor. The real floor contact decides.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	var stamina_before := runtime.combat.stamina
	actor.global_position += Vector2(0.0, -220.0)
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()
	actor.movement.mode = MovementComponent.Mode.GROUND
	t.assert_true(not actor.is_on_floor(), "the stale-mode fixture is actually airborne")
	t.assert_true(not actor.dodge.try_begin(1.0), "a stale GROUND mode does not let an airborne actor dodge")
	t.assert_true(actor.combat_action.is_idle(), "the rejected stale-mode dodge leaves the action axis idle")
	t.assert_equal(runtime.combat.stamina, stamina_before, "the rejected stale-mode dodge spends no stamina")
	t.assert_true(not actor.movement.controls_locked, "the rejected stale-mode dodge takes no control lock")

	t.assert_true(await _settle(t, actor), "the actor lands again after the stale-mode check")
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.dodge.try_begin(1.0), "the re-landed actor may dodge again")
	actor.dodge.reset()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_return_channel_policy(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	var cancellations: Array[int] = []
	actor.return_channel_changed.connect(func(active: bool, _progress: float) -> void:
		if not active:
			cancellations.append(1)
	)

	# A committed dodge interrupts an in-progress return channel.
	runtime.combat.stamina = runtime.combat.max_stamina
	_start_return_channel(actor)
	t.assert_true(actor.return_channel > 0.0 and not actor.movement.enabled, "the channel fixture is running with movement disabled")
	cancellations.clear()
	t.assert_true(actor.dodge.try_begin(1.0), "a valid dodge is not blocked by an active return channel")
	t.assert_equal(actor.return_channel, 0.0, "a committed dodge cancels the return channel")
	t.assert_true(actor.movement.enabled, "cancelling the channel restores movement")
	t.assert_equal(cancellations.size(), 1, "the channel is cancelled by exactly one owner")
	t.assert_true(actor.dodge.is_active() and actor.movement.has_control_lock(MovementComponent.CONTROL_LOCK_DODGE), "the dodge runs normally after cancelling the channel")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina - definition.stamina_cost, "the dodge still commits stamina exactly once")
	actor.dodge.reset()

	# Every rejection path must leave the channel — and movement — untouched.
	await _settle(t, actor)
	runtime.combat.stamina = definition.stamina_cost - 1.0
	_start_return_channel(actor)
	cancellations.clear()
	t.assert_true(not actor.dodge.try_begin(1.0), "an unaffordable dodge is rejected")
	t.assert_true(actor.return_channel > 0.0 and not actor.movement.enabled, "an unaffordable dodge preserves the return channel")
	t.assert_true(cancellations.is_empty(), "a rejected dodge emits no channel cancellation")
	_clear_return_channel(actor)

	runtime.combat.stamina = runtime.combat.max_stamina
	await _settle(t, actor)
	actor.global_position += Vector2(0.0, -220.0)
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()
	_start_return_channel(actor)
	cancellations.clear()
	t.assert_true(not actor.dodge.try_begin(1.0), "an airborne dodge is rejected")
	t.assert_true(actor.return_channel > 0.0 and not actor.movement.enabled, "an airborne dodge preserves the return channel")
	_clear_return_channel(actor)

	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile")), "the hit-stun channel fixture is damaged")
	t.assert_true(actor.hurt.is_active(), "the fixture is in hit-stun")
	_start_return_channel(actor)
	cancellations.clear()
	t.assert_true(not actor.dodge.try_begin(1.0), "a dodge during hit-stun is rejected")
	t.assert_true(actor.return_channel > 0.0 and not actor.movement.enabled, "a hit-stun dodge rejection preserves the return channel")
	t.assert_true(cancellations.is_empty(), "no channel cancellation is emitted during hit-stun")
	_clear_return_channel(actor)
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	actor.hurt.reset()

	# A malformed direction is a rejection like any other.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	_start_return_channel(actor)
	cancellations.clear()
	t.assert_true(not actor.dodge.try_begin(0.5), "a malformed direction is rejected")
	t.assert_true(actor.return_channel > 0.0 and not actor.movement.enabled, "a malformed direction preserves the return channel")
	_clear_return_channel(actor)

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

## Reproduces the state PlayerActor enters when a return item starts channelling,
## without depending on adventure phase or inventory contents.
func _start_return_channel(actor: PlayerActor) -> void:
	actor.return_channel = 0.001
	actor.return_channel_origin = actor.global_position
	actor.movement.enabled = false

func _clear_return_channel(actor: PlayerActor) -> void:
	actor.return_channel = 0.0
	actor.movement.enabled = true

func _spawn_settlement_player(t: Node, layer: Node) -> PlayerActor:
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "player dodge fixture loads the settlement")
	await t.get_tree().process_frame
	var actor := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	await _settle(t, actor)
	return actor

## Runs real physics until the actor is genuinely standing on the world, instead
## of forcing `movement.mode`. A dodge now requires actual floor contact, so a
## fixture that fakes the locomotion mode would no longer exercise the contract.
## Also re-freezes stamina regeneration, which survival stage changes can undo.
func _settle(t: Node, actor: PlayerActor, frames: int = 240) -> bool:
	for frame in frames:
		if actor.is_on_floor() and actor.movement.mode == MovementComponent.Mode.GROUND:
			break
		await t.get_tree().physics_frame
	# Regeneration runs in the same _process; freeze it so every spend is exact.
	actor.combat.stamina_regen_multiplier = 0.0
	actor.health.invulnerable_remaining = 0.0
	return actor.is_on_floor() and actor.movement.mode == MovementComponent.Mode.GROUND

func _test_dodge_timeline_and_stamina(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	t.assert_true(definition != null, "the player scene carries an authored dodge definition")
	t.assert_true(not "duration_seconds" in actor.dodge or actor.dodge.definition != null, "the component reads its timing from the definition")

	runtime.combat.stamina = runtime.combat.max_stamina
	var before := runtime.combat.stamina
	actor.facing = 1.0
	t.assert_true(actor.dodge.try_begin(-1.0), "a grounded dodge request is accepted")
	t.assert_true(actor.combat_action.is_dodging() and actor.dodge.is_active(), "a dodge enters the DODGE combat action")
	t.assert_equal(runtime.combat.stamina, before - definition.stamina_cost, "the dodge commits stamina exactly once, on start")
	t.assert_equal(actor.dodge.direction, -1.0, "the requested direction is committed")
	t.assert_equal(actor.facing, -1.0, "the dodge commits the actor facing")
	t.assert_true(is_equal_approx(actor.velocity.x, -definition.speed), "the dodge drives the authored roll speed")
	t.assert_true(actor.movement.controls_locked and actor.movement.has_control_lock(MovementComponent.CONTROL_LOCK_DODGE), "a dodge holds its own named control lock")

	t.assert_true(not actor.dodge.try_begin(1.0), "a second dodge is refused while one is running")
	t.assert_true(not actor.combat.attack(1.0), "an attack is refused while dodging")
	t.assert_equal(runtime.combat.stamina, before - definition.stamina_cost, "a refused dodge spends nothing")

	# Late input may not steer a roll that is already committed.
	actor.input.move_axis = 1.0
	actor.dodge.physics_tick(0.05)
	t.assert_equal(actor.dodge.direction, -1.0, "late input cannot steer a committed dodge")
	t.assert_true(is_equal_approx(actor.velocity.x, -definition.speed), "the roll speed is held for the whole dodge")
	actor.input.move_axis = 0.0

	var mid_stamina := runtime.combat.stamina
	actor.dodge.physics_tick(definition.duration_seconds)
	t.assert_true(not actor.dodge.is_active() and actor.combat_action.is_idle(), "the authored duration ends the dodge at IDLE")
	t.assert_equal(actor.dodge.elapsed, 0.0, "a finished dodge clears its timeline")
	t.assert_true(not actor.movement.controls_locked, "a finished dodge releases its control lock")
	t.assert_equal(runtime.combat.stamina, mid_stamina, "finishing a dodge never refunds its stamina")

	# An oversized frame must still resolve the dodge exactly once.
	runtime.combat.stamina = runtime.combat.max_stamina
	await _settle(t, actor)
	t.assert_true(actor.dodge.try_begin(1.0), "the oversized-delta fixture starts a dodge")
	actor.dodge.physics_tick(definition.duration_seconds + 5.0)
	t.assert_true(not actor.dodge.is_active() and actor.combat_action.is_idle(), "an oversized delta still finishes the dodge")
	t.assert_true(not actor.health.evasion_invulnerable, "an oversized delta closes the i-frame gate")

	# Stamina is the gate: an exhausted player cannot dodge at all.
	await _settle(t, actor)
	runtime.combat.stamina = definition.stamina_cost - 1.0
	t.assert_true(not actor.dodge.try_begin(1.0), "a dodge is refused without enough stamina")
	t.assert_true(actor.combat_action.is_idle(), "a refused dodge leaves the action axis idle")
	t.assert_equal(runtime.combat.stamina, definition.stamina_cost - 1.0, "a refused dodge spends nothing")
	runtime.combat.stamina = runtime.combat.max_stamina

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_iframes(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	runtime.combat.stamina = runtime.combat.max_stamina

	t.assert_true(not actor.health.evasion_invulnerable, "an idle player carries no evasion gate")
	t.assert_true(actor.dodge.try_begin(1.0), "the i-frame fixture starts a dodge")
	t.assert_true(actor.dodge.is_invulnerable() and actor.health.evasion_invulnerable, "the dodge opens the evasion gate on its first frame")

	var health_before := actor.health.current_health
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(not actor.health.receive_damage(DamageContext.new(5.0, &"test", actor, &"hostile")), "an evadable hit is turned aside inside the window")
	t.assert_equal(actor.health.current_health, health_before, "an evaded hit deals no damage")
	t.assert_true(actor.dodge.is_active() and not actor.hurt.is_active(), "an evaded hit neither ends the dodge nor causes hit-stun")
	t.assert_equal(actor.health.invulnerable_remaining, 0.0, "an evaded hit does not consume the post-hit contact window")

	# Survival pressure is explicitly not dodgeable.
	t.assert_true(actor.health.receive_periodic_damage(1.0), "periodic damage lands during i-frames")
	t.assert_true(actor.health.current_health < health_before, "periodic damage still reduces HP")
	var starvation_health := actor.health.current_health
	actor._on_survival_changed(0.0, 0.0, 3, 3)
	t.assert_true(actor.health.current_health < starvation_health, "starvation damage lands during i-frames")
	var unevadable := DamageContext.new(3.0, &"trap", actor, &"environment")
	unevadable.can_be_evaded = false
	var unevadable_health := actor.health.current_health
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(unevadable), "a can_be_evaded = false hit lands during i-frames")
	t.assert_true(actor.health.current_health < unevadable_health, "an unevadable hit still reduces HP")
	t.assert_true(actor.hurt.is_active(), "an unevadable direct hit still causes hit-stun")
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	actor.hurt.reset()
	actor.dodge.reset()

	# The vulnerable tail of the dodge takes hits normally.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.health.current_health = actor.health.max_health
	t.assert_true(actor.dodge.try_begin(1.0), "the i-frame tail fixture starts a dodge")
	actor.dodge.physics_tick(definition.iframe_end_seconds + 0.01)
	t.assert_true(actor.dodge.is_active(), "the dodge is still running after its i-frames end")
	t.assert_true(not actor.dodge.is_invulnerable() and not actor.health.evasion_invulnerable, "the evasion gate closes with the authored window")
	var tail_health := actor.health.current_health
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(5.0, &"test", actor, &"hostile")), "a hit lands on the dodge recovery tail")
	t.assert_true(actor.health.current_health < tail_health, "the dodge tail takes real damage")
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	actor.hurt.reset()
	actor.dodge.reset()
	t.assert_true(not actor.health.evasion_invulnerable, "reset closes the evasion gate")
	t.assert_true(not actor.health.god_mode, "the dodge never reuses god mode")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_hurt_interrupt(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	runtime.combat.stamina = runtime.combat.max_stamina

	var transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: transitions.append([previous, current]))
	t.assert_true(actor.dodge.try_begin(1.0), "the interrupt fixture starts a dodge")
	actor.dodge.physics_tick(definition.iframe_end_seconds + 0.01)
	var committed_stamina := runtime.combat.stamina
	actor.velocity = Vector2.ZERO
	transitions.clear()
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile", Vector2(140.0, -40.0))), "the vulnerable dodge tail is hit")
	t.assert_true(actor.hurt.is_active() and not actor.dodge.is_active(), "hit-stun interrupts a running dodge")
	t.assert_equal(transitions, [[CombatActionController.State.DODGE, CombatActionController.State.HURT]], "the dodge transitions directly to HURT without a transient IDLE")
	t.assert_equal(actor.velocity, Vector2(140.0, -40.0), "an interrupted dodge leaves the knockback impulse intact")
	t.assert_equal(runtime.combat.stamina, committed_stamina, "an interrupted dodge is never refunded")
	t.assert_true(not actor.health.evasion_invulnerable, "hit-stun closes the evasion gate")
	t.assert_true(actor.movement.has_control_lock(MovementComponent.CONTROL_LOCK_HURT), "hit-stun holds its own control lock")
	t.assert_true(not actor.movement.has_control_lock(MovementComponent.CONTROL_LOCK_DODGE), "the interrupted dodge released only its own lock")
	t.assert_true(actor.movement.controls_locked, "controls stay locked through the hand-over")
	t.assert_equal(actor.dodge.elapsed, 0.0, "an interrupted dodge clears its timeline")

	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(not actor.dodge.try_begin(1.0), "a dodge cannot be used to escape hit-stun")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "a dodge refused during hit-stun spends nothing")
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	t.assert_true(not actor.movement.controls_locked, "hit-stun releases the last lock when it ends")
	await _settle(t, actor)
	t.assert_true(actor.dodge.try_begin(1.0), "a dodge is available again once hit-stun ends")
	actor.dodge.reset()

	# An attack in flight is not a dodge cancel.
	runtime.combat.stamina = runtime.combat.max_stamina
	await _settle(t, actor)
	t.assert_true(actor.combat.attack(1.0), "the attack-cancel fixture starts an attack")
	var attack_stamina := runtime.combat.stamina
	t.assert_true(not actor.dodge.try_begin(1.0), "a dodge cannot cancel an attack wind-up")
	t.assert_equal(runtime.combat.stamina, attack_stamina, "a dodge refused during an attack spends nothing")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the refused dodge leaves the attack running")
	actor.combat.abort_attack()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_locomotion_boundaries(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	runtime.combat.stamina = runtime.combat.max_stamina

	# Grounded start only. An airborne or climbing actor has no dodge.
	actor.movement.mode = MovementComponent.Mode.AIR
	t.assert_true(not actor.dodge.try_begin(1.0), "an airborne dodge is refused")
	actor.movement.mode = MovementComponent.Mode.CLIMB
	t.assert_true(not actor.dodge.try_begin(1.0), "a climbing dodge is refused")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "refused starts spend nothing")
	await _settle(t, actor)

	# The component itself never moves the body: it writes velocity and lets
	# move_and_slide resolve terrain, so a wall cannot be rolled through.
	t.assert_true(actor.dodge.try_begin(1.0), "the locomotion fixture starts a dodge")
	var position_before := actor.global_position
	actor.dodge.physics_tick(0.05)
	t.assert_equal(actor.global_position, position_before, "the dodge never writes position directly")

	# Rolling off a ledge is allowed: the dodge keeps running and simply falls.
	actor.global_position += Vector2(0.0, -120.0)
	actor.velocity.y = 0.0
	actor.movement.physics_tick(0.016)
	actor.movement.physics_tick(0.016)
	t.assert_equal(actor.movement.mode, MovementComponent.Mode.AIR, "a dodge that leaves the ground becomes a normal AIR fall")
	t.assert_true(actor.velocity.y > 0.0, "gravity keeps applying during an airborne dodge")
	t.assert_true(actor.dodge.is_active(), "leaving the ground does not cancel a committed dodge")
	t.assert_true(is_equal_approx(actor.velocity.x, definition.speed), "the roll speed survives the ledge")

	# Input and jump stay locked for the whole dodge.
	actor.input.move_axis = -1.0
	actor.movement.physics_tick(0.016)
	t.assert_true(actor.velocity.x > 0.0, "opposing input cannot brake a committed dodge")
	var vertical_before := actor.velocity.y
	actor.movement.request_jump()
	t.assert_equal(actor.velocity.y, vertical_before, "jump is ignored during a dodge")
	actor.input.move_axis = 0.0
	actor.dodge.reset()
	t.assert_true(not actor.movement.controls_locked, "reset releases the dodge control lock")

	# A wall stops the roll rather than letting it pass through.
	await _settle(t, actor)
	actor.velocity = Vector2.ZERO
	runtime.combat.stamina = runtime.combat.max_stamina
	var wall := StaticBody2D.new()
	var wall_shape := CollisionShape2D.new()
	var box := RectangleShape2D.new()
	box.size = Vector2(40.0, 400.0)
	wall_shape.shape = box
	wall.add_child(wall_shape)
	actor.get_parent().add_child(wall)
	wall.global_position = actor.global_position + Vector2(70.0, 0.0)
	await t.get_tree().physics_frame
	await t.get_tree().physics_frame
	var wall_limit := wall.global_position.x - 20.0
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.dodge.try_begin(1.0), "the wall fixture starts a dodge toward the wall")
	for step in 12:
		actor.dodge.physics_tick(0.016)
		actor.movement.physics_tick(0.016)
	t.assert_true(actor.global_position.x < wall_limit, "a dodge cannot roll through a wall")
	actor.dodge.reset()
	wall.queue_free()
	await t.get_tree().process_frame

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_authoritative_guards(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.dodge.try_begin(1.0), "the guard fixture starts a dodge")

	var target := InteractionTarget.new()
	target.interaction_priority = 999
	target.global_position = actor.global_position
	actor.get_parent().add_child(target)
	actor.interaction._targets.append(target)
	actor.interaction.current_target = target
	var activations: Array[int] = []
	target.activated.connect(func(_who: Node) -> void: activations.append(1))
	var berries_before := actor.player_state().inventory.count(&"berry")
	# The world-transition guard only reaches its action checks for a registered,
	# world-ready peer, so the single-player fixture registers itself first.
	var world_state := GameSession.get_peer_world(actor.peer_id)
	NetworkManager.players[actor.peer_id] = NetworkPlayerInfo.new(actor.peer_id, GameSession.get_player_id(actor.peer_id), "Dodge", true)
	NetworkManager.world_ready_peers[actor.peer_id] = PeerWorldReadyState.new(world_state.world_id, world_state.revision)

	var item_service := actor.get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
	var owns_item_service := item_service == null
	if owns_item_service:
		item_service = PlayerItemReplicationService.new()
		actor.get_parent().add_child(item_service)
	var item_results: Array[bool] = []
	item_service.use_item_result.connect(func(success: bool, _message: String) -> void: item_results.append(success), CONNECT_ONE_SHOT)
	item_service.request_use_item(&"berry")
	t.assert_equal(item_results.size(), 1, "the authoritative item command returns one dodge result")
	if not item_results.is_empty():
		t.assert_true(not item_results[0], "the authoritative item command rejects a dodging player")

	actor._on_interact()
	actor._on_quick_item()
	t.assert_true(not actor.consume_item(&"berry"), "authoritative direct item use is rejected while dodging")
	t.assert_true(activations.is_empty(), "interaction does not execute while dodging")
	t.assert_equal(actor.player_state().inventory.count(&"berry"), berries_before, "quick item does not execute while dodging")
	t.assert_equal(actor.return_channel, 0.0, "a dodge cannot start a return channel")
	var transition := NetworkManager._validate_authoritative_world_interaction(actor.peer_id)
	t.assert_true(not transition.success, "the authoritative world-transition guard rejects a dodging player")
	t.assert_equal(transition.message, "Cannot change worlds while dodging", "the guard rejects for the dodge, not for an unrelated reason")

	actor.dodge.reset()
	actor.interaction.current_target = target
	actor._on_interact()
	t.assert_equal(activations.size(), 1, "interaction is available once the dodge ends")
	t.assert_true(actor.consume_item(&"berry"), "quick item use is available once the dodge ends")
	t.assert_true(NetworkManager._validate_authoritative_world_interaction(actor.peer_id).success, "world transitions are available once the dodge ends")

	actor.interaction._targets.erase(target)
	actor.interaction.current_target = null
	target.queue_free()
	if owns_item_service:
		item_service.queue_free()
	NetworkManager.players.erase(actor.peer_id)
	NetworkManager.world_ready_peers.erase(actor.peer_id)
	await t.get_tree().process_frame

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_network_intent(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var definition := actor.dodge.definition
	runtime.combat.stamina = runtime.combat.max_stamina
	var presented: Array[Array] = []
	actor.network_dodge.dodge_presented.connect(func(
		peer_id: int, sequence: int, direction: float, duration: float
	) -> void: presented.append([peer_id, sequence, direction, duration]))

	t.assert_true(not actor.network_dodge._server_execute_dodge(actor.peer_id + 7, 10, 1.0).success, "a command for another peer is rejected")
	t.assert_true(actor.network_dodge._server_execute_dodge(actor.peer_id, 10, 1.0).success, "the authoritative dodge path accepts a valid command")
	t.assert_true(actor.dodge.is_active(), "an accepted command starts the authoritative dodge")
	t.assert_equal(presented.size(), 1, "an accepted dodge is presented exactly once")
	if not presented.is_empty():
		t.assert_equal(presented[0], [actor.peer_id, 10, 1.0, definition.duration_seconds], "the presentation carries direction and authored duration")
	t.assert_true(not actor.network_dodge._server_execute_dodge(actor.peer_id, 10, 1.0).success, "a duplicate sequence is rejected")
	t.assert_true(not actor.network_dodge._server_execute_dodge(actor.peer_id, 9, 1.0).success, "a stale sequence is rejected")
	actor.dodge.reset()

	# A command rejected by gameplay still consumes its sequence, so it cannot be
	# replayed once the actor is dodgeable again.
	await _settle(t, actor)
	runtime.combat.stamina = 0.0
	t.assert_true(not actor.network_dodge._server_execute_dodge(actor.peer_id, 20, 1.0).success, "an unaffordable dodge command is rejected")
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(not actor.network_dodge._server_execute_dodge(actor.peer_id, 20, 1.0).success, "a rejected sequence is still consumed")
	t.assert_true(not actor.dodge.is_active(), "a replayed sequence starts no dodge")

	# A malformed direction is rejected without inventing a facing for it.
	for malformed in [0.0, 0.25, 9.0, NAN, INF]:
		var rejected := actor.network_dodge._server_execute_dodge(actor.peer_id, 30 + presented.size(), malformed)
		t.assert_true(not rejected.success, "direction %s is rejected by the authoritative path" % malformed)
	t.assert_true(not actor.dodge.is_active(), "a malformed command starts no dodge")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "a malformed command spends no stamina")

	# The presentation path mirrors, it does not simulate.
	await _settle(t, actor)
	var presented_count := presented.size()
	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 99, -1.0, definition.duration_seconds)
	t.assert_equal(presented.size(), presented_count, "an authoritative actor ignores presentation packets about itself")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "a presentation packet spends no stamina")
	t.assert_true(not actor.dodge.is_active(), "a presentation packet starts no authoritative dodge")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_death_and_world_transition(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.dodge.try_begin(1.0), "the transition fixture starts a dodge")
	var stamina_before := runtime.combat.stamina
	var previous_dodge := actor.dodge

	var context := GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(SceneRouter.go_to_adventure(context), "a dodging actor can be replaced by a world transition")
	await t.get_tree().process_frame
	var replacement := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(replacement != null and replacement != actor, "the world transition creates a new player actor")
	t.assert_true(replacement.dodge != previous_dodge, "the dodge component is scene-local, not shared")
	t.assert_true(replacement.combat_action.is_idle() and not replacement.dodge.is_active(), "a new world actor starts IDLE without a dodge")
	t.assert_true(not replacement.movement.controls_locked, "a new world actor starts with controls unlocked")
	t.assert_true(not replacement.health.evasion_invulnerable, "a new world actor starts without i-frames")
	t.assert_true(runtime.combat.stamina >= stamina_before and runtime.combat.stamina < runtime.combat.max_stamina, "a scene-local dodge does not replace persistent stamina, and its spend survives the transition")

	replacement.combat.stamina_regen_multiplier = 0.0
	await _settle(t, replacement)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(replacement.dodge.try_begin(1.0), "the new actor can dodge")
	t.assert_true(replacement.health.evasion_invulnerable, "the new actor's dodge opens its own evasion gate")
	replacement._on_died(DamageContext.new(999.0, &"test", replacement, &"environment"))
	t.assert_true(replacement.is_death_handled(), "the death fixture resolves")
	t.assert_true(not replacement.dodge.is_active() and replacement.combat_action.is_idle(), "death clears a running dodge")
	t.assert_true(not replacement.health.evasion_invulnerable, "death closes the evasion gate")
	t.assert_true(not replacement.movement.controls_locked, "death releases the dodge control lock")
	t.assert_equal(replacement.dodge.elapsed, 0.0, "death clears the dodge timeline")

	t.assert_true(SceneRouter.go_to_settlement(), "the death fixture returns to the settlement")
	await t.get_tree().process_frame
	var respawned := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(respawned != null and not respawned.dodge.is_active(), "a respawned actor starts without a dodge")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
