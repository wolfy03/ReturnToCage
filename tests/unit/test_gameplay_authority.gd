extends RefCounted

const B: StringName = &"player_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const C: StringName = &"player_cccccccccccccccccccccccccccccccc"
const SEWER: StringName = &"adventure:sewer_region"
var root: ServerWorldRoot

func run(t: Node) -> void:
	await _entry_distance(t)
	await _escape_authorization(t)
	await _return_spawn(t)
	await _channel_and_failure(t)
	await _preflight_and_spawn_failures(t)
	await _respawn_ignores_retiring_actor(t)
	await _channel_rejections_and_cleanup(t)

func _setup(t: Node, adventure: bool = false) -> void:
	NetworkManager.leave_game()
	t.assert_equal(NetworkManager.host_game(31000 + randi_range(0, 4000), 3), OK, "authority fixture hosts")
	t.assert_true(GameSession.start_new_game(), "authority fixture starts")
	root = ServerWorldRoot.new()
	t.add_child(root)
	await t.get_tree().process_frame
	NetworkManager.players[42] = NetworkPlayerInfo.new(42, B, "B", true)
	NetworkManager._set_identity(42, B)
	GameSession.attach_player(42, B)
	if adventure:
		GameSession.begin_player_adventure(42, &"sewer_gate", &"sewer_region")
	root.reconcile()
	await t.get_tree().physics_frame
	await t.get_tree().process_frame
	NetworkManager.mark_peer_world_ready(1)
	NetworkManager.mark_peer_world_ready(42)
	# This unit fixture has no ENet socket for synthetic attachment 42. The
	# process probe separately exercises real snapshot and presentation traffic.
	NetworkManager._replication_ready_after_msec[42] = Time.get_ticks_msec() + 60000
	if adventure:
		for enemy_id in root.runtime(SEWER).enemy_manager()._enemies:
			var enemy := root.runtime(SEWER).enemy_manager().get_enemy(enemy_id)
			enemy.set_physics_process(false)
			enemy.get_node("NetworkEnemy").set_process(false)

func _cleanup(t: Node) -> void:
	NetworkManager._local_peer_id = 1
	root.get_parent().remove_child(root)
	root.queue_free()
	await t.get_tree().process_frame
	NetworkManager.leave_game()

func _snapshot() -> Dictionary:
	var session := GameSession.adventure_session_for_peer(42)
	var personal := session.get_player_adventure(42) if session != null else null
	return {
		"world": [GameSession.get_peer_world_id(42), GameSession.get_peer_world(42).revision],
		"player": GameSession.get_player(42).to_save_dict(),
		"storage": GameSession.settlement.to_save_dict(),
		"participation": personal,
		"loot": personal.unsecured_loot.to_array() if personal != null else [],
		"spawn": NetworkManager.spawn_assignment_for_peer(42),
		"ready": NetworkManager.is_peer_world_ready(42),
		"pending": NetworkManager._pending_world_transitions.get(42),
	}

func _entry_distance(t: Node) -> void:
	await _setup(t)
	var actor := root.runtime(&"settlement").player_manager().get_actor(42)
	actor.position = Vector2(150, 510)
	var before := _snapshot()
	var result := NetworkManager._begin_player_world_transition(42, &"sewer_gate", &"sewer_region")
	t.assert_true(not result.success, "far Settlement exit request must fail")
	t.assert_equal(_snapshot(), before, "far exit preserves all canonical and transition state")
	actor.position = Vector2(865, 510)
	t.assert_true(not NetworkManager._begin_player_world_transition(42, &"bad_exit", &"sewer_region").success, "invalid exit fails")
	t.assert_true(not NetworkManager._begin_player_world_transition(42, &"field_gate", &"field_region").success, "locked destination fails")
	t.assert_true(NetworkManager._begin_player_world_transition(42, &"sewer_gate", &"sewer_region").success, "near authored Settlement exit succeeds")
	before = _snapshot()
	t.assert_true(not NetworkManager._begin_player_world_transition(42, &"sewer_gate", &"sewer_region").success, "pending transition rejects repeated entry")
	t.assert_equal(_snapshot(), before, "pending rejection preserves committed assignment")
	await _cleanup(t)

func _escape_authorization(t: Node) -> void:
	await _setup(t, true)
	var actor := root.runtime(SEWER).player_manager().get_actor(42)
	actor.position = Vector2(700, 510)
	var before := _snapshot()
	var result := NetworkManager._return_player_to_settlement(42, AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(not result.success, "forged normal escape far from geometry must fail")
	t.assert_equal(_snapshot(), before, "forged normal escape preserves all state")
	t.assert_true(not NetworkManager._escape_at_point(42, &"bad_escape").success, "invalid escape id fails")
	actor.position = Vector2(1370, 230)
	t.assert_true(not NetworkManager._escape_at_point(42, &"sewer_ladder").success, "requires_landing condition retained")
	t.assert_equal(_snapshot(), before, "invalid point and landing rejection preserve state")
	await _cleanup(t)
	await _setup(t, true)
	before = _snapshot()
	result = NetworkManager._return_player_to_settlement(42, AdventureSession.Result.RETURN_ITEM_ESCAPE)
	t.assert_true(not result.success, "return result without completed server channel must fail")
	t.assert_equal(_snapshot(), before, "forged return-item result preserves all state")
	await _cleanup(t)

func _return_spawn(t: Node) -> void:
	await _setup(t, true)
	var actor := root.runtime(SEWER).player_manager().get_actor(42)
	actor.position = Vector2(70, 510)
	GameSession.get_player(42).last_safe_position = Vector2(99000, 510)
	var result := NetworkManager._return_player_to_settlement(42, AdventureSession.Result.NORMAL_ESCAPE)
	t.assert_true(result.success, "invalid safe position uses configured validated fallback")
	var spawn := NetworkManager.spawn_assignment_for_peer(42)
	t.assert_true(spawn != null and spawn.fallback_used, "finite out-of-bounds return position is rejected")
	t.assert_true(GameSession.get_player(42).last_safe_position.x < 1400, "return heals canonical safe position")
	await _cleanup(t)

func _channel_and_failure(t: Node) -> void:
	await _setup(t, true)
	var actor := root.runtime(SEWER).player_manager().get_actor(42)
	actor.position = Vector2(300, 510)
	if not NetworkManager.has_method("_start_return_item"):
		t.assert_true(false, "remote return-item intent must have a server handler")
		await _cleanup(t)
		return
	var inventory := GameSession.get_player(42).inventory
	var count := inventory.count(&"return_seed")
	var start: CommandResult = NetworkManager.call("_start_return_item", 42)
	t.assert_true(start.success and actor.return_channel > 0.0 and not actor.movement.enabled, "server starts and locks return channel")
	t.assert_true(not NetworkManager.call("_start_return_item", 42).success, "duplicate channel intent rejected")
	actor.input.move_axis = 1.0
	actor._physics_process(0.01)
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "movement cancels authoritative channel")
	t.assert_equal(inventory.count(&"return_seed"), count, "cancel consumes no item")
	actor.input.move_axis = 0.0
	NetworkManager.call("_start_return_item", 42)
	var damage := DamageContext.new(1.0)
	damage.causes_hurt = false
	actor._on_damaged(damage)
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "damage cancels channel")
	actor.hurt.reset()
	actor.position = Vector2(300, 510)
	NetworkManager.call("_start_return_item", 42)
	var manager := root.runtime(&"settlement").player_manager()
	manager.spawn_validation_collision_mask = 0
	var before := _snapshot()
	actor.return_channel = actor.return_channel_required
	actor._complete_return_channel()
	t.assert_equal(_snapshot(), before, "failed return preflight preserves inventory/world/loot/storage/spawn/readiness")
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "failed completion clears channel and unlocks")
	manager.spawn_validation_collision_mask = 1
	NetworkManager.call("_start_return_item", 42)
	actor.return_channel = actor.return_channel_required
	actor._complete_return_channel()
	t.assert_equal(inventory.count(&"return_seed"), count - 1, "successful return consumes exactly one item")
	t.assert_equal(GameSession.get_peer_world_id(42), &"settlement", "completed server channel returns its owner")
	await _cleanup(t)

func _preflight_and_spawn_failures(t: Node) -> void:
	await _setup(t)
	var actor := root.runtime(&"settlement").player_manager().get_actor(42)
	actor.position = Vector2(865, 510)
	var definition := ContentRegistry.get_definition(&"sewer_region") as RegionDefinition
	var broken := definition.duplicate() as RegionDefinition
	broken.scene_path = "res://missing-destination.tscn"
	ContentRegistry._definitions[definition.id] = broken
	var before := _snapshot()
	var failed := NetworkManager._begin_player_world_transition(42, &"sewer_gate", definition.id)
	t.assert_true(not failed.success, "destination runtime failure rejects transition")
	t.assert_equal(_snapshot(), before, "destination failure preserves all canonical state")
	t.assert_true(root.runtime(SEWER) == null and root.runtime_count() == 1, "preflight failure leaves no ghost runtime")
	ContentRegistry._definitions[definition.id] = definition
	await _cleanup(t)
	await _setup(t, true)
	actor = root.runtime(SEWER).player_manager().get_actor(42)
	actor.position = Vector2(70, 510)
	var state := GameSession.get_player(42)
	var manager := root.runtime(&"settlement").player_manager()
	for position in [Vector2(360, 500), Vector2(90000, 500), Vector2(650, 425), Vector2(1500, 20)]:
		state.last_safe_position = position
		var spawn := manager.transition_spawn(42)
		t.assert_true(spawn.error_message.is_empty(), "valid or fallback Settlement spawn resolves")
		t.assert_true(spawn.position == position if position == Vector2(360, 500) else spawn.fallback_used, "bounds/collision/support checked before fallback")
	state.last_safe_position = Vector2(200, 20)
	for marker in manager._spawn_points():
		marker.position = Vector2(30000, 500)
	before = _snapshot()
	failed = NetworkManager._escape_at_point(42, &"sewer_entrance")
	t.assert_true(not failed.success, "all invalid fallback markers reject return")
	t.assert_equal(_snapshot(), before, "failed spawn cannot secure loot or remove participation")
	await _cleanup(t)

func _respawn_ignores_retiring_actor(t: Node) -> void:
	await _setup(t, true)
	var manager := root.runtime(SEWER).player_manager()
	var actor := manager.get_actor(42)
	actor.position = Vector2(150, 520)
	await t.get_tree().physics_frame
	await t.get_tree().process_frame
	NetworkManager.world_ready_peers.erase(42)
	t.assert_true(manager.respawn_player(42), "respawn clearance excludes its own retiring actor")
	t.assert_true(manager.get_actor(42) != actor, "respawn replaces exactly one authoritative actor")
	await _cleanup(t)

func _channel_rejections_and_cleanup(t: Node) -> void:
	await _setup(t, true)
	NetworkManager._local_peer_id = 42 # Synthetic transport: owner events stay local.
	var actor := root.runtime(SEWER).player_manager().get_actor(42)
	var state := GameSession.get_player(42)
	actor.hurt.hurt_triggered.disconnect(actor.network_combat._on_hurt_triggered)
	var inventory := state.inventory
	inventory.remove_item(&"return_seed", inventory.count(&"return_seed"))
	t.assert_true(not NetworkManager._start_return_item(42).success, "no return item rejects channel")
	inventory.add_item(&"return_seed", 1)
	var region := ContentRegistry.get_definition(&"sewer_region") as RegionDefinition
	var restricted := region.duplicate() as RegionDefinition
	restricted.allow_return_item = false
	ContentRegistry._definitions[region.id] = restricted
	t.assert_true(not NetworkManager._start_return_item(42).success, "region return-item prohibition enforced")
	ContentRegistry._definitions[region.id] = region
	actor.position = Vector2(350, 510)
	await t.get_tree().physics_frame
	await t.get_tree().physics_frame
	NetworkManager._start_return_item(42)
	t.assert_true(not NetworkManager.complete_return_item(actor).success, "early channel completion rejected")
	actor.position.x += 10.0
	actor._physics_process(0.01)
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "displacement cancels return")
	NetworkManager._start_return_item(42)
	actor.hurt.begin_hurt()
	actor._physics_process(0.01)
	t.assert_true(actor.return_channel == 0.0, "HURT cancels return")
	actor.hurt.reset()
	for frame in 15:
		await t.get_tree().physics_frame
	NetworkManager._start_return_item(42)
	t.assert_true(actor.dodge.try_begin(1.0), "grounded channel permits authoritative dodge")
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "committed dodge cancels return")
	actor.dodge.reset()
	actor.velocity = Vector2.ZERO
	NetworkManager._start_return_item(42)
	var original_guard := inventory.mutation_guard
	inventory.mutation_guard = func() -> bool: return false
	var before := _snapshot()
	actor.return_channel = actor.return_channel_required
	actor._complete_return_channel()
	t.assert_equal(_snapshot(), before, "failed item removal restores prepared spawn and all canonical state")
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "failed item transaction cancels channel")
	inventory.mutation_guard = original_guard
	var invalid_loot := ItemStack.new(&"leaf_vest", 1)
	invalid_loot.instance_id = "duplicate-secure-instance"
	invalid_loot.durability = 30
	GameSession.settlement.storage.add_stack(invalid_loot)
	GameSession.adventure_session_for_peer(42).get_player_adventure(42).unsecured_loot.add_stack(invalid_loot)
	NetworkManager._start_return_item(42)
	before = _snapshot()
	actor.return_channel = actor.return_channel_required
	actor._complete_return_channel()
	t.assert_equal(_snapshot(), before, "invalid loot staging cannot consume item or partially secure possessions")
	NetworkManager._start_return_item(42)
	GameSession.detach_player(42)
	t.assert_true(actor.return_channel == 0.0 and actor.movement.enabled, "disconnect/despawn clears pending channel")
	t.assert_equal(inventory.count(&"return_seed"), 1, "all failed and cancelled channels conserve return item")
	await _cleanup(t)
