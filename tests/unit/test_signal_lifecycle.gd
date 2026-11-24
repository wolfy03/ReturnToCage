extends RefCounted

# STEP 4: autoload signal lifecycle of re-creatable UI (AppRoot, GameHUD,
# MultiplayerPanel, DebugPanel). Leak warnings (ObjectDB / orphan) are caught by
# check_project.py's output scan; this file checks connection counts.

const CYCLES := 3

func run(t: Node) -> void:
	NetworkManager.leave_game()
	t.assert_true(GameSession.activate_offline_local_identity(), "signal lifecycle tests start offline")
	var baseline := _autoload_connection_counts()
	for cycle in CYCLES:
		await _app_cycle(t, cycle)
	t.assert_equal(_autoload_connection_counts(), baseline, "%d AppRoot create/detach/free cycles leave no autoload connection behind" % CYCLES)
	for cycle in CYCLES:
		await _standalone_cycle(t, "res://ui/game_hud.gd", "GameHUD", cycle)
		await _standalone_cycle(t, "res://ui/multiplayer/multiplayer_panel.gd", "MultiplayerPanel", cycle)
	t.assert_equal(_autoload_connection_counts(), baseline, "standalone HUD/panel cycles leave no autoload connection behind")
	await _host_rejoin_cycle(t, baseline)
	_test_bindings_contract(t)
	GameSession.start_new_game()

func _app_cycle(t: Node, cycle: int) -> void:
	var app := (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	t.add_child(app)
	await t.get_tree().process_frame
	var owners := _binding_owners(app)
	for label in owners:
		var bindings: SignalBindings = owners[label]
		t.assert_true(bindings.size() > 0 and bindings.connected_count() == bindings.size(), "cycle %d: %s connects all of its autoload bindings" % [cycle, label])
	t.assert_equal(_duplicate_connections(), [], "cycle %d: no autoload signal is connected twice to the same callback" % cycle)
	var hud := app.get_node("UILayer/GameHUD")
	t.assert_equal(_connections_to(GameSession.session_reset, hud), 1, "cycle %d: one session reset refreshes the HUD once" % cycle)
	t.assert_equal(_connections_to(SaveManager.load_finished, hud), 1, "cycle %d: one Load result reaches the HUD once" % cycle)

	# Detached but alive: nothing in the removed tree may react to autoloads.
	t.remove_child(app)
	for label in owners:
		t.assert_equal((owners[label] as SignalBindings).connected_count(), 0, "cycle %d: detached %s releases its autoload bindings" % [cycle, label])
	t.assert_equal(_connections_into(app), 0, "cycle %d: a detached AppRoot subtree receives no autoload signal" % cycle)
	# These used to reach AppRoot._return_to_menu and fail on get_tree() == null.
	NetworkManager.multiplayer_session_ended.emit("signal-lifecycle-test")
	GameSession.session_reset.emit()
	SaveManager.load_finished.emit(true, "signal-lifecycle-test")

	t.add_child(app)
	for label in owners:
		var restored: SignalBindings = owners[label]
		t.assert_equal(restored.connected_count(), restored.size(), "cycle %d: re-entered %s restores its bindings" % [cycle, label])
	t.assert_equal(_duplicate_connections(), [], "cycle %d: re-entering does not duplicate connections" % cycle)
	app.queue_free()
	await t.get_tree().process_frame

func _standalone_cycle(t: Node, script_path: String, label: String, cycle: int) -> void:
	var node := (load(script_path) as GDScript).new() as Node
	t.add_child(node)
	await t.get_tree().process_frame
	var bindings: SignalBindings = node.get("autoload_signals")
	t.assert_true(bindings != null and bindings.connected_count() == bindings.size(), "cycle %d: standalone %s connects its bindings" % [cycle, label])
	t.assert_equal(_duplicate_connections(), [], "cycle %d: standalone %s adds no duplicate connection" % [cycle, label])
	node.queue_free()
	await t.get_tree().process_frame

func _host_rejoin_cycle(t: Node, baseline: Dictionary) -> void:
	var app := (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	t.add_child(app)
	await t.get_tree().process_frame
	var with_app := _autoload_connection_counts()
	for round in 2:
		var port := 28500 + randi_range(0, 400) + round
		t.assert_equal(NetworkManager.host_game(port, 2), OK, "host/leave round %d opens a host" % round)
		NetworkManager.leave_game()
		await t.get_tree().process_frame
		t.assert_equal(_autoload_connection_counts(), with_app, "host/leave round %d does not add stale callbacks" % round)
		t.assert_equal(_duplicate_connections(), [], "host/leave round %d keeps connections unique" % round)
	app.queue_free()
	await t.get_tree().process_frame
	t.assert_equal(_autoload_connection_counts(), baseline, "host/leave cycles leave no autoload connection after AppRoot is freed")

func _test_bindings_contract(t: Node) -> void:
	var bindings := SignalBindings.new()
	var target := Node.new()
	var callable := target.get_index.unbind(1)
	bindings.add(GameSession.quest_changed, callable)
	bindings.connect_all()
	bindings.connect_all()
	t.assert_equal(_connections_to(GameSession.quest_changed, target), 1, "connect_all is idempotent")
	t.assert_true(GameSession.quest_changed.is_connected(callable), "a stored unbind() adapter can be found again")
	bindings.disconnect_all()
	bindings.disconnect_all()
	t.assert_equal(_connections_to(GameSession.quest_changed, target), 0, "disconnect_all releases the stored adapter and is idempotent")
	target.free()

func _autoload_sources() -> Dictionary:
	return {
		"GameSession": GameSession, "NetworkManager": NetworkManager, "SaveManager": SaveManager,
		"SceneRouter": SceneRouter, "LocalInputContext": LocalInputContext, "ContentRegistry": ContentRegistry,
		"Notifications": GameSession.notifications,
	}

func _autoload_connection_counts() -> Dictionary:
	var counts := {}
	var sources := _autoload_sources()
	for source_name in sources:
		var source: Object = sources[source_name]
		for signal_info in source.get_signal_list():
			var count := source.get_signal_connection_list(signal_info.name).size()
			if count > 0:
				counts["%s.%s" % [source_name, signal_info.name]] = count
	return counts

func _duplicate_connections() -> Array[String]:
	var duplicates: Array[String] = []
	var sources := _autoload_sources()
	for source_name in sources:
		var source: Object = sources[source_name]
		for signal_info in source.get_signal_list():
			var seen := {}
			for connection in source.get_signal_connection_list(signal_info.name):
				var callable: Callable = connection.callable
				var target := callable.get_object()
				var key := "%d|%s|%d" % [target.get_instance_id() if target != null else 0, callable.get_method(), callable.get_unbound_arguments_count()]
				if seen.has(key):
					duplicates.append("%s.%s -> %s" % [source_name, signal_info.name, key])
				seen[key] = true
	return duplicates

func _connections_to(source_signal: Signal, target: Object) -> int:
	var count := 0
	for connection in source_signal.get_connections():
		if (connection.callable as Callable).get_object() == target:
			count += 1
	return count

func _connections_into(root: Node) -> int:
	var count := 0
	var sources := _autoload_sources()
	for source_name in sources:
		var source: Object = sources[source_name]
		for signal_info in source.get_signal_list():
			for connection in source.get_signal_connection_list(signal_info.name):
				var target := (connection.callable as Callable).get_object()
				if target is Node and (target == root or root.is_ancestor_of(target)):
					count += 1
	return count

func _binding_owners(app: AppRoot) -> Dictionary:
	var owners := {"AppRoot": app.autoload_signals}
	owners["GameHUD"] = app.get_node("UILayer/GameHUD").get("autoload_signals")
	owners["MultiplayerPanel"] = app.multiplayer_panel.autoload_signals
	var debug_panel := app.find_child("DebugPanel", true, false)
	if debug_panel != null:
		owners["DebugPanel"] = debug_panel.get("autoload_signals")
	return owners
