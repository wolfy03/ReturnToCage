extends RefCounted

# STEP 3: per-player gameplay notification routing. ENet isolation between the
# host and real clients is covered by the world-runtime and local multiplayer
# probes; this file covers local routing, the receive guard and lifecycle.

const REMOTE_PLAYER := &"player_ffffffffffffffffffffffffffffffff"

func run(t: Node) -> void:
	NetworkManager.leave_game()
	t.assert_true(GameSession.activate_offline_local_identity(), "notification tests start offline")
	_test_offline_routing(t)
	_test_host_routing(t)
	_test_receive_guard(t)
	_test_save_load_display(t)
	NetworkManager.leave_game()
	GameSession.start_new_game()

func _test_offline_routing(t: Node) -> void:
	var notices: Array[String] = []
	var on_message := func(message: String) -> void: notices.append(message)
	GameSession.notifications.remote_message_received.connect(on_message)
	GameSession.last_message = "local ui"
	t.assert_equal(GameSession.notifications.local_message, "local ui", "last_message assignment is a local notification")
	GameSession.notifications.notify_player(GameSession.get_local_player_id(), "offline personal")
	t.assert_equal(GameSession.last_message, "offline personal", "offline personal notification is shown locally")
	GameSession.notifications.notify_player(REMOTE_PLAYER, "offline anyone")
	t.assert_equal(GameSession.last_message, "offline anyone", "offline has one user, so every gameplay actor is local")
	GameSession.notifications.notify_shared("offline shared")
	t.assert_equal(GameSession.last_message, "offline shared", "offline shared notification is shown locally")
	t.assert_true(notices.is_empty(), "local writes run no UI callbacks synchronously")
	GameSession.notifications.receive_remote("from host")
	t.assert_equal(GameSession.last_message, "from host", "a received notification becomes the local status line")
	t.assert_equal(notices, ["from host"], "only a received notification asks the HUD to refresh")
	GameSession.notifications.remote_message_received.disconnect(on_message)

	GameSession.start_new_game()
	GameSession.settlement.storage.add_item(&"rusty_scrap", 3)
	t.assert_true(GameSession.upgrade_facility(&"workbench"), "offline workbench upgrade fixture succeeds")
	t.assert_true(GameSession.last_message.ends_with("upgraded to level 1"), "offline upgrade actor sees its result")

func _test_host_routing(t: Node) -> void:
	var port := 27000 + randi_range(0, 800)
	t.assert_equal(NetworkManager.host_game(port, 3), OK, "notification host fixture opens")
	GameSession.start_new_game()
	var host_id := GameSession.get_local_player_id()
	GameSession.last_message = "host sentinel"
	GameSession.notifications.notify_player(REMOTE_PLAYER, "remote private gather")
	t.assert_equal(GameSession.last_message, "host sentinel", "a remote player's private notice never reaches the host HUD")
	t.assert_true(not NetworkManager.send_gameplay_notification(REMOTE_PLAYER, "unmapped"), "a player without an authenticated peer gets nothing")
	t.assert_true(not NetworkManager.send_gameplay_notification(host_id, "host via wire"), "the host is never addressed over the wire")
	GameSession.notifications.notify_peer(1, "Unsecured loot: rusty_scrap x2")
	t.assert_equal(GameSession.last_message, "Unsecured loot: rusty_scrap x2", "the host's own gather notice is shown on the host HUD")
	GameSession.notifications.notify_shared("shared by remote", REMOTE_PLAYER)
	t.assert_equal(GameSession.last_message, "shared by remote", "a shared event by another player is shown on the host")
	GameSession.last_message = "host sentinel"
	GameSession.notifications.notify_shared("shared by host", host_id)
	t.assert_equal(GameSession.last_message, "host sentinel", "the acting host is not notified twice for its own shared event")
	GameSession.settlement.storage.add_item(&"rusty_scrap", 3)
	var remote_upgrade := GameSession.execute_facility_upgrade_command(&"workbench", REMOTE_PLAYER)
	t.assert_true(remote_upgrade.success, "remote-actor upgrade fixture succeeds")
	t.assert_equal(GameSession.last_message, remote_upgrade.message, "a remote player's upgrade reaches the host as a shared Settlement event")
	GameSession.last_message = "host sentinel"
	t.assert_true(not GameSession.execute_facility_upgrade_command(&"workbench", REMOTE_PLAYER).success, "a second upgrade past max level fails")
	t.assert_equal(GameSession.last_message, "host sentinel", "a remote actor's failed command result stays off the host HUD")
	NetworkManager.leave_game()
	t.assert_equal(GameSession.last_message, "", "leaving a multiplayer session clears its notifications")

func _test_receive_guard(t: Node) -> void:
	GameSession.last_message = "offline sentinel"
	NetworkManager._receive_gameplay_notification("forged while offline")
	t.assert_equal(GameSession.last_message, "offline sentinel", "notifications outside an entered client session are ignored")
	var port := 27900 + randi_range(0, 600)
	t.assert_equal(NetworkManager.host_game(port, 2), OK, "guard host fixture opens")
	GameSession.last_message = "host sentinel"
	NetworkManager._receive_gameplay_notification("client to host")
	t.assert_equal(GameSession.last_message, "host sentinel", "the host never accepts a notification RPC")
	NetworkManager.leave_game()
	t.assert_true(NetworkProtocol.valid_notification("ok"), "bounded text is a valid notification")
	t.assert_true(not NetworkProtocol.valid_notification(""), "empty text is rejected")
	t.assert_true(not NetworkProtocol.valid_notification("x".repeat(NetworkProtocol.MAX_NOTIFICATION_LENGTH + 1)), "oversized text is rejected")
	t.assert_true(not NetworkProtocol.valid_notification(7), "non-string payload is rejected")

func _test_save_load_display(t: Node) -> void:
	var path := "user://gameplay_notifications_%s_%s.json" % [Time.get_ticks_usec(), randi()]
	GameSession.start_new_game()
	t.assert_true(SaveManager.save_game(path), "notification Save fixture writes")
	GameSession.last_message = "before load"
	t.assert_true(SaveManager.load_game(path), "notification Load fixture loads")
	t.assert_equal(GameSession.last_message, "Game loaded", "the Load result is shown as the local status message")
	for suffix in ["", ".bak", ".tmp", ".bak.rollback", ".corrupt"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
