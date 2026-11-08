extends RefCounted

const ACTIONS := [&"jump", &"primary_attack", &"dodge", &"interact", &"use_quick_item"]
const SHORTCUTS := [&"open_inventory", &"open_equipment", &"pause"]

func run(t: Node) -> void:
	await _test_owners(t)
	_test_local_input(t)
	await _test_host_and_remote(t)

func _test_owners(t: Node) -> void:
	var owner_a := Node.new()
	var owner_b := Node.new()
	var unrelated := RefCounted.new()
	var changes: Array[bool] = []
	var record := func(blocked: bool) -> void: changes.append(blocked)
	LocalInputContext.gameplay_input_blocked_changed.connect(record)
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "no owners leaves input allowed")
	LocalInputContext.acquire(owner_a)
	t.assert_true(LocalInputContext.is_gameplay_blocked(), "first owner blocks input")
	LocalInputContext.acquire(owner_a)
	LocalInputContext.release(unrelated)
	t.assert_equal(changes, [true], "duplicate acquisition and unknown release emit nothing")
	LocalInputContext.acquire(owner_b)
	LocalInputContext.release(owner_a)
	t.assert_true(LocalInputContext.is_gameplay_blocked(), "second owner maintains the block after first release")
	t.assert_equal(changes, [true], "only aggregate state changes emit a signal")
	LocalInputContext.release(owner_b)
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "last owner release allows input")
	t.assert_equal(changes, [true, false], "last owner emits exactly one unblock")

	t.add_child(owner_a)
	LocalInputContext.acquire(owner_a)
	owner_a.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	t.assert_equal(changes, [true, false, true, false], "deleted owner is pruned and emits without a query")
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "freed Node cannot hold input blocked")

	var transient := RefCounted.new()
	LocalInputContext.acquire(transient)
	transient = null
	t.assert_true(not LocalInputContext.is_gameplay_blocked(), "query prunes a deleted non-Node owner")
	t.assert_equal(changes, [true, false, true, false, true, false], "weak owner cleanup emits once")
	LocalInputContext.gameplay_input_blocked_changed.disconnect(record)
	owner_b.free()

func _test_local_input(t: Node) -> void:
	var owner := RefCounted.new()
	var local := PlayerInputComponent.new()
	t.add_child(local)
	var seen: Array[StringName] = []
	local.jump_requested.connect(func() -> void: seen.append(&"jump"))
	local.attack_requested.connect(func() -> void: seen.append(&"primary_attack"))
	local.dodge_requested.connect(func(_axis: float) -> void: seen.append(&"dodge"))
	local.interact_requested.connect(func() -> void: seen.append(&"interact"))
	local.quick_item_requested.connect(func() -> void: seen.append(&"use_quick_item"))
	local.inventory_requested.connect(func() -> void: seen.append(&"open_inventory"))
	local.equipment_requested.connect(func() -> void: seen.append(&"open_equipment"))
	local.pause_requested.connect(func() -> void: seen.append(&"pause"))

	Input.action_press(&"move_right")
	Input.action_press(&"move_up")
	local._process(0.0)
	_send(local, ACTIONS)
	t.assert_equal(local.move_vector, Vector2(1, -1), "unblocked local input samples both movement axes")
	t.assert_equal(seen, ACTIONS, "unblocked local input emits all gameplay edges")
	LocalInputContext.acquire(owner)
	t.assert_equal(local.move_vector, Vector2.ZERO, "acquire immediately clears axes before another process tick")
	t.assert_true(not local.take_jump_pressed(), "acquire clears a jump waiting for the network tick")
	seen.clear()
	for action in ACTIONS:
		Input.action_press(action)
	_send(local, ACTIONS)
	local._process(0.0)
	t.assert_equal(local.move_vector, Vector2.ZERO, "blocked polling ignores held movement")
	t.assert_true(seen.is_empty() and not local.take_jump_pressed(), "blocked gameplay emits no signal and queues no jump")
	local.gameplay_actions_enabled = false
	local.network_intents_enabled = true
	_send(local, ACTIONS)
	t.assert_true(seen.is_empty() and not local.take_jump_pressed(), "blocked Client cannot emit intents")
	_send(local, SHORTCUTS)
	t.assert_equal(seen, SHORTCUTS, "inventory, equipment and pause shortcuts still dispatch")

	seen.clear()
	LocalInputContext.release(owner)
	local._process(0.0)
	_send(local, ACTIONS)
	t.assert_equal(local.move_vector, Vector2.ZERO, "held movement stays neutral after closing the UI")
	t.assert_true(seen.is_empty() and not local.take_jump_pressed(), "held actions do not replay on close")
	Input.action_press(&"move_left")
	local._process(0.0)
	t.assert_equal(local.move_axis, -1.0, "a fresh opposite movement key works while the old direction is still held")
	Input.action_release(&"move_left")
	for action in ACTIONS + [&"move_right", &"move_up"]:
		Input.action_release(action)
	# A release observed before the GUI consumes it allows a new press in the same frame.
	var release := InputEventAction.new()
	release.action = &"jump"
	local._input(release)
	Input.action_press(&"move_right")
	local._process(0.0)
	t.assert_equal(local.move_vector, Vector2.RIGHT, "release and new press rearm movement")
	_send(local, ACTIONS)
	t.assert_equal(seen, ACTIONS.slice(1), "Client re-emits fresh combat, interact and quick-item intents")
	t.assert_true(local.take_jump_pressed(), "fresh Client jump is queued for the move command")
	Input.action_release(&"move_right")
	local.free()

func _test_host_and_remote(t: Node) -> void:
	NetworkManager.leave_game()
	var port := 29000 + randi_range(0, 1000)
	t.assert_equal(NetworkManager.host_game(port, 2), OK, "input fixture opens a real local host")
	t.assert_true(GameSession.start_new_game(), "input fixture starts a session")
	var remote_id := &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	NetworkManager.players[42] = NetworkPlayerInfo.new(42, remote_id, "B", true)
	NetworkManager.peer_to_player[42] = remote_id
	NetworkManager.player_to_peer[remote_id] = 42
	t.assert_true(GameSession.attach_player(42, remote_id) != null, "fixture attaches a remote PlayerState")
	var worlds := ServerWorldRoot.new()
	t.add_child(worlds)
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	var settlement := worlds.runtime(&"settlement")
	var host := settlement.player_manager().get_actor(1) if settlement != null else null
	var remote := settlement.player_manager().get_actor(42) if settlement != null else null
	t.assert_true(host != null and remote != null, "authoritative runtime has host and remote PlayerActors")
	if host != null and remote != null:
		t.assert_true(not host.input.local_input_enabled and not remote.input.local_input_enabled, "authority receivers do not poll the keyboard")
		host.input.apply_move_command(PlayerMoveCommand.new(1, 1.0, -1.0, false))
		remote.input.apply_move_command(PlayerMoveCommand.new(1, -1.0, 1.0, false))
		for actor in [host, remote]:
			t.assert_true(actor.combat_action.begin_attack(), "actor starts an attack before the block")
			t.assert_equal(actor.input_buffer.submit_attack(2, 1.0), CombatInputBufferComponent.SubmitResult.BUFFERED,
				"actor has a follow-up queued before the block")
		var owner := RefCounted.new()
		LocalInputContext.acquire(owner)
		t.assert_equal(host.input.move_vector, Vector2.ZERO, "the Host authority clears its old local movement")
		t.assert_true(not host.input_buffer.has_pending() and host.combat_action.is_attacking(),
			"blocking drops the Host's pending follow-up while keeping its active attack")
		t.assert_equal(remote.input.move_vector, Vector2(-1, 1), "host UI does not erase remote movement")
		t.assert_true(remote.input_buffer.has_pending() and remote.combat_action.is_attacking(),
			"host UI does not clear the remote attack or follow-up")
		var received_jumps := [0, 0]
		host.input.jump_requested.connect(func() -> void: received_jumps[0] += 1)
		remote.input.jump_requested.connect(func() -> void: received_jumps[1] += 1)
		host.input.apply_move_command(PlayerMoveCommand.new(2, 1.0, 0.0, true))
		remote.input.apply_move_command(PlayerMoveCommand.new(2, 1.0, 0.0, true))
		t.assert_equal(host.input.move_vector, Vector2.ZERO, "blocked Host command receiver stays neutral")
		t.assert_equal(remote.input.move_vector, Vector2.RIGHT, "remote move commands still apply while the Host is blocked")
		t.assert_equal(received_jumps, [0, 1], "remote jump is still delivered and the Host jump is blocked")
		LocalInputContext.release(owner)
		host.input.apply_move_command(PlayerMoveCommand.new(3, 1.0, 0.0, true))
		t.assert_equal(received_jumps, [1, 1], "Host command receiver resumes on release")
	worlds.queue_free()
	await t.get_tree().process_frame
	NetworkManager.leave_game()

func _send(target: PlayerInputComponent, actions: Array) -> void:
	for action in actions:
		var event := InputEventAction.new()
		event.action = action
		event.pressed = true
		target._unhandled_input(event)
