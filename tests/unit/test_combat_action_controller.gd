extends RefCounted
## Combat action axis: a state machine independent from locomotion. This stage
## adds the states and transitions only — the legacy attack still resolves
## instantly, so gameplay timing must be unchanged and no new timer may exist.

func run(t: Node) -> void:
	_test_initial_state(t)
	_test_legal_transitions(t)
	_test_illegal_transitions(t)
	_test_signal_policy(t)
	_test_reset(t)
	_test_immediate_attack_bridge(t)
	await _test_actor_integration(t)
	await _test_world_transition_and_respawn(t)

func _controller() -> CombatActionController:
	return CombatActionController.new()

func _test_initial_state(t: Node) -> void:
	var action := _controller()
	t.assert_equal(action.current_state(), CombatActionController.State.IDLE, "a new combat action controller starts idle")
	t.assert_true(action.is_idle() and not action.is_attacking(), "idle helpers agree with the initial state")
	action.free()

func _test_legal_transitions(t: Node) -> void:
	var action := _controller()
	t.assert_true(action.begin_attack(), "IDLE -> ATTACK_STARTUP is allowed")
	t.assert_equal(action.current_state(), CombatActionController.State.ATTACK_STARTUP, "begin_attack enters startup")
	t.assert_true(action.enter_attack_active(), "ATTACK_STARTUP -> ATTACK_ACTIVE is allowed")
	t.assert_true(action.enter_attack_recovery(), "ATTACK_ACTIVE -> ATTACK_RECOVERY is allowed")
	t.assert_true(action.finish_attack(), "ATTACK_RECOVERY -> IDLE is allowed")
	t.assert_true(action.is_idle(), "a full attack cycle returns to idle")

	t.assert_true(action.begin_attack() and action.cancel_attack(), "an attack can be cancelled from startup")
	t.assert_true(action.is_idle(), "cancelling startup returns to idle")
	t.assert_true(action.begin_attack() and action.enter_attack_active() and action.cancel_attack(), "an attack can be cancelled from the active phase")
	t.assert_true(action.is_idle(), "cancelling the active phase returns to idle")
	action.free()

func _test_illegal_transitions(t: Node) -> void:
	var action := _controller()
	var s := CombatActionController.State
	for forbidden in [s.ATTACK_ACTIVE, s.ATTACK_RECOVERY, s.IDLE]:
		t.assert_true(not action.transition_to(forbidden), "IDLE rejects a transition to %d" % forbidden)
		t.assert_true(action.is_idle(), "a rejected transition leaves IDLE untouched")
	t.assert_true(not action.enter_attack_active(), "the active phase cannot be entered without a startup")
	t.assert_true(not action.enter_attack_recovery(), "recovery cannot be entered from idle through the graph")
	t.assert_true(not action.finish_attack(), "finishing is rejected when no attack is running")
	t.assert_true(not action.cancel_attack(), "cancelling is rejected when no attack is running")

	action.begin_attack()
	t.assert_true(not action.transition_to(s.ATTACK_RECOVERY), "startup cannot skip the active phase")
	t.assert_equal(action.current_state(), s.ATTACK_STARTUP, "a rejected skip leaves startup untouched")
	action.enter_attack_active()
	t.assert_true(not action.transition_to(s.ATTACK_STARTUP), "the active phase cannot return to startup")
	t.assert_equal(action.current_state(), s.ATTACK_ACTIVE, "a rejected backwards transition leaves the state untouched")
	action.enter_attack_recovery()
	t.assert_true(not action.transition_to(s.ATTACK_ACTIVE), "recovery cannot re-enter the active phase")
	t.assert_true(not action.transition_to(s.ATTACK_STARTUP), "recovery cannot restart an attack directly")
	t.assert_equal(action.current_state(), s.ATTACK_RECOVERY, "recovery survives rejected transitions")

	t.assert_true(not CombatActionController.is_allowed_transition(s.IDLE, s.ATTACK_ACTIVE), "the transition table forbids IDLE -> ACTIVE")
	t.assert_true(not CombatActionController.is_allowed_transition(s.IDLE, s.ATTACK_RECOVERY), "the transition table forbids IDLE -> RECOVERY")
	t.assert_true(CombatActionController.is_allowed_transition(s.IDLE, s.ATTACK_STARTUP), "the transition table allows IDLE -> STARTUP")
	action.free()

func _test_signal_policy(t: Node) -> void:
	var action := _controller()
	var events: Array[Array] = []
	var callback := func(previous: int, current: int) -> void: events.append([previous, current])
	action.state_changed.connect(callback)

	action.begin_attack()
	t.assert_equal(events.size(), 1, "an accepted transition emits one state change")
	t.assert_equal(events[0], [CombatActionController.State.IDLE, CombatActionController.State.ATTACK_STARTUP], "the signal carries previous and current states")
	action.begin_attack()
	t.assert_equal(events.size(), 1, "re-requesting the current state emits nothing")
	action.transition_to(CombatActionController.State.ATTACK_RECOVERY)
	t.assert_equal(events.size(), 1, "a rejected transition emits nothing")
	action.enter_attack_active()
	action.enter_attack_recovery()
	action.finish_attack()
	t.assert_equal(events.size(), 4, "each real change emits exactly once")
	action.state_changed.disconnect(callback)
	action.free()

func _test_reset(t: Node) -> void:
	var action := _controller()
	var events: Array[int] = []
	var callback := func(_previous: int, _current: int) -> void: events.append(1)
	action.state_changed.connect(callback)
	action.reset()
	t.assert_true(action.is_idle() and events.is_empty(), "resetting an idle controller changes nothing and stays silent")
	action.begin_attack()
	action.enter_attack_active()
	action.reset()
	t.assert_true(action.is_idle(), "reset returns to idle from any state")
	t.assert_equal(events.size(), 3, "reset emits one change when it actually moved the state")
	action.state_changed.disconnect(callback)
	action.free()

func _test_immediate_attack_bridge(t: Node) -> void:
	var action := _controller()
	t.assert_true(action.enter_recovery_from_immediate_attack(), "the legacy immediate attack reaches recovery")
	t.assert_equal(action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the bridge lands in recovery")
	t.assert_true(not action.enter_recovery_from_immediate_attack(), "the bridge only applies from idle")
	t.assert_true(action.finish_attack(), "the bridge still leaves recovery through the normal edge")
	action.begin_attack()
	t.assert_true(not action.enter_recovery_from_immediate_attack(), "the bridge cannot skip an attack already in progress")
	t.assert_equal(action.current_state(), CombatActionController.State.ATTACK_STARTUP, "a rejected bridge leaves the state untouched")
	action.free()

func _spawn_settlement_player(t: Node, layer: Node) -> PlayerActor:
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "combat action fixture loads the settlement")
	await t.get_tree().process_frame
	return t.get_tree().get_first_node_in_group(&"player") as PlayerActor

func _test_actor_integration(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var peer_id := GameSession.get_local_peer_id()
	var runtime := GameSession.get_player_runtime(peer_id)
	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	t.assert_true(actor != null and actor.combat_action != null, "the player actor owns a combat action controller")
	t.assert_true(actor.combat.action == actor.combat_action, "CombatComponent is wired to the actor's controller")
	t.assert_true(actor.combat_action.is_idle(), "a fresh actor starts idle")
	t.assert_true(MovementComponent.Mode.keys().size() == 3 \
		and MovementComponent.Mode.keys().has("GROUND") and MovementComponent.Mode.keys().has("AIR") \
		and MovementComponent.Mode.keys().has("CLIMB"), "MovementComponent.Mode stays locomotion-only")

	# A successful legacy attack commits the action state; startup and active are
	# not faked because the attack still resolves instantly.
	var events: Array[Array] = []
	var callback := func(previous: int, current: int) -> void: events.append([previous, current])
	actor.combat_action.state_changed.connect(callback)
	var stamina_before := runtime.combat.stamina
	t.assert_true(actor.combat.attack(1.0), "a legacy attack still succeeds")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "a successful attack enters recovery")
	t.assert_equal(events.size(), 1, "the legacy attack emits a single action change, not a faked phase walk")
	t.assert_equal(actor.combat.cooldown_remaining, weapon.attack_cooldown, "the weapon cooldown is unchanged by the action axis")
	t.assert_equal(runtime.combat.stamina, stamina_before - weapon.stamina_cost, "stamina ownership is unchanged")

	# Re-attacking during recovery is rejected without touching anything.
	var stamina_in_recovery := runtime.combat.stamina
	var cooldown_in_recovery := actor.combat.cooldown_remaining
	var armed_before := actor.combat.hitbox.remaining
	t.assert_true(not actor.combat.attack(1.0), "a second attack during recovery is rejected")
	t.assert_equal(runtime.combat.stamina, stamina_in_recovery, "a rejected re-attack spends no stamina")
	t.assert_equal(actor.combat.cooldown_remaining, cooldown_in_recovery, "a rejected re-attack does not extend the cooldown")
	t.assert_equal(actor.combat.hitbox.remaining, armed_before, "a rejected re-attack arms no hitbox")
	t.assert_equal(events.size(), 1, "a rejected re-attack emits no action change")

	# The existing cooldown is the recovery window; no second timer was added.
	actor.combat._process(weapon.attack_cooldown + 0.01)
	t.assert_equal(actor.combat.cooldown_remaining, 0.0, "the cooldown elapses as before")
	t.assert_true(actor.combat_action.is_idle(), "the action returns to idle when the cooldown ends")
	t.assert_equal(events.size(), 2, "returning to idle emits exactly one more change")
	actor.combat._process(1.0)
	t.assert_equal(events.size(), 2, "an already-idle controller is not re-notified every frame")
	actor.combat_action.state_changed.disconnect(callback)

	# Every rejection path must leave the action axis at IDLE.
	t.assert_true(actor.combat_action.is_idle(), "the action axis is idle before the rejection cases")
	runtime.combat.stamina = weapon.stamina_cost - 0.5
	t.assert_true(not actor.combat.attack(1.0) and actor.combat_action.is_idle(), "an attack rejected for stamina leaves the action idle")
	runtime.combat.stamina = runtime.combat.max_stamina
	actor.combat.cooldown_remaining = 1.0
	t.assert_true(not actor.combat.attack(1.0) and actor.combat_action.is_idle(), "an attack rejected by cooldown leaves the action idle")
	actor.combat.cooldown_remaining = 0.0
	actor.return_channel = 0.5
	t.assert_true(not actor.combat.attack(1.0) and actor.combat_action.is_idle(), "an attack rejected during return channelling leaves the action idle")
	actor.return_channel = 0.0
	var equipped := GameSession.player.equipment.unequip(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
	t.assert_true(not actor.combat.attack(1.0) and actor.combat_action.is_idle(), "an attack without a weapon leaves the action idle")
	GameSession.player.equipment.equip(equipped)

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_world_transition_and_respawn(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	var actor: PlayerActor = await _spawn_settlement_player(t, layer)
	var peer_id := GameSession.get_local_peer_id()
	var runtime := GameSession.get_player_runtime(peer_id)
	t.assert_true(actor.combat.attack(1.0), "the fixture lands one attack before transitioning")
	t.assert_equal(actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the actor is mid-recovery before the transition")
	var previous_action := actor.combat_action
	var stamina_before := runtime.combat.stamina

	var context: AdventureContext = GameSession.request_adventure_from_exit(&"sewer_gate", &"sewer_region")
	t.assert_true(SceneRouter.go_to_adventure(context), "the fixture enters the sewer")
	await t.get_tree().process_frame
	var adventure_actor := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(adventure_actor != actor, "the world transition creates a new actor")
	t.assert_true(adventure_actor.combat_action.is_idle(), "an attack does not survive a world transition")
	t.assert_true(adventure_actor.combat_action != previous_action, "the action axis is scene-local, not shared")
	t.assert_true(runtime.combat.stamina >= stamina_before, "stamina still survives a world transition without death")
	t.assert_true(adventure_actor.combat.combat_runtime == runtime.combat, "the new actor keeps the same runtime stamina state")

	t.assert_true(adventure_actor.combat.attack(1.0), "the new actor can attack")
	t.assert_equal(adventure_actor.combat_action.current_state(), CombatActionController.State.ATTACK_RECOVERY, "the new actor enters recovery")
	# Drive the real actor death path so the actor-level cleanup is exercised.
	var life := GameSession.get_player_life_id(peer_id)
	adventure_actor._on_died(DamageContext.new(999.0, &"test", adventure_actor, &"environment"))
	t.assert_true(GameSession.get_player_death_result(peer_id) != null, "death resolves for the respawn fixture")
	t.assert_true(adventure_actor.combat_action.is_idle(), "death clears a pending attack recovery")
	t.assert_true(GameSession.get_player_life_id(peer_id) == life, "death does not arm a new life by itself")
	t.assert_true(SceneRouter.go_to_settlement(), "respawn returns to the settlement")
	await t.get_tree().process_frame
	var respawned := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	t.assert_true(respawned != null and respawned.combat_action.is_idle(), "a respawned actor starts idle")
	t.assert_equal(runtime.combat.stamina, runtime.combat.max_stamina, "the respawn stamina policy is unchanged")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
