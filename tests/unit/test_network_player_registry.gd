extends RefCounted

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var local_id := GameSession.get_local_peer_id()
	var local_state := GameSession.player
	t.assert_true(GameSession.has_player(local_id), "offline local player is registered")
	t.assert_true(GameSession.players[local_id] == local_state, "GameSession.player is the canonical local peer state")
	var remote := GameSession.register_player(42)
	t.assert_true(remote != null and remote != local_state, "register peer creates a distinct PlayerState")
	t.assert_true(remote == GameSession.register_player(42), "duplicate peer registration reuses PlayerState")
	var first_item: StartingItemDefinition = GameSession.get_start_definition().inventory_items[0]
	t.assert_equal(remote.inventory.count(first_item.item_id), first_item.quantity, "peer state uses GameStartDefinition")
	GameSession.unregister_player(42)
	t.assert_true(not GameSession.has_player(42), "unregister removes peer state")
	t.assert_true(GameSession.player == local_state, "remote unregister preserves compatibility facade")
