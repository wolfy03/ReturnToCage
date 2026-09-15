extends RefCounted
## Stage-8 combo, authoritative input buffer and authored cancel windows.
##
## The buffer is a server-side scheduler, not client prediction: it decides only
## *when* an already-validated intent runs. Cancel windows are authored data, so
## whether a chain or a dodge cancel may happen is never a code decision.

func run(t: Node) -> void:
	_test_window_definition(t)
	_test_combo_definition(t)
	_test_weapon_migration(t)
	_test_shipped_combo(t)
	_test_buffer_definition(t)
	await _test_combo_chaining(t)
	await _test_buffered_chain_timing(t)
	await _test_dodge_cancel(t)
	await _test_buffer_lifecycle(t)
	await _test_presentation_timing(t)
	await _test_authoritative_clock(t)
	await _test_full_combo_hits(t)

func _step(startup: float, active: float, recovery: float) -> AttackDefinition:
	var step := AttackDefinition.new()
	step.startup_seconds = startup
	step.active_seconds = active
	step.recovery_seconds = recovery
	return step

func _test_window_definition(t: Node) -> void:
	var window := CombatActionWindowDefinition.new()
	t.assert_true(not window.enabled, "a window is closed until it is authored open")
	t.assert_true(not window.contains(0.0), "a disabled window permits nothing")
	t.assert_true(window.validation_errors(&"test").is_empty(), "a disabled window needs no bounds")

	window.enabled = true
	window.start_seconds = 0.30
	window.end_seconds = 0.50
	t.assert_true(not window.contains(0.29), "a window permits nothing before it opens")
	t.assert_true(window.contains(0.30), "a window opens on its start")
	t.assert_true(window.contains(0.499), "a window covers everything before its end")
	t.assert_true(not window.contains(0.50), "the window end is exclusive")
	t.assert_true(not window.contains(NAN), "a non-finite time is never inside a window")
	t.assert_true(window.validation_errors(&"test", 0.22, 0.55).is_empty(), "a window inside its action validates")
	t.assert_true(not "id" in window, "CombatActionWindowDefinition is a plain Resource, not a ContentDefinition")

	for invalid in [NAN, INF, -INF]:
		var broken_start := CombatTestFixtures.open_window(0.30, 0.50)
		broken_start.start_seconds = invalid
		t.assert_true(not broken_start.validation_errors().is_empty(), "start_seconds = %s is rejected" % invalid)
		var broken_end := CombatTestFixtures.open_window(0.30, 0.50)
		broken_end.end_seconds = invalid
		t.assert_true(not broken_end.validation_errors().is_empty(), "end_seconds = %s is rejected" % invalid)
	var negative := CombatTestFixtures.open_window(-0.10, 0.50)
	t.assert_true(not negative.validation_errors().is_empty(), "a negative start is rejected")
	var inverted := CombatTestFixtures.open_window(0.50, 0.30)
	t.assert_true(not inverted.validation_errors().is_empty(), "a window that ends before it starts is rejected")
	var empty := CombatTestFixtures.open_window(0.30, 0.30)
	t.assert_true(not empty.validation_errors().is_empty(), "a zero-length window is rejected")

	# Startup and the live hitbox are commitment; only recovery may be cancelled.
	var attack := _step(0.10, 0.12, 0.33)
	t.assert_true(is_equal_approx(attack.recovery_start_seconds(), 0.22), "recovery begins after startup and active")
	attack.chain_window = CombatTestFixtures.open_window(0.05, 0.20)
	t.assert_true(not attack.validation_errors().is_empty(), "a window inside startup is rejected")
	attack.chain_window = CombatTestFixtures.open_window(0.15, 0.40)
	t.assert_true(not attack.validation_errors().is_empty(), "a window inside the live phase is rejected")
	attack.chain_window = CombatTestFixtures.open_window(0.30, 0.90)
	t.assert_true(not attack.validation_errors().is_empty(), "a window outlasting its attack is rejected")
	attack.chain_window = CombatTestFixtures.open_window(0.22, 0.55)
	t.assert_true(attack.validation_errors().is_empty(), "a window spanning recovery exactly is valid")
	attack.dodge_cancel_window = CombatTestFixtures.open_window(0.10, 0.30)
	t.assert_true(not attack.validation_errors().is_empty(), "a dodge cancel window is bound by the same rule")
	attack.dodge_cancel_window = null
	t.assert_true(attack.validation_errors().is_empty(), "an absent window is simply no window")
	t.assert_true(not attack.can_dodge_cancel_at(0.30), "an absent window permits no cancel")

func _test_combo_definition(t: Node) -> void:
	var combo := AttackComboDefinition.new()
	t.assert_true(not combo.validation_errors(&"test").is_empty(), "a combo with no steps is invalid")
	t.assert_equal(combo.step_count(), 0, "an empty combo has no steps")
	t.assert_true(combo.step(0) == null and not combo.has_step(0), "an empty combo answers no to every index")

	combo.steps = [null] as Array[AttackDefinition]
	t.assert_true(not combo.validation_errors(&"test").is_empty(), "a null step is invalid")

	var single := CombatTestFixtures.single_step_combo(_step(0.10, 0.12, 0.33))
	t.assert_true(single.validation_errors(&"test").is_empty(), "a one-step combo is valid content")
	t.assert_equal(single.step_count(), 1, "a one-step combo has one step")
	t.assert_true(single.has_step(0) and not single.has_step(1), "a one-step combo ends after its first step")
	t.assert_true(single.step(-1) == null, "a negative index is outside every combo")

	var three := CombatTestFixtures.combo_of([_step(0.10, 0.12, 0.33), _step(0.09, 0.12, 0.30), _step(0.13, 0.14, 0.38)] as Array[AttackDefinition])
	t.assert_true(three.validation_errors(&"test").is_empty(), "a three-step combo is valid content")
	t.assert_equal(three.step_count(), 3, "a three-step combo reports three steps")
	three.steps[1].active_seconds = 0.0
	var errors := three.validation_errors(&"test_weapon")
	t.assert_true(not errors.is_empty(), "an invalid step invalidates the whole combo")
	t.assert_true(String(errors[0]).begins_with("test_weapon step 1: "), "combo errors name the step they came from")
	t.assert_true(not "id" in three, "AttackComboDefinition is a plain Resource, not a ContentDefinition")

func _test_weapon_migration(t: Node) -> void:
	var weapon := WeaponDefinition.new()
	weapon.id = &"test_combo_weapon"
	weapon.display_name = "Combo test"
	t.assert_true(not "attack_definition" in weapon, "the single attack_definition field is gone")
	t.assert_true("attack_combo" in weapon, "attack_combo is the weapon's attack source")
	t.assert_true(not weapon.validate_definition(ContentRegistry).is_empty(), "a weapon without a combo is invalid")
	weapon.attack_combo = AttackComboDefinition.new()
	t.assert_true(not weapon.validate_definition(ContentRegistry).is_empty(), "an empty combo invalidates the weapon")
	weapon.attack_combo = CombatTestFixtures.single_step_combo(_step(0.10, 0.12, 0.33))
	t.assert_true(weapon.validate_definition(ContentRegistry).is_empty(), "a weapon with a valid one-step combo passes")

func _test_shipped_combo(t: Node) -> void:
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var combo := weapon.attack_combo
	t.assert_true(combo != null and combo.step_count() == 3, "twig_sword ships a three-step combo")
	t.assert_true(combo.validation_errors(weapon.id).is_empty(), "the shipped combo is valid content")

	var authored := [
		{"startup": 0.10, "active": 0.12, "recovery": 0.33, "range": 52.0, "size": Vector2(52.0, 30.0), "offset": Vector2(26.0, 0.0), "knockback": Vector2(120.0, -40.0), "chain": [0.30, 0.50], "dodge": [0.22, 0.55]},
		{"startup": 0.09, "active": 0.12, "recovery": 0.30, "range": 56.0, "size": Vector2(56.0, 30.0), "offset": Vector2(28.0, 0.0), "knockback": Vector2(130.0, -40.0), "chain": [0.28, 0.46], "dodge": [0.21, 0.51]},
		{"startup": 0.13, "active": 0.14, "recovery": 0.38, "range": 60.0, "size": Vector2(60.0, 32.0), "offset": Vector2(30.0, 0.0), "knockback": Vector2(165.0, -55.0), "chain": [], "dodge": [0.27, 0.65]},
	]
	for index in authored.size():
		var expected: Dictionary = authored[index]
		var step := combo.step(index)
		t.assert_true(step != null, "step %d exists" % index)
		t.assert_true(is_equal_approx(step.startup_seconds, expected["startup"]), "step %d startup is authored" % index)
		t.assert_true(is_equal_approx(step.active_seconds, expected["active"]), "step %d active is authored" % index)
		t.assert_true(is_equal_approx(step.recovery_seconds, expected["recovery"]), "step %d recovery is authored" % index)
		t.assert_equal(step.range, expected["range"], "step %d range is authored" % index)
		t.assert_equal(step.hitbox_size, expected["size"], "step %d hitbox size is authored" % index)
		t.assert_equal(step.hitbox_offset, expected["offset"], "step %d hitbox offset is authored" % index)
		t.assert_equal(step.knockback, expected["knockback"], "step %d knockback is authored" % index)
		var chain: Array = expected["chain"]
		if chain.is_empty():
			t.assert_true(step.chain_window == null or not step.chain_window.enabled, "step %d ends the combo" % index)
		else:
			t.assert_true(step.chain_window != null and step.chain_window.enabled, "step %d can chain" % index)
			t.assert_true(is_equal_approx(step.chain_window.start_seconds, chain[0]) and is_equal_approx(step.chain_window.end_seconds, chain[1]), "step %d chain window is authored" % index)
		var dodge_bounds: Array = expected["dodge"]
		t.assert_true(step.dodge_cancel_window != null and step.dodge_cancel_window.enabled, "step %d can be dodge-cancelled" % index)
		t.assert_true(is_equal_approx(step.dodge_cancel_window.start_seconds, dodge_bounds[0]) and is_equal_approx(step.dodge_cancel_window.end_seconds, dodge_bounds[1]), "step %d dodge window is authored" % index)
		t.assert_true(step.dodge_cancel_window.start_seconds >= step.recovery_start_seconds() - 0.0001, "step %d dodge window stays inside recovery" % index)

func _test_buffer_definition(t: Node) -> void:
	var definition := CombatInputBufferDefinition.new()
	t.assert_true(definition.validation_errors().is_empty(), "the default buffer duration is valid")
	for invalid in [NAN, INF, -INF, 0.0, -0.2]:
		var broken := CombatInputBufferDefinition.new()
		broken.buffer_seconds = invalid
		t.assert_true(not broken.validation_errors(&"test").is_empty(), "buffer_seconds = %s is rejected" % invalid)
	var shipped := load("res://data/combat/player_input_buffer.tres") as CombatInputBufferDefinition
	t.assert_true(shipped != null and shipped.validation_errors().is_empty(), "the shipped player input buffer is valid")
	t.assert_true(is_equal_approx(shipped.buffer_seconds, 0.15), "the shipped buffer window is 0.15s")

func _spawn(t: Node, layer: Node) -> PlayerActor:
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "combo fixture loads the settlement")
	await t.get_tree().process_frame
	var actor := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	await _settle(t, actor)
	return actor

func _settle(t: Node, actor: PlayerActor, frames: int = 240) -> bool:
	for frame in frames:
		if actor.is_on_floor() and actor.movement.mode == MovementComponent.Mode.GROUND:
			break
		await t.get_tree().physics_frame
	actor.combat.stamina_regen_multiplier = 0.0
	actor.health.invulnerable_remaining = 0.0
	actor.input_buffer.clear()
	return actor.is_on_floor() and actor.movement.mode == MovementComponent.Mode.GROUND

## Drives the attack timeline forward from wherever it is to the first instant
## inside the current step's chain window, without going through the buffer.
func _advance_to_chain_window(actor: PlayerActor, step: AttackDefinition) -> void:
	_advance_to_elapsed(actor, step.chain_window.start_seconds + 0.001)

func _advance_to_elapsed(actor: PlayerActor, target: float) -> void:
	var delta := target - actor.combat.attack_elapsed()
	if delta > 0.0:
		actor.combat.physics_tick(delta)

## Registers a twig_sword variant whose first step closes its follow-up windows
## before recovery ends, so a "window has closed" case actually exists. The
## shipped weapon deliberately leaves both windows open for all of recovery.
func _equip_narrow_window_weapon(actor: PlayerActor) -> ItemStack:
	var source := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var weapon := source.duplicate(true) as WeaponDefinition
	weapon.id = &"test_narrow_window_sword"
	var step := weapon.attack_combo.step(0)
	step.dodge_cancel_window = CombatTestFixtures.open_window(0.22, 0.30)
	step.chain_window = CombatTestFixtures.open_window(0.22, 0.30)
	ContentRegistry._definitions[weapon.id] = weapon
	var stack := ItemStack.new(weapon.id, 1)
	stack.durability = weapon.max_durability
	return actor.player_state().equipment.equip(stack)

func _restore_weapon(actor: PlayerActor, previous: ItemStack) -> void:
	actor.player_state().equipment.unequip(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	if previous != null:
		actor.player_state().equipment.equip(previous)
	ContentRegistry._definitions.erase(&"test_narrow_window_sword")

func _test_combo_chaining(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var combo := weapon.attack_combo
	runtime.combat.stamina = runtime.combat.max_stamina
	var start_stamina := runtime.combat.stamina
	var transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: transitions.append([previous, current]))

	t.assert_true(actor.combat.attack(1.0), "the combo fixture starts its first step")
	t.assert_equal(actor.combat.combo_index(), 0, "an independent attack starts at the first step")
	t.assert_equal(actor.combat.attack_elapsed(), 0.0, "a new step starts with no elapsed time")
	t.assert_true(not actor.combat.can_chain_attack_now(), "a wind-up cannot chain")
	actor.combat.physics_tick(combo.step(0).startup_seconds)
	t.assert_equal(runtime.combat.stamina, start_stamina - weapon.stamina_cost, "the first step commits its own stamina")
	t.assert_true(not actor.combat.can_chain_attack_now(), "the live phase cannot chain")
	t.assert_true(not actor.combat.can_dodge_cancel_now(), "the live phase cannot be dodge-cancelled")

	actor.combat.physics_tick(combo.step(0).active_seconds)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the first step reaches recovery")
	t.assert_true(is_equal_approx(actor.combat.attack_elapsed(), combo.step(0).recovery_start_seconds()), "elapsed tracks the whole step, not the phase")
	t.assert_true(not actor.combat.can_chain_attack_now(), "recovery cannot chain before its authored window")
	t.assert_true(actor.combat.can_dodge_cancel_now(), "the dodge cancel window opens as recovery begins")
	t.assert_true(not actor.combat.chain_attack(1.0), "a chain outside the window is refused")

	_advance_to_chain_window(actor, combo.step(0))
	t.assert_true(actor.combat.can_chain_attack_now(), "the chain window opens on time")
	transitions.clear()
	var before_second := runtime.combat.stamina
	t.assert_true(actor.combat.chain_attack(1.0), "the second step chains out of recovery")
	t.assert_equal(transitions, [[CombatActionController.State.ATTACK_RECOVERY, CombatActionController.State.ATTACK_STARTUP]], "a chain never passes through IDLE")
	t.assert_equal(actor.combat.combo_index(), 1, "the chain advances the combo index")
	t.assert_equal(actor.combat.attack_elapsed(), 0.0, "a chained step restarts its own clock")
	t.assert_equal(runtime.combat.stamina, before_second, "starting a step spends nothing; the commit does")
	t.assert_true(is_equal_approx(actor.combat.phase_remaining(), combo.step(1).startup_seconds), "the second step uses its own authored startup")

	actor.combat.physics_tick(combo.step(1).startup_seconds)
	t.assert_equal(runtime.combat.stamina, before_second - weapon.stamina_cost, "the second step commits its own stamina")
	t.assert_equal(actor.combat._pending_context.knockback, combo.step(1).knockback, "each step builds its own damage context")
	actor.combat.physics_tick(combo.step(1).active_seconds)
	_advance_to_chain_window(actor, combo.step(1))
	transitions.clear()
	t.assert_true(actor.combat.chain_attack(1.0), "the third step chains out of the second")
	t.assert_equal(transitions, [[CombatActionController.State.ATTACK_RECOVERY, CombatActionController.State.ATTACK_STARTUP]], "the second chain never passes through IDLE either")
	t.assert_equal(actor.combat.combo_index(), 2, "the combo reaches its last step")

	actor.combat.physics_tick(combo.step(2).startup_seconds)
	t.assert_equal(runtime.combat.stamina, start_stamina - weapon.stamina_cost * 3.0, "a full combo costs one commit per step")
	actor.combat.physics_tick(combo.step(2).active_seconds)
	t.assert_true(not actor.combat.can_chain_attack_now(), "the last step has nowhere to chain")
	t.assert_true(not actor.combat.chain_attack(1.0), "the last step refuses to chain")
	actor.combat.physics_tick(combo.step(2).recovery_seconds)
	t.assert_true(actor.combat_action.is_idle(), "the combo ends at IDLE")
	t.assert_equal(actor.combat.combo_index(), 0, "finishing the combo resets the index")
	t.assert_equal(actor.combat.attack_elapsed(), 0.0, "finishing the combo clears the step clock")

	# A fresh attack always opens the combo again.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "a new independent attack is accepted")
	t.assert_equal(actor.combat.combo_index(), 0, "an independent attack restarts at the first step")
	actor.combat.abort_attack()
	t.assert_equal(actor.combat.combo_index(), 0, "aborting clears the combo index")

	# An oversized frame still walks a step exactly once and reports honest elapsed.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the oversized-delta fixture starts a step")
	actor.combat.physics_tick(combo.step(0).total_seconds() + 1.0)
	t.assert_true(actor.combat_action.is_idle(), "an oversized delta finishes the step")
	actor.combat.abort_attack()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_buffered_chain_timing(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var combo := weapon.attack_combo
	var buffer := actor.input_buffer
	var buffer_seconds := buffer.definition.buffer_seconds

	# Pressed during the wind-up: too early to run, so it waits.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the buffered-chain fixture starts its first step")
	t.assert_equal(buffer.submit_attack(10, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "an attack during startup is buffered")
	t.assert_true(buffer.has_pending(), "the buffer holds the early intent")
	t.assert_equal(buffer.pending_sequence(), 10, "the buffer keeps the command's own sequence")
	t.assert_equal(actor.combat.combo_index(), 0, "buffering starts nothing yet")

	actor.combat.physics_tick(combo.step(0).startup_seconds)
	buffer.physics_tick(0.001)
	t.assert_true(buffer.has_pending() and actor.combat.combo_index() == 0, "the live phase is not a chance to chain")
	actor.combat.physics_tick(combo.step(0).active_seconds)
	buffer.physics_tick(0.001)
	t.assert_true(buffer.has_pending(), "recovery before the window is still not a chance to chain")

	_advance_to_chain_window(actor, combo.step(0))
	buffer.physics_tick(0.001)
	t.assert_true(not buffer.has_pending(), "the buffered intent is consumed when its window opens")
	t.assert_equal(actor.combat.combo_index(), 1, "the buffered intent chained into the second step")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the chained step began its wind-up")
	actor.combat.abort_attack()

	# Pressed far too early: the intent expires before the window ever opens.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the expiry fixture starts its first step")
	t.assert_equal(buffer.submit_attack(11, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "the expiry fixture buffers an attack")
	buffer.physics_tick(buffer_seconds + 0.01)
	t.assert_true(not buffer.has_pending(), "an abandoned intent expires")
	actor.combat.physics_tick(combo.step(0).total_seconds())
	buffer.physics_tick(0.016)
	t.assert_true(actor.combat_action.is_idle() and actor.combat.combo_index() == 0, "an expired intent starts nothing at all")

	# Pressed after the chain window closed, but while the buffer still lives:
	# the combo is over, so this opens a new one rather than resuming the old.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the late-input fixture starts its first step")
	_advance_to_elapsed(actor, combo.step(0).chain_window.end_seconds + 0.001)
	t.assert_true(not actor.combat.can_chain_attack_now(), "the chain window has closed")
	t.assert_equal(buffer.submit_attack(12, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "a late attack still buffers")
	actor.combat.physics_tick(combo.step(0).total_seconds())
	t.assert_true(actor.combat_action.is_idle(), "the first step ran to completion")
	buffer.physics_tick(0.001)
	t.assert_equal(actor.combat.combo_index(), 0, "a late intent opens a new combo instead of resuming the old one")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the new combo began")
	actor.combat.abort_attack()

	# The last step cannot chain, but the buffer still survives into a new combo.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the last-step fixture opens its combo")
	# Drive straight to the final step through the authored windows.
	_advance_to_chain_window(actor, combo.step(0))
	t.assert_true(actor.combat.chain_attack(1.0), "the last-step fixture chains once")
	_advance_to_chain_window(actor, combo.step(1))
	t.assert_true(actor.combat.chain_attack(1.0), "the last-step fixture chains twice")
	t.assert_equal(actor.combat.combo_index(), 2, "the fixture reached the last step")
	_advance_to_elapsed(actor, combo.step(2).recovery_start_seconds())
	t.assert_equal(buffer.submit_attack(13, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "an attack during the last step's recovery buffers")
	buffer.physics_tick(0.001)
	t.assert_true(buffer.has_pending() and actor.combat.combo_index() == 2, "the last step never chains")
	_advance_to_elapsed(actor, combo.step(2).total_seconds() + 0.001)
	t.assert_true(actor.combat_action.is_idle(), "the last step ran to completion")
	buffer.physics_tick(0.001)
	t.assert_equal(actor.combat.combo_index(), 0, "the buffered intent opens a fresh combo after the last step")
	actor.combat.abort_attack()

	# A buffered swing keeps the facing the player asked for.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.facing = -1.0
	t.assert_true(actor.combat.attack(-1.0), "the facing fixture starts facing left")
	t.assert_equal(buffer.submit_attack(14, -1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "the facing fixture buffers a left-facing attack")
	actor.facing = 1.0
	_advance_to_chain_window(actor, combo.step(0))
	buffer.physics_tick(0.001)
	t.assert_equal(actor.combat.combo_index(), 1, "the buffered facing fixture chained")
	t.assert_equal(actor.combat._pending_facing, -1.0, "a buffered swing uses the facing snapshotted at input time")
	t.assert_equal(actor.combat._pending_context.knockback.x, -combo.step(1).knockback.x, "the snapshotted facing mirrors the step's knockback")
	actor.combat.abort_attack()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_dodge_cancel(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var step := weapon.attack_combo.step(0)
	var buffer := actor.input_buffer
	var dodge_cost := actor.dodge.definition.stamina_cost

	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the dodge cancel fixture starts an attack")
	# Startup and the live phase are commitment: a dodge waits, it does not cut in.
	t.assert_equal(buffer.submit_dodge(20, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "a dodge during startup is buffered, not executed")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "startup is not cancelled into a dodge")
	buffer.physics_tick(0.001)
	t.assert_true(buffer.has_pending(), "a buffered dodge waits through startup")
	actor.combat.physics_tick(step.startup_seconds)
	buffer.physics_tick(0.001)
	t.assert_true(buffer.has_pending() and actor.combat_action.current_state() == CombatActionController.State.ATTACK_ACTIVE, "the live phase is not cancelled into a dodge either")

	var committed_attack_stamina := runtime.combat.stamina
	var transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: transitions.append([previous, current]))
	actor.combat.physics_tick(step.active_seconds)
	t.assert_true(actor.combat.can_dodge_cancel_now(), "the dodge cancel window is open in recovery")
	transitions.clear()
	buffer.physics_tick(0.001)
	t.assert_true(not buffer.has_pending(), "the buffered dodge runs when its window opens")
	t.assert_equal(transitions, [[CombatActionController.State.ATTACK_RECOVERY, CombatActionController.State.DODGE]], "the cancel goes straight from recovery into DODGE")
	t.assert_true(actor.dodge.is_active(), "the dodge actually started")
	t.assert_equal(runtime.combat.stamina, committed_attack_stamina - dodge_cost, "the cancel costs a dodge; the attack keeps what it already spent")
	t.assert_true(actor.combat._pending_weapon == null and actor.combat._pending_attack == null, "the cancelled attack drops its pending data")
	t.assert_equal(actor.combat.phase_remaining(), 0.0, "the cancelled attack drops its phase timer")
	t.assert_equal(actor.combat.combo_index(), 0, "a dodge cancel ends the combo")
	t.assert_true(not actor.combat.hitbox.active, "the cancelled attack leaves no live hitbox")
	t.assert_true(actor.movement.has_control_lock(MovementComponent.CONTROL_LOCK_DODGE), "the cancel dodge holds its own control lock")
	actor.dodge.reset()

	# Outside the authored window the cancel is simply unavailable. The shipped
	# weapon leaves both windows open for all of recovery, so this needs a variant
	# whose windows actually close while the attack is still running.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	var previous := _equip_narrow_window_weapon(actor)
	var narrow := (ContentRegistry.get_definition(&"test_narrow_window_sword") as WeaponDefinition).attack_combo.step(0)
	t.assert_true(actor.combat.attack(1.0), "the closed-window fixture starts an attack")
	_advance_to_elapsed(actor, narrow.dodge_cancel_window.end_seconds + 0.001)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the closed-window fixture is still in recovery")
	t.assert_true(not actor.combat.can_dodge_cancel_now(), "the dodge cancel window has closed")
	t.assert_true(not actor.combat.can_chain_attack_now(), "the chain window has closed too")
	var closed_stamina := runtime.combat.stamina
	t.assert_true(not actor.dodge.try_begin_from_attack_cancel(1.0), "a cancel outside the window is refused")
	t.assert_equal(runtime.combat.stamina, closed_stamina, "a refused cancel spends nothing")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "a refused cancel leaves the attack running")
	t.assert_true(not actor.dodge.try_begin(1.0), "the neutral dodge entry never cancels an attack")
	t.assert_true(not actor.combat.chain_attack(1.0), "a chain outside the window is refused too")
	actor.combat.abort_attack()
	_restore_weapon(actor, previous)

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_buffer_lifecycle(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var step := weapon.attack_combo.step(0)
	var buffer := actor.input_buffer

	# Latest input wins, in both directions. A buffer is not a queue.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the replacement fixture starts an attack")
	buffer.submit_attack(30, 1.0)
	t.assert_equal(buffer.pending_intent(), CombatInputBufferComponent.Intent.ATTACK, "the attack intent is pending")
	buffer.submit_dodge(31, 1.0)
	t.assert_equal(buffer.pending_intent(), CombatInputBufferComponent.Intent.DODGE, "a later dodge replaces the pending attack")
	t.assert_equal(buffer.pending_sequence(), 31, "the replacement keeps its own sequence")
	buffer.submit_attack(32, 1.0)
	t.assert_equal(buffer.pending_intent(), CombatInputBufferComponent.Intent.ATTACK, "a later attack replaces the pending dodge")
	buffer.clear()
	t.assert_true(not buffer.has_pending() and buffer.remaining() == 0.0, "clearing drops the intent and its clock")
	actor.combat.abort_attack()

	# An intent refused while the actor is free is refused on its merits, and the
	# buffer does not keep it around hoping the answer changes.
	await _settle(t, actor)
	runtime.combat.stamina = 0.0
	t.assert_equal(buffer.submit_attack(33, 1.0), CombatInputBufferComponent.SubmitResult.REJECTED, "an unaffordable attack from IDLE is rejected")
	t.assert_true(not buffer.has_pending(), "an IDLE refusal is not buffered")
	t.assert_equal(buffer.submit_dodge(34, 1.0), CombatInputBufferComponent.SubmitResult.REJECTED, "an unaffordable dodge from IDLE is rejected")
	t.assert_true(not buffer.has_pending(), "an IDLE dodge refusal is not buffered either")

	# Being hit ends the exchange, and the intent queued for it dies with it.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the hit-stun fixture starts an attack")
	buffer.submit_attack(35, 1.0)
	t.assert_true(buffer.has_pending(), "an intent is pending before the hit")
	actor.health.invulnerable_remaining = 0.0
	t.assert_true(actor.health.receive_damage(DamageContext.new(1.0, &"test", actor, &"hostile")), "the hit-stun fixture is damaged")
	t.assert_true(actor.hurt.is_active(), "the hit landed")
	t.assert_true(not buffer.has_pending(), "hit-stun drops the intent that belonged to the interrupted exchange")
	t.assert_equal(actor.combat.combo_index(), 0, "hit-stun ends the combo")

	# An intent pressed *during* hit-stun is a new decision, and it survives.
	t.assert_equal(buffer.submit_attack(36, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "an attack pressed during hit-stun is buffered")
	actor.hurt.physics_tick(actor.hurt.duration_seconds + 0.01)
	t.assert_true(actor.combat_action.is_idle(), "hit-stun ended")
	buffer.physics_tick(0.001)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the intent buffered during hit-stun runs once it ends")
	t.assert_equal(actor.combat.combo_index(), 0, "the post-hit attack opens a fresh combo")
	actor.combat.abort_attack()

	# A dodge is not cancelled into an attack; the attack simply waits for it.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.dodge.try_begin(1.0), "the dodge-then-attack fixture starts a dodge")
	t.assert_equal(buffer.submit_attack(37, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "an attack during a dodge is buffered")
	buffer.physics_tick(0.001)
	t.assert_true(actor.dodge.is_active() and buffer.has_pending(), "the dodge is never cancelled into an attack")
	actor.dodge.physics_tick(actor.dodge.definition.duration_seconds)
	t.assert_true(actor.combat_action.is_idle(), "the dodge finished normally")
	buffer.physics_tick(0.001)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the buffered attack runs once the dodge ends")
	actor.combat.abort_attack()

	# An intent that becomes impossible at the moment it is eligible gets exactly
	# one attempt, not an endless retry.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the eligible-failure fixture starts an attack")
	buffer.submit_dodge(38, 1.0)
	actor.combat.physics_tick(step.recovery_start_seconds())
	actor.global_position += Vector2(0.0, -220.0)
	actor.velocity = Vector2.ZERO
	actor.move_and_slide()
	t.assert_true(not actor.is_on_floor(), "the fixture actor is airborne when the window opens")
	buffer.physics_tick(0.001)
	t.assert_true(not buffer.has_pending(), "an intent that fails when eligible is dropped, not retried")
	t.assert_true(not actor.dodge.is_active(), "the failed cancel started no dodge")
	actor.combat.abort_attack()

	# Death clears the buffer so nothing fires on the next life.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the death fixture starts an attack")
	buffer.submit_attack(39, 1.0)
	t.assert_true(buffer.has_pending(), "an intent is pending before death")
	actor._on_died(DamageContext.new(999.0, &"test", actor, &"environment"))
	t.assert_true(actor.is_death_handled(), "the death fixture resolves")
	t.assert_true(not buffer.has_pending(), "death clears the pending intent")
	t.assert_equal(buffer.submit_attack(40, 1.0), CombatInputBufferComponent.SubmitResult.REJECTED, "a dead actor buffers nothing")

	# Death schedules a real respawn; letting it complete here keeps its deferred
	# world transition from replacing a later fixture's actor mid-test.
	for frame in 80:
		await t.get_tree().physics_frame
	var respawned := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(respawned != null and respawned != actor, "death creates a replacement actor")
	t.assert_true(not respawned.input_buffer.has_pending(), "a respawned actor starts with an empty buffer")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_presentation_timing(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var step := weapon.attack_combo.step(0)
	var buffer := actor.input_buffer
	var attacks: Array[Array] = []
	var dodges: Array[Array] = []
	actor.network_combat.attack_presented.connect(func(_peer_id: int, sequence: int, facing: float) -> void: attacks.append([sequence, facing]))
	actor.network_dodge.dodge_presented.connect(func(_peer_id: int, sequence: int, direction: float) -> void: dodges.append([sequence, direction]))

	# Immediate execution still announces exactly once.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.network_combat._server_execute_attack(actor.peer_id, 50).success, "an IDLE attack command is accepted")
	t.assert_equal(attacks.size(), 1, "an immediate attack is presented exactly once")
	t.assert_equal(attacks[0][0], 50, "the presentation carries the command's sequence")

	# A buffered intent announces nothing until it actually runs.
	attacks.clear()
	t.assert_true(actor.network_combat._server_execute_attack(actor.peer_id, 51).success, "an attack command during the wind-up is accepted")
	t.assert_true(attacks.is_empty(), "a buffered attack is not presented on receipt")
	actor.combat.physics_tick(step.startup_seconds + step.active_seconds)
	_advance_to_chain_window(actor, step)
	buffer.physics_tick(0.001)
	t.assert_equal(attacks.size(), 1, "the buffered attack is presented exactly once, when it runs")
	t.assert_equal(attacks[0][0], 51, "the buffered presentation keeps the original command sequence")
	actor.combat.abort_attack()

	# A replaced intent never happened, so it is never presented.
	await _settle(t, actor)
	attacks.clear()
	dodges.clear()
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the replacement fixture starts an attack")
	t.assert_true(actor.network_combat._server_execute_attack(actor.peer_id, 52).success, "the replaced attack command is accepted")
	t.assert_true(actor.network_dodge._server_execute_dodge(actor.peer_id, 53, 1.0).success, "the replacing dodge command is accepted")
	actor.combat.physics_tick(step.recovery_start_seconds() + 0.001)
	buffer.physics_tick(0.001)
	t.assert_true(attacks.is_empty(), "the replaced attack is never presented")
	t.assert_equal(dodges.size(), 1, "the replacing dodge is presented exactly once")
	t.assert_equal(dodges[0][0], 53, "the dodge presentation keeps its own sequence")
	actor.dodge.reset()

	# A consumed sequence stays consumed even though the intent only waited.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the replay fixture starts an attack")
	t.assert_true(actor.network_combat._server_execute_attack(actor.peer_id, 60).success, "the replay fixture buffers an attack")
	t.assert_true(not actor.network_combat._server_execute_attack(actor.peer_id, 60).success, "a buffered sequence cannot be replayed")
	t.assert_true(not actor.network_combat._server_execute_attack(actor.peer_id, 59).success, "a stale sequence is still rejected")
	t.assert_true(actor.network_combat._server_execute_attack(actor.peer_id, 61).success, "a newer sequence replaces the buffered intent")
	t.assert_equal(buffer.pending_sequence(), 61, "the buffer holds the newest sequence")
	buffer.clear()
	actor.combat.abort_attack()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

## Mirrors PlayerActor's authoritative order exactly. Combat must advance before
## the buffer is asked, so an intent whose window opens this frame runs this
## frame instead of next.
func _authoritative_combat_tick(actor: PlayerActor, delta: float) -> void:
	actor.hurt.physics_tick(delta)
	actor.dodge.physics_tick(delta)
	actor.combat.physics_tick(delta)
	actor.input_buffer.physics_tick(delta)

## The same tick with combat and the buffer swapped, used only to show what the
## ordering above buys: the follow-up slips a frame.
func _reversed_combat_tick(actor: PlayerActor, delta: float) -> void:
	actor.hurt.physics_tick(delta)
	actor.dodge.physics_tick(delta)
	actor.input_buffer.physics_tick(delta)
	actor.combat.physics_tick(delta)

func _test_authoritative_clock(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var step := weapon.attack_combo.step(0)
	var buffer := actor.input_buffer
	var frame := 0.016

	# The attack timeline has exactly one owner, and it is not the render frame.
	var script_methods: Array = actor.combat.get_script().get_script_method_list()
	var declared: Array[String] = []
	for method: Dictionary in script_methods:
		declared.append(String(method.get("name", "")))
	t.assert_true(not declared.has("_process"), "CombatComponent declares no _process; the attack timeline has one clock")
	t.assert_true(declared.has("physics_tick"), "CombatComponent advances from an explicit physics tick")

	# A chain window that opens inside a tick is usable inside that same tick.
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the same-frame chain fixture starts an attack")
	_advance_to_elapsed(actor, step.chain_window.start_seconds - 0.001)
	t.assert_true(not actor.combat.can_chain_attack_now(), "the fixture sits just before the chain window")
	t.assert_equal(buffer.submit_attack(80, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "the same-frame fixture buffers an attack")
	_authoritative_combat_tick(actor, frame)
	t.assert_equal(actor.combat.combo_index(), 1, "a window that opens this tick is used this tick")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_STARTUP, "the same-frame chain entered the next step")
	t.assert_true(not buffer.has_pending(), "the same-frame chain consumed the intent")
	actor.combat.abort_attack()

	# Asking the buffer before the timeline moves costs a frame — this is the
	# drift the unified clock exists to remove.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the reversed-order fixture starts an attack")
	_advance_to_elapsed(actor, step.chain_window.start_seconds - 0.001)
	buffer.submit_attack(81, 1.0)
	_reversed_combat_tick(actor, frame)
	t.assert_equal(actor.combat.combo_index(), 0, "asking the buffer first misses the window by a frame")
	t.assert_true(buffer.has_pending(), "the missed intent is still waiting")
	_authoritative_combat_tick(actor, frame)
	t.assert_equal(actor.combat.combo_index(), 1, "it lands on the following tick instead")
	actor.combat.abort_attack()

	# The same holds for a dodge cancel: the window opens as recovery begins.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the same-frame cancel fixture starts an attack")
	_advance_to_elapsed(actor, step.dodge_cancel_window.start_seconds - 0.001)
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_ACTIVE, "the cancel fixture is still committed to the swing")
	t.assert_equal(buffer.submit_dodge(82, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "the cancel fixture buffers a dodge")
	var transitions: Array[Array] = []
	actor.combat_action.state_changed.connect(func(previous: int, current: int) -> void: transitions.append([previous, current]))
	_authoritative_combat_tick(actor, frame)
	t.assert_true(actor.dodge.is_active(), "a dodge cancel window that opens this tick is used this tick")
	t.assert_equal(transitions[transitions.size() - 1], [CombatActionController.State.ATTACK_RECOVERY, CombatActionController.State.DODGE], "the same-frame cancel still goes straight from recovery into DODGE")
	actor.dodge.reset()

	# Expiry is checked before eligibility, so the boundary is decided by the
	# clock rather than by which callback happened to run first.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the expiry-boundary fixture starts an attack")
	_advance_to_elapsed(actor, step.chain_window.start_seconds - 0.001)
	buffer.submit_attack(83, 1.0)
	# Set directly: the point of the case is the exact remaining time at the tick
	# where the window opens, which no public call can land on precisely.
	buffer._remaining = 0.020
	_authoritative_combat_tick(actor, frame)
	t.assert_equal(actor.combat.combo_index(), 1, "an intent with time left survives the tick that opens its window")
	actor.combat.abort_attack()

	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the expired-boundary fixture starts an attack")
	_advance_to_elapsed(actor, step.chain_window.start_seconds - 0.001)
	buffer.submit_attack(84, 1.0)
	buffer._remaining = 0.010
	_authoritative_combat_tick(actor, frame)
	t.assert_true(not buffer.has_pending(), "an intent that runs out during the tick expires")
	t.assert_equal(actor.combat.combo_index(), 0, "an expired intent does not chain even though the window opened")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the original step keeps running")
	actor.combat.abort_attack()

	# Finally the real thing: no hand-driven ticks, just the actor's own physics.
	await _settle(t, actor)
	runtime.combat.stamina = runtime.combat.max_stamina
	t.assert_true(actor.combat.attack(1.0), "the physics-frame fixture starts an attack")
	var guard := 0
	while actor.combat.attack_elapsed() < step.recovery_start_seconds() and guard < 120:
		await t.get_tree().physics_frame
		guard += 1
	t.assert_true(actor.combat.attack_elapsed() >= step.recovery_start_seconds(), "real physics frames advance the attack timeline")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "real physics frames reach recovery")
	t.assert_equal(buffer.submit_attack(85, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED, "the physics-frame fixture buffers an attack before the window")
	guard = 0
	while actor.combat.combo_index() == 0 and guard < 30:
		await t.get_tree().physics_frame
		guard += 1
	t.assert_equal(actor.combat.combo_index(), 1, "the buffered intent chains on the actor's own physics timeline")
	t.assert_true(not buffer.has_pending(), "the physics-frame chain consumed the intent")
	actor.combat.abort_attack()

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

func _test_full_combo_hits(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn(t, layer)
	var runtime := GameSession.get_player_runtime(actor.peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	var combo := weapon.attack_combo
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.facing = 1.0

	var definition := ContentRegistry.get_definition(&"sewer_beetle") as EnemyDefinition
	var enemy := definition.actor_scene.instantiate() as EnemyAgent
	enemy.setup_enemy(definition, 8001, true, actor.world_id)
	actor.get_parent().add_child(enemy)
	await t.get_tree().process_frame
	enemy.set_physics_process(false)
	enemy.global_position = actor.global_position + Vector2(26.0, 0.0)
	enemy.health.max_health = 1000.0
	enemy.health.current_health = 1000.0
	enemy.health.invulnerability_seconds = 0.0
	await t.get_tree().physics_frame

	# Re-freeze regeneration after the awaited spawn frames: a survival stage
	# change during them puts the multiplier back, and _process regenerates on
	# every driven tick.
	actor.combat.stamina_regen_multiplier = 0.0
	runtime.combat.stamina = runtime.combat.max_stamina
	var start_stamina := runtime.combat.stamina
	var health_before := enemy.health.current_health
	t.assert_true(actor.combat.attack(1.0), "the full-combo fixture starts its first step")
	for index in 3:
		var step := combo.step(index)
		enemy.global_position = actor.global_position + step.hitbox_offset
		var step_health := enemy.health.current_health
		actor.combat.physics_tick(step.startup_seconds)
		t.assert_true(enemy.health.current_health < step_health, "step %d lands a hit" % index)
		var after_first_hit := enemy.health.current_health
		actor.combat.physics_tick(step.active_seconds * 0.5)
		t.assert_equal(enemy.health.current_health, after_first_hit, "step %d hits the same target only once" % index)
		actor.combat.physics_tick(step.active_seconds * 0.5)
		if index == 2:
			break
		_advance_to_chain_window(actor, step)
		t.assert_true(actor.combat.chain_attack(1.0), "the full-combo fixture chains into step %d" % (index + 1))
	t.assert_true(enemy.health.current_health < health_before, "the whole combo damaged the enemy")
	t.assert_equal(runtime.combat.stamina, start_stamina - weapon.stamina_cost * 3.0, "the whole combo cost three commits")
	actor.combat.abort_attack()

	enemy.queue_free()
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
