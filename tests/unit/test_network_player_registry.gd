extends RefCounted

const REMOTE_PLAYER_ID: StringName = &"player_42424242424242424242424242424242"

func run(t: Node) -> void:
	NetworkManager.leave_game()
	GameSession.start_new_game()
	var local_id := GameSession.get_local_peer_id()
	var local_state := GameSession.player
	t.assert_true(GameSession.has_player(local_id), "offline local player is registered")
	t.assert_true(GameSession.players[local_id] == local_state, "GameSession.player is the canonical local peer state")
	t.assert_true(GameSession.get_persistent_player(GameSession.get_local_player_id()) == local_state, "host/offline player is owned by persistent player_id")
	var remote := GameSession.attach_player(42, REMOTE_PLAYER_ID)
	t.assert_true(remote != null and remote != local_state, "register peer creates a distinct PlayerState")
	t.assert_true(remote == GameSession.attach_player(42, REMOTE_PLAYER_ID), "duplicate peer registration reuses PlayerState")
	var first_item: StartingItemDefinition = GameSession.get_start_definition().inventory_items[0]
	t.assert_equal(remote.inventory.count(first_item.item_id), first_item.quantity, "peer state uses GameStartDefinition")
	remote.set_health(37.0)
	var item_revision := remote.item_state_revision
	var retired_runtime := GameSession.get_player_runtime(42)
	var old_vitals_callback: Callable = GameSession._player_vitals_callbacks[42]
	var old_item_callback: Callable = GameSession._player_item_callbacks[42]
	GameSession.detach_player(42)
	t.assert_true(not GameSession.has_player(42), "detach removes the active peer attachment")
	t.assert_true(GameSession.get_player_runtime(42) == null, "detach removes peer-scoped runtime state")
	t.assert_true(not remote.vitals_changed.is_connected(old_vitals_callback), "detach disconnects the exact old vitals callback")
	t.assert_true(not remote.item_state_changed.is_connected(old_item_callback), "detach disconnects the exact old item callback")
	t.assert_true(GameSession.has_persistent_player(REMOTE_PLAYER_ID), "detach preserves the canonical persistent PlayerState")
	t.assert_true(GameSession.get_player_state_by_player_id(REMOTE_PLAYER_ID) == remote, "detached state remains addressable by player_id")
	var rebound := GameSession.attach_player(84, REMOTE_PLAYER_ID)
	t.assert_true(rebound == remote and is_equal_approx(rebound.health, 37.0), "same player_id reattaches the existing PlayerState to a new peer")
	t.assert_true(GameSession.get_player_runtime(84) != retired_runtime, "reattach creates a fresh peer-scoped runtime record")
	t.assert_equal(rebound.item_state_revision, item_revision, "reattach does not reset item state revision")
	var new_vitals_callback: Callable = GameSession._player_vitals_callbacks[84]
	var new_item_callback: Callable = GameSession._player_item_callbacks[84]
	t.assert_true(remote.vitals_changed.is_connected(new_vitals_callback) and remote.vitals_changed.get_connections().size() == 1, "reattach installs exactly one vitals callback")
	t.assert_true(remote.item_state_changed.is_connected(new_item_callback) and remote.item_state_changed.get_connections().size() == 1, "reattach installs exactly one item callback")
	t.assert_equal(GameSession.persistent_player_count(), 2, "repeated attachment keeps one canonical state per player_id")
	GameSession.detach_player(84)
	var repeated := GameSession.attach_player(126, REMOTE_PLAYER_ID)
	t.assert_true(repeated == remote and GameSession.persistent_player_count() == 2, "a second reconnect still reuses one canonical PlayerState")
	t.assert_true(remote.vitals_changed.get_connections().size() == 1 and remote.item_state_changed.get_connections().size() == 1, "repeated reconnect does not accumulate domain callbacks")
	GameSession.detach_player(126)
	GameSession.remove_player_state(REMOTE_PLAYER_ID)
	t.assert_true(not GameSession.has_persistent_player(REMOTE_PLAYER_ID), "permanent removal is distinct from detach")
	t.assert_true(GameSession.player == local_state, "remote unregister preserves compatibility facade")
