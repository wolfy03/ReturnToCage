extends RefCounted

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var context := GameSession.begin_adventure(&"sewer_gate", &"sewer_region", &"sewer_entrance")
	t.assert_true(context != null, "combat integration adventure starts")
	if context == null:
		return
	var world := preload("res://world/adventure/sewer_region.tscn").instantiate()
	world.configure(context)
	t.add_child(world)
	await t.get_tree().process_frame
	await t.get_tree().physics_frame
	var player_manager := world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	var enemy_manager := world.get_node("EnemySpawnManager") as EnemySpawnManager
	var loot_manager := world.get_node("LootSpawnManager") as LootSpawnManager
	var player := player_manager.get_actor(GameSession.get_local_peer_id())
	var enemy: EnemyAgent
	for child in world.get_children():
		if child is EnemyAgent:
			enemy = child
			break
	t.assert_true(player != null and enemy != null, "authoritative world spawns player and enemy actors")
	if player == null or enemy == null:
		world.queue_free()
		return

	enemy.global_position = player.global_position + Vector2(38, 0)
	player.facing = 1.0
	var enemy_health_before := enemy.health.current_health
	var attack := player.network_combat._server_execute_attack(player.peer_id, 0)
	await t.get_tree().physics_frame
	await t.get_tree().physics_frame
	t.assert_true(attack.success and enemy.health.current_health < enemy_health_before, "player intent executes existing server hitbox combat against an in-range enemy")

	player.health.invulnerable_remaining = 0.0
	var player_health_before := GameSession.get_player(player.peer_id).health
	enemy.global_position = player.global_position + Vector2(20, 0)
	enemy.player = player
	enemy.perform_attack()
	t.assert_true(GameSession.get_player(player.peer_id).health < player_health_before, "server enemy attack mutates canonical PlayerState health")

	enemy.health.invulnerable_remaining = 0.0
	enemy.health.current_health = 1.0
	var dead_enemy_id := enemy.network_entity_id
	var lethal := DamageContext.new(10.0, &"physical", player, &"player")
	t.assert_true(enemy.health.receive_damage(lethal), "lethal enemy damage is accepted once")
	t.assert_true(not enemy.health.receive_damage(lethal), "dead enemy rejects duplicate lethal damage")
	await t.get_tree().create_timer(0.55).timeout
	t.assert_true(enemy_manager.get_enemy(dead_enemy_id) == null, "enemy death unregisters and despawns the network entity")
	t.assert_equal(loot_manager.entity_ids().size(), 1, "enemy death rolls and spawns loot exactly once")

	var loot_id := loot_manager.entity_ids()[0]
	var loot := loot_manager.get_loot(loot_id)
	loot.global_position = player.global_position
	var personal := GameSession.adventure.active_session.get_player_adventure(player.peer_id)
	var before_count := personal.unsecured_loot.count(loot.stack.item_id)
	var picked := loot_manager.server_try_pickup(player.peer_id, loot_id)
	var raced := loot_manager.server_try_pickup(player.peer_id, loot_id)
	t.assert_true(picked.success and not raced.success, "loot claim transaction allows exactly one winner")
	t.assert_equal(personal.unsecured_loot.count(loot.stack.item_id), before_count + loot.stack.quantity, "pickup credits only the requesting peer personal loot")
	t.assert_true(not world.get_node("NetworkEntityRegistry").has_entity(loot_id), "claimed loot is removed from the entity registry")
	world.queue_free()
	await t.get_tree().process_frame
	GameSession.adventure.active_session = null
	GameSession.set_phase(GameSession.Phase.SETTLEMENT)
