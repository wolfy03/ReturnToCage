extends Node
## Opt-in shared Editor/Export validation. Normal gameplay never instantiates it.

var app: AppRoot
var role: String
var port: int
var command_path: String
var result_path: String
var _sequence := 0
var _busy := false
var _failed := false
var _deadline: int
var _player_id: StringName
var _watched_id: StringName
var _watch_origin: Vector2
var _watch_direction := 1.0
var _saw_motion := false
var _saw_run := false
var _input_sample: Dictionary = {}
var _input_edges: Dictionary[int, Array] = {}
const INPUT_KEYS := {
	"left": KEY_A, "right": KEY_D, "up": KEY_W, "jump": KEY_SPACE,
	"attack": KEY_J, "dodge": KEY_SHIFT, "interact": KEY_E, "quick": KEY_Q,
}
var _remembered: Dictionary[StringName, int] = {}
var _gui_mode := false
var _context: Dictionary = {}
var _profile_hash: String
var _save_hash := ""
var _save_session_id := ""
var _saved_slot_layout: Dictionary = {}
var _saved_stats: Dictionary = {}
var _saved_storage: Dictionary = {}
var _remembered_slot_layout: Dictionary = {}
var _previous_slot_intent: Dictionary = {}
var _prepared_slot_intent: Dictionary = {}
var _item_presenter_id := 0
var _expect_item_windows := false
const FIELD_GEAR_SAVE := "user://field_gear_boundary.json"
var _field_gear_sequence := -1
var _field_gear_won := false
var _field_gear_session := ""

func configure(p_app: AppRoot, context: Dictionary) -> void:
	app = p_app
	_gui_mode = true
	_context = context.duplicate(true)

func _ready() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--command="):
			command_path = argument.trim_prefix("--command=")
		elif argument.begins_with("--result="):
			result_path = argument.trim_prefix("--result=")
	_deadline = Time.get_ticks_msec() + 60000
	if app == null:
		app = (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
		add_child(app)
	if _gui_mode:
		var isolated := OS.get_environment("RTC_TEST_USER_ROOT").replace("\\", "/").simplify_path()
		var user_path := OS.get_user_data_dir().replace("\\", "/").simplify_path()
		if isolated.is_empty() or not user_path.begins_with(isolated + "/"):
			_fail("lifecycle validation requires an isolated native user directory")
			return
		app.multiplayer_panel.host_requested.disconnect(app._host_game)
		app.multiplayer_panel.host_requested.connect(func() -> void: app._host_game(port))
		app.multiplayer_panel.host_saved_requested.disconnect(app._host_saved_game)
		app.multiplayer_panel.host_saved_requested.connect(func() -> void: app._host_saved_game("", port, 4))
		app.multiplayer_panel.join_requested.disconnect(app._join_game)
		app.multiplayer_panel.join_requested.connect(func(address: String) -> void: app._join_game(address, port))
	await get_tree().process_frame
	await get_tree().process_frame
	_player_id = GameSession.get_local_player_id()
	_profile_hash = FileAccess.get_file_as_string("user://local_player_profile.json").sha256_text()
	# Exercise publication while a Windows reader holds the previous result.
	# The real Python controller can hold the same short-lived sharing lock.
	if OS.get_name() == "Windows":
		await _write("initializing")
		var reader := FileAccess.open(result_path, FileAccess.READ)
		get_tree().create_timer(0.05).timeout.connect(func() -> void: reader.close(), CONNECT_ONE_SHOT)
	await _write("ready")

func _process(_delta: float) -> void:
	if _failed:
		return
	var watched := _actor(_watched_id)
	if watched != null:
		_saw_motion = _saw_motion or (watched.position.x - _watch_origin.x) * _watch_direction > 12.0
		var visual := watched.player_visual().get_node("PlayerAnimationPresenter") as PlayerAnimationPresenter
		_saw_run = _saw_run or visual != null and visual.current_animation() == &"run" and watched.facing == _watch_direction
	if Time.get_ticks_msec() > _deadline:
		_fail("command timeout")
		return
	if _busy or not FileAccess.file_exists(command_path):
		return
	var parser := JSON.new()
	var text := FileAccess.get_file_as_string(command_path)
	if text.is_empty() or parser.parse(text) != OK or not parser.data is Dictionary:
		return
	var command: Dictionary = parser.data
	if int(command.get("sequence", 0)) <= _sequence:
		return
	_sequence = int(command.sequence)
	_deadline = Time.get_ticks_msec() + 60000
	_busy = true
	if _gui_mode:
		print("SESSION STEP %d %s %s" % [_sequence, command.get("action", ""), JSON.stringify(_state_dump())])
	_execute(command)

func _execute(command: Dictionary) -> void:
	var action := String(command.action)
	var target := StringName(command.get("player", ""))
	match action:
		"host", "host_saved":
			_expect_item_windows = false # Starting a new session deliberately closes item windows.
			if _gui_mode:
				var button := app.multiplayer_panel.host_button if action == "host" else app.multiplayer_panel.host_saved_button
				if not await _click(button):
					_fail("Host/Host Save did not receive GUI input")
					return
			else:
				app._host_game(port)
			if not await _wait(_ready_world):
				_fail("host world not ready")
				return
			if action == "host_saved" and (GameSession.session_id != _save_session_id or GameSession.player.inventory.count(&"rusty_scrap") != 3 or _slot_layout(GameSession.player) != _saved_slot_layout):
				_fail("Host Save did not restore the original Save v5")
				return
		"join":
			var address := String(command.get("address", "127.0.0.1"))
			if _gui_mode:
				app.multiplayer_panel.address_edit.text = address
				if not await _click(app.multiplayer_panel.join_button):
					_fail("Join did not receive GUI input")
					return
			else:
				app._join_game(address, port)
			if not await _wait(_ready_world):
				_fail("join failed: %s" % NetworkManager.last_error)
				return
			if not NetworkManager._received_session_snapshot or not NetworkManager._received_private_player_state \
					or not NetworkManager._received_world_assignment or not NetworkManager._received_spawn_assignment:
				_fail("Join skipped an authoritative synchronization stage")
				return
		"new_game", "load_game":
			var button := app.new_game_button if action == "new_game" else app.load_game_button
			if not await _click(button) or not await _wait(_offline_ready):
				_fail("offline New/Load did not receive GUI input or restore simulation")
				return
			if action == "load_game" and (GameSession.session_id != _save_session_id or GameSession.player.inventory.count(&"rusty_scrap") != 3 or _slot_layout(GameSession.player) != _saved_slot_layout):
				_fail("Load Game did not restore the original Save v5")
				return
			if action == "load_game" and (_gear_stats(GameSession.player) != _saved_stats \
					or GameSession.settlement.storage.to_slot_dict() != _saved_storage or not _unique_item_instances(GameSession.player)):
				_fail("Load Game did not restore equipment stats or storage")
				return
		"save_fixture":
			if command.get("require_input_block", false) and not LocalInputContext.is_gameplay_blocked():
				_fail("Save fixture requires an open input-blocking window")
				return
			var inventory := GameSession.player.inventory
			if not inventory.add_item(&"rusty_scrap", 3).success or not inventory.expand_capacity(6).success:
				_fail("could not add Save fixture resources")
				return
			var scrap_slot := -1
			for index in inventory.capacity:
				var stack := inventory.get_slot(index)
				if stack != null and stack.item_id == &"rusty_scrap":
					scrap_slot = index
					break
			if not inventory.move_slot(scrap_slot, 17).success:
				_fail("could not create a sparse Save fixture")
				return
			_saved_slot_layout = _slot_layout(GameSession.player)
			_saved_stats = _gear_stats(GameSession.player)
			_saved_storage = GameSession.settlement.storage.to_slot_dict()
			if not _unique_item_instances(GameSession.player):
				_fail("Save fixture contains duplicate item instances")
				return
			if not await _click(app.get_node("UILayer/GameHUD").save_button) or not FileAccess.file_exists(SaveManager.SAVE_PATH):
				_fail("Save button did not write the isolated Save v5")
				return
			_save_session_id = GameSession.session_id
			_save_hash = FileAccess.get_file_as_string(SaveManager.SAVE_PATH).sha256_text()
		"to_menu", "check_menu":
			var previous := GameSession.get_local_player() if action == "to_menu" else null
			if action == "to_menu":
				app._leave_game() # Offline fixture uses the production menu cleanup path.
			if not await _wait(_menu_clean):
				_fail("menu/session cleanup did not complete")
				return
			var presenter: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
			if previous != null and previous.item_state_changed.is_connected(presenter._on_item_state_changed):
				_fail("retired PlayerState still has the inventory presenter signal")
				return
			_expect_item_windows = false
		"inspect":
			if not await _wait(func() -> bool: return _roster_issue(command).is_empty()):
				_fail("%s: %s" % [command.get("label", "inspect"), _roster_issue(command)])
				return
			if _expect_item_windows and not _item_windows_visible():
				_fail("item windows did not survive world presentation change")
				return
		"slot_seed":
			var player := GameSession.get_player_state_by_player_id(target)
			if not NetworkManager.is_server() or player == null:
				_fail("slot fixture requires authoritative owner")
				return
			var cells: Array[ItemStack] = []
			cells.resize(18)
			cells[0] = ItemStack.new(&"berry", 6)
			cells[2] = ItemStack.new(&"water_drop", 2)
			var vest := ItemStack.new(&"leaf_vest", 1)
			vest.instance_id = "slot-vest-" + String(target)
			vest.durability = 31
			cells[5] = vest
			if not player.inventory.initialize_slots(cells, 18).success:
				_fail("cannot seed sparse inventory")
				return
		"slot_ready":
			if not await _wait(func() -> bool:
				return GameSession.player.inventory.capacity == 18 and GameSession.player.inventory.get_slot(5) != null
			):
				_fail("owner did not receive sparse slot fixture")
				return
		"slot_rpc":
			if not await _slot_rpc(command):
				_fail("slot RPC result/layout mismatch: %s" % command)
				return
		"slot_ui":
			if not await _slot_ui(command):
				_fail("slot GUI did not reconcile the owner snapshot and result: %s" % command)
				return
		"slot_drop_observe":
			var peer := NetworkManager.peer_id_for_player(target)
			var player := GameSession.get_player(peer)
			var runtime := NetworkManager.server_world_runtime(SceneRouter.current_world_id())
			var presentation := _visible_loot_manager()
			if player == null or player.inventory.get_slot(0) != null or runtime == null or presentation == null:
				_fail("client drag did not clear the authoritative slot")
				return
			var ids := runtime.loot_manager().entity_ids()
			if ids.size() != 1:
				_fail("client drag did not create exactly one field item")
				return
			var server_loot := runtime.loot_manager().get_loot(ids[0])
			var visible := presentation.get_loot(ids[0])
			if visible == null or visible.stack.item_id != &"berry" or visible.stack.quantity != 6 \
					or not visible.global_position.is_equal_approx(server_loot.global_position):
				_fail("Host did not see the exact field item at the server position")
				return
		"slot_transition_fixture":
			var peer := NetworkManager.peer_id_for_player(target)
			if not NetworkManager.is_server() or not NetworkManager.is_peer_world_ready(peer):
				_fail("pending-transition fixture requires an attached ready player")
				return
			if command.block:
				NetworkManager._pending_world_transitions[peer] = NetworkManager.world_assignment_for_peer(peer)
			else:
				NetworkManager._pending_world_transitions.erase(peer)
		"item_seed":
			var player := GameSession.get_player_state_by_player_id(target)
			var gear := ItemStack.new(&"leaf_vest", 1)
			gear.instance_id = String(command.get("instance", ""))
			gear.durability = 37
			if not NetworkManager.is_authoritative_simulation() or player == null or not player.inventory.add_stack(gear).success:
				_fail("cannot seed equipment action fixture")
				return
		"field_gear_materials":
			var storage := GameSession.settlement.storage
			if not NetworkManager.is_authoritative_simulation() or not storage.add_item(&"moss_fiber", 2).success or not storage.add_item(&"rusty_scrap", 1).success:
				_fail("cannot seed field gear recipe materials")
				return
		"field_gear_ready":
			if not await _wait(func() -> bool:
				return GameSession.settlement.storage.count(&"moss_fiber") >= 2 and GameSession.settlement.storage.count(&"rusty_scrap") >= 1
			):
				_fail("field gear inputs did not synchronize")
				return
		"field_gear_craft", "field_gear_race", "field_gear_replay":
			if not await _craft_field_gear(action, int(command.get("sequence_offset", 0))):
				_fail("field gear RPC did not conserve inputs and owner-private outputs: " + action)
				return
		"field_gear_save":
			if not NetworkManager.is_server() or not SaveManager.save_game(FIELD_GEAR_SAVE):
				_fail("host could not save immediately after field gear craft")
				return
			_field_gear_session = GameSession.session_id
		"field_gear_rehost":
			app._host_saved_game(FIELD_GEAR_SAVE, port, 4)
			if not await _wait(_ready_world) or GameSession.session_id != _field_gear_session:
				_fail("Host Save did not restore the crafted field gear session")
				return
		"item_foreign":
			if not await _reject_foreign_equip(String(command.instance)):
				_fail("client could equip another owner's instance")
				return
		"item_ui":
			if not await _item_ui(command):
				_fail("equipment/consumption GUI did not reconcile: %s" % command)
				return
		"item_resume":
			if get_tree().multiplayer_poll or not await _resume_pending_item():
				_fail("pending item command did not settle after resuming ENet")
				return
		"item_display":
			if not await _check_equipped_display():
				_fail("equipment window did not reflect the current owner's restored gear")
				return
		"slot_prepare":
			var service := _item_service()
			_prepared_slot_intent = service.make_slot_intent(PlayerItemCommandService.SlotAction.MOVE, PlayerItemCommandService.SlotInventory.MAIN, 0, 17)
			if _prepared_slot_intent.is_empty():
				_fail("could not capture pre-transition slot intent")
				return
		"slot_remember":
			_remembered_slot_layout = _slot_layout(GameSession.player)
		"slot_check":
			if _remembered_slot_layout.is_empty() or _slot_layout(GameSession.player) != _remembered_slot_layout:
				_fail("slot layout changed across world transition or reconnect")
				return
		"slot_canonical":
			var player := GameSession.get_player_state_by_player_id(target)
			var stack := player.inventory.get_slot(15) if player != null else null
			if not NetworkManager.is_server() or stack == null or stack.instance_id != "slot-vest-" + String(target) or stack.durability != 31:
				_fail("canonical inventory did not commit the moved equipment instance")
				return
		"slot_privacy":
			if NetworkManager.is_server():
				_fail("privacy check needs an observing client")
				return
			for peer_id in GameSession.players:
				if peer_id == NetworkManager.local_peer_id():
					continue
				var remote := GameSession.get_player(peer_id)
				if not remote.inventory.stacks().is_empty() or not remote.protected_inventory.stacks().is_empty() or not remote.equipment.all_equipped().is_empty():
					_fail("other owner's private slot state reached this client")
					return
		"item_windows":
			if not await _check_item_windows():
				_fail("inventory/equipment GUI validation failed")
				return
		"input_windows":
			if not await _set_input_windows(command):
				_fail("visible item windows and local input block disagree")
				return
		"input_key":
			var physical: Key = INPUT_KEYS.get(String(command.key), KEY_NONE)
			if physical == KEY_NONE:
				_fail("unknown physical input fixture key")
				return
			if command.get("expect_interact", false):
				var actor := _actor(_player_id)
				if actor == null:
					_fail("interaction fixture requires a local actor")
					return
				var delivered := [false]
				var observe := func() -> void: delivered[0] = true
				actor.input.interact_requested.connect(observe)
				await _tap_probe_key(physical)
				actor.input.interact_requested.disconnect(observe)
				if not delivered[0]:
					_fail("other player's interaction was not dispatched")
					return
			elif command.has("pressed"):
				_probe_key(physical, bool(command.pressed))
				await get_tree().process_frame
			else:
				await _tap_probe_key(physical)
		"input_storage":
			if not await _check_blocked_storage():
				_fail("blocked owner did not reconcile a Settlement storage round trip")
				return
		"input_blocked_edges":
			if not await _check_blocked_edges():
				_fail("a gameplay action leaked from the blocked local keyboard")
				return
		"input_authority":
			if not await _check_authoritative_input(target, command):
				_fail("authoritative input mismatch: %s sample=%s" % [command, _input_sample])
				return
		"input_place":
			var actor := NetworkManager.authoritative_actor(NetworkManager.peer_id_for_player(target))
			if not NetworkManager.is_server() or actor == null:
				_fail("input fixture needs a real authoritative actor")
				return
			actor.position = Vector2(float(command.x), 520.0)
			actor.velocity = Vector2.ZERO
			if command.get("effect", false):
				var effect := ContentRegistry.get_definition(&"quick_paws") as EffectDefinition
				actor.player_state().effects.apply_effect(effect, ItemDefinition.FoodSlot.SNACK)
			await get_tree().physics_frame
			await get_tree().physics_frame
		"input_world_tick":
			if not await _check_blocked_enemy_tick(target):
				_fail("blocked Host did not observe Sewer enemy physics and replication progress")
				return
		"watch":
			var actor := _actor(target)
			if actor == null:
				_fail("missing actor to watch")
				return
			_watched_id = target
			_watch_origin = actor.position
			_watch_direction = -1.0 if command.get("left", false) else 1.0
			_saw_motion = false
			_saw_run = false
		"move":
			# Exercise real movement with the item windows closed, then restore
			# the existing lifecycle fixture's window state for later checks.
			var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
			var restore_inventory := items.inventory_window.visible
			var restore_equipment := items.equipment_window.visible
			if restore_inventory:
				await _item_key(KEY_I)
			if restore_equipment:
				await _item_key(KEY_P)
			var input_action: StringName = &"move_left" if command.get("left", false) else &"move_right"
			Input.action_press(input_action)
			await get_tree().create_timer(0.6).timeout
			# Keep the original run assertion even on a slow rendered runner.
			# Give the local presentation time to observe its replicated run.
			var run_deadline := Time.get_ticks_msec() + 500
			while _watched_id == _player_id and not _saw_run and Time.get_ticks_msec() < run_deadline:
				await get_tree().process_frame
			Input.action_release(input_action)
			await get_tree().create_timer(0.15).timeout
			if restore_inventory:
				await _item_key(KEY_I)
			if restore_equipment:
				await _item_key(KEY_P)
		"assert_motion":
			if not await _wait(func() -> bool: return _saw_motion and _saw_run):
				var actor := _actor(_watched_id)
				var authority := NetworkManager.authoritative_actor(NetworkManager.peer_id_for_player(_watched_id)) if NetworkManager.is_server() else null
				_fail("transform/run animation missing for %s motion=%s run=%s pos=%s direction=%s transform_sequence=%s authority=%s" % [
					_watched_id, _saw_motion, _saw_run, actor.position if actor != null else Vector2.INF,
					_watch_direction, actor.network._snapshot_sequence if actor != null else -1,
					{"position": authority.position, "velocity": authority.velocity, "input": authority.input.move_axis,
					"received": authority.network._last_received_sequence, "snapshot": authority.network._snapshot_sequence,
					"locked": authority.movement.controls_locked} if authority != null else {},
				])
				return
		"place":
			var actor := NetworkManager.authoritative_actor(NetworkManager.peer_id_for_player(target))
			if actor == null:
				_fail("missing authoritative transition actor")
				return
			actor.position = Vector2(865, 510) if command.destination == "enter" else Vector2(70, 510)
			actor.velocity = Vector2.ZERO
			await get_tree().physics_frame
			await get_tree().physics_frame
		"enter", "return":
			var result := NetworkManager.request_enter_region(&"sewer_gate", &"sewer_region") if action == "enter" \
				else NetworkManager.request_escape_at_point(&"sewer_entrance")
			var destination: StringName = &"adventure:sewer_region" if action == "enter" else &"settlement"
			if not get_tree().multiplayer_poll and not await _resume_pending_item():
				_fail("item request did not settle during world transition")
				return
			if not result.success or not await _wait(func() -> bool: return _ready_world() and SceneRouter.current_world_id() == destination):
				_fail("world transition failed: %s" % result.message)
				return
		"remember":
			var actor := _actor(target)
			_remembered[target] = actor.get_instance_id() if actor != null else 0
		"kill":
			var peer := NetworkManager.peer_id_for_player(target)
			var actor := NetworkManager.authoritative_actor(peer)
			var old_id := actor.get_instance_id() if actor != null else 0
			if actor == null:
				_fail("missing lethal damage target")
				return
			actor.health.invulnerable_remaining = 0.0
			var damage := DamageContext.new(10000.0, &"roster_probe", null, &"environment")
			damage.can_be_evaded = false
			actor.health.receive_damage(damage)
			if not await _wait(func() -> bool:
				var current := NetworkManager.authoritative_actor(peer)
				return current != null and current.get_instance_id() != old_id
			):
				_fail("production death did not respawn an authoritative actor")
				return
		"assert_replaced":
			if not await _wait(func() -> bool: return _actor(target) != null and _actor(target).get_instance_id() != _remembered.get(target, 0)):
				_fail("death did not replace presentation actor")
				return
		"repeat_arrival":
			for peer in NetworkManager.players:
				NetworkManager._broadcast_world_arrival(peer)
				NetworkManager._broadcast_world_arrival(peer)
		"invalid_roster":
			var manager := _manager()
			var peer := NetworkManager.local_peer_id()
			var old := manager.get_actor(peer)
			var assignment := NetworkManager.world_assignment_for_peer(peer)
			var wrong := PlayerWorldAssignment.from_payload(assignment.to_payload())
			wrong.session_id = "retired-session"
			manager._on_world_roster_player_received(peer, wrong, Vector2(999, 999))
			wrong = PlayerWorldAssignment.from_payload(assignment.to_payload())
			wrong.player_id = &"player_00000000000000000000000000000000"
			manager._on_world_roster_player_received(peer, wrong, Vector2(999, 999))
			manager._on_world_roster_player_received(peer, assignment, Vector2.INF)
			if manager.get_actor(peer) != old or old.position == Vector2(999, 999):
				_fail("invalid roster changed the actor")
				return
		"disconnect", "quit":
			if _gui_mode and NetworkManager.is_multiplayer_active():
				if not await _click(app.multiplayer_panel.disconnect_button):
					_fail("Disconnect did not receive GUI input")
					return
			else:
				app._leave_game()
			get_tree().multiplayer_poll = true
			if not await _wait(_menu_clean):
				_fail("scene cleanup failed")
				return
			_expect_item_windows = false
			if action == "quit":
				var retiring := app
				app = null
				SceneRouter.register_world_layer(null)
				retiring.queue_free()
				await get_tree().process_frame
				await get_tree().process_frame
				var coordinator := get_tree().root.get_node_or_null(NodePath(String(EnvironmentLoadCoordinator.NODE_NAME))) as EnvironmentLoadCoordinator
				if coordinator != null and not await _wait(func() -> bool: return coordinator.pending_path_count() == 0):
					_fail("resource loads did not drain")
					return
				await _write("pass")
				print("PLAYER ROSTER PROBE PASS %s" % role)
				if _gui_mode:
					print("SESSION LIFECYCLE PROBE PASS %s" % role)
				_failed = true
				# Let this command coroutine release its captures before tree teardown.
				get_tree().call_deferred("quit", 0)
				return
		_:
			_fail("unknown action %s" % action)
			return
	if GameSession.get_local_player_id() != _player_id:
		_fail("persistent local identity changed")
		return
	if _gui_mode and FileAccess.get_file_as_string("user://local_player_profile.json").sha256_text() != _profile_hash:
		_fail("lifecycle actions changed the persisted local Profile v1")
		return
	if not _save_hash.is_empty() and FileAccess.get_file_as_string(SaveManager.SAVE_PATH).sha256_text() != _save_hash:
		_fail("lifecycle actions changed the original Save file")
		return
	await _write("pass")
	_busy = false

func _roster_issue(command: Dictionary) -> String:
	var manager := _manager()
	if not _ready_world() or manager == null or SceneRouter.current_world_id() != StringName(command.world):
		return "presentation world not ready"
	var actual: Array[String] = []
	for peer in manager._actors:
		var actor := manager.get_actor(peer)
		if actor == null or not actor.is_visible_in_tree() or actor.process_mode == Node.PROCESS_MODE_DISABLED:
			return "hidden/stopped actor %d" % peer
		if actor.is_simulation_authority() or actor.simulation_enabled or not actor.presentation_enabled \
				or actor.world_id != manager.world_id or actor.player_state() != GameSession.get_player(peer) \
				or actor.input.local_input_enabled != (peer == NetworkManager.local_peer_id()):
			return "presentation authority/identity/world mismatch"
		var visual := actor.player_visual().get_node("PlayerAnimationPresenter") as PlayerAnimationPresenter
		var hurtbox := actor.get_node("Hurtbox") as HurtboxComponent
		if visual == null or not visual.sprite.visible or hurtbox.monitoring or hurtbox.monitorable:
			return "visual missing or presentation damage enabled"
		actual.append(String(GameSession.get_player_id(peer)))
	var expected: Array = command.expected.duplicate()
	actual.sort()
	expected.sort()
	if actual != expected:
		return "presentation roster actual=%s expected=%s" % [actual, expected]
	var count := 0
	for child in manager.get_parent().get_children():
		if child is PlayerActor:
			count += 1
	if count != expected.size():
		return "duplicate/unregistered presentation actor"
	if NetworkManager.is_server():
		var root := app.get_node("ServerWorldRoot") as ServerWorldRoot
		for id in root.world_ids():
			var runtime := root.runtime(id)
			var peers := GameSession.peer_ids_in_world(id)
			if runtime.player_manager()._actors.size() != peers.size():
				return "authoritative runtime roster differs from canonical world"
			for peer in peers:
				var actor := runtime.player_manager().get_actor(peer)
				if actor == null or not actor.is_simulation_authority() or actor.presentation_enabled or actor == manager.get_actor(peer):
					return "authoritative/presentation actor separation failed"
	return ""

func _manager() -> PlayerSpawnManager:
	return app.world_layer.get_child(0).get_node("PlayerSpawnManager") as PlayerSpawnManager if app != null and app.world_layer.get_child_count() == 1 else null

func _actor(id: StringName) -> PlayerActor:
	var manager := _manager()
	var peer := NetworkManager.peer_id_for_player(id)
	if peer <= 0 and id == GameSession.get_local_player_id():
		peer = GameSession.get_local_peer_id()
	return manager.get_actor(peer) if manager != null and not id.is_empty() else null

func _ready_world() -> bool:
	return not app.menu.visible and NetworkManager.is_local_world_ready() and _manager() != null

func _offline_ready() -> bool:
	return not NetworkManager.is_multiplayer_active() and NetworkManager.is_authoritative_simulation() \
		and GameSession.phase == GameSession.Phase.SETTLEMENT and not app.menu.visible \
		and SceneRouter.current_world_id() == &"settlement" and _manager() != null \
		and _actor(_player_id) != null and _actor(_player_id).is_simulation_authority() \
		and app.get_node("UILayer/GameHUD").visible

func _menu_clean() -> bool:
	var hud := app.get_node("UILayer/GameHUD")
	var items: InventoryPresenter = hud.inventory_presenter
	return NetworkManager.state == NetworkManager.ConnectionState.OFFLINE \
		and NetworkManager.players.is_empty() and NetworkManager.world_ready_peers.is_empty() \
		and NetworkManager.peer_to_player.is_empty() and NetworkManager.player_to_peer.is_empty() \
		and NetworkManager._pending_world_transitions.is_empty() and NetworkManager._spawn_assignments.is_empty() \
		and NetworkManager._replication_ready_after_msec.is_empty() and NetworkManager._returning_peers.is_empty() \
		and not NetworkManager._received_session_snapshot and not NetworkManager._received_private_player_state \
		and not NetworkManager._received_world_assignment and not NetworkManager._received_spawn_assignment \
		and GameSession.phase == GameSession.Phase.MENU and GameSession.session_id.is_empty() \
		and GameSession.players.size() == 1 and GameSession.get_local_player_id() == _player_id \
		and GameSession.adventure.active_session == null and GameSession._adventure_sessions_by_world.is_empty() \
		and SceneRouter.current_world_id().is_empty() and SceneRouter._assignment_session_id.is_empty() \
		and SceneRouter._assignment_revision == 0 and not app._menu_transition_pending \
		and app.get_node("ServerWorldRoot").runtime_count() == 0 \
		and app.menu.visible and app.world_layer.get_child_count() == 0 and not hud.visible \
		and hud.bound_player == null and not get_tree().paused \
		and not items.inventory_window.visible and not items.equipment_window.visible and not items.tooltip.visible \
		and items._state == null and items._pending_item_type == -1 and items._pending_sequence == -1 \
		and not items.inventory_window._pending and _item_service()._pending_item_types.is_empty() \
		and not app.new_game_button.disabled and not app.load_game_button.disabled \
		and not app.multiplayer_panel.host_button.disabled and not app.multiplayer_panel.host_saved_button.disabled \
		and not app.multiplayer_panel.join_button.disabled and app.multiplayer_panel.disconnect_button.disabled

func _item_service() -> PlayerItemReplicationService:
	return get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService

func _slot_layout(player: PlayerState) -> Dictionary:
	return {"inventory": player.inventory.to_slot_dict(), "protected": player.protected_inventory.to_slot_dict(), "equipment": player.equipment.to_dict()}

func _gear_stats(player: PlayerState) -> Dictionary:
	var gear: EquipmentWindow = app.get_node("UILayer/GameHUD").inventory_presenter.equipment_window
	var values := {}
	for stat_id in gear._stat_values:
		values[stat_id] = player.stats.value(stat_id)
	return values

func _unique_item_instances(player: PlayerState) -> bool:
	var seen := {}
	for stack in player.inventory.stacks() + player.protected_inventory.stacks() + player.equipment.all_equipped():
		if stack.instance_id.is_empty():
			continue
		if seen.has(stack.instance_id):
			return false
		seen[stack.instance_id] = true
	return true

func _slot_rpc(command: Dictionary) -> bool:
	var service := _item_service()
	if service == null or NetworkManager.is_server():
		return false
	var player := GameSession.get_local_player()
	var before := _slot_layout(player)
	var revision := player.item_state_revision
	var action := int(command.get("slot_action", PlayerItemCommandService.SlotAction.MOVE))
	var from := int(command.get("from", 0))
	var to := int(command.get("to", 17))
	var amount := int(command.get("amount", 0))
	var failure := String(command.get("reject", ""))
	var intent := service.make_slot_intent(action, PlayerItemCommandService.SlotInventory.MAIN, from, to, amount)
	if intent.is_empty():
		return false
	match failure:
		"owner": intent.owner_player_id = String(command.player)
		"session": intent.session_id = "retired-session"
		"revision": intent.revision -= 1
		"instance": intent.source.instance_id = "forged-instance"
		"replay": intent = _previous_slot_intent.duplicate(true)
		"world": intent = _prepared_slot_intent.duplicate(true)
	var sequence: int = intent.sequence
	var replies: Array[Dictionary] = []
	var receive := func(received_sequence: int, success: bool, message: String) -> void:
		if received_sequence == sequence:
			replies.append({"success": success, "message": message})
	service.slot_result.connect(receive)
	# Deliberately exercise the real ENet authority boundary, including forged intents.
	service._request_slot_command.rpc_id(1, intent)
	var replied := await _wait(func() -> bool: return not replies.is_empty())
	service.slot_result.disconnect(receive)
	if not replied:
		return false
	if not failure.is_empty():
		return not replies[0].success and player.item_state_revision == revision and _slot_layout(player) == before \
			and (failure != "replay" or String(replies[0].message).contains("sequence")) \
			and (failure != "world" or String(replies[0].message).contains("world"))
	_previous_slot_intent = intent.duplicate(true)
	if not replies[0].success or player.item_state_revision != revision + 1 or _slot_layout(player) == before:
		return false
	var expected := InventoryModel.new(before.inventory.capacity, Callable(ContentRegistry, "get_item"))
	var instances: Dictionary[String, String] = {}
	var layout := SaveData.inventory_layout(before.inventory, expected.definition_resolver, instances, "slot test")
	if not layout.success or not expected.initialize_slots(layout.slots).success:
		return false
	var result: CommandResult
	match action:
		PlayerItemCommandService.SlotAction.MOVE: result = expected.move_slot(from, to)
		PlayerItemCommandService.SlotAction.SWAP: result = expected.swap_slots(from, to)
		PlayerItemCommandService.SlotAction.MERGE: result = expected.merge_slots(from, to)
		PlayerItemCommandService.SlotAction.SPLIT: result = expected.split_stack(from, to, amount)
		PlayerItemCommandService.SlotAction.SORT: result = expected.sort_slots()
	return result != null and result.success and player.inventory.to_slot_dict() == expected.to_slot_dict()

func _visible_loot_manager() -> LootSpawnManager:
	if app.world_layer.get_child_count() != 1:
		return null
	return app.world_layer.get_child(0).get_node_or_null("LootSpawnManager") as LootSpawnManager

func _slot_ui(command: Dictionary) -> bool:
	var offline := not NetworkManager.is_multiplayer_active()
	if NetworkManager.is_server():
		return false
	var presenter: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	var bag := presenter.inventory_window
	if not bag.visible:
		await _item_key(KEY_I)
	if not bag.visible or not await _click(bag.tab_buttons[InventoryWindow.Tab.CONSUMABLE]):
		return false
	var player := GameSession.get_local_player()
	var from := int(command.get("from", 0))
	var to := int(command.get("to", 4))
	var world_drop: bool = command.get("world_drop", false)
	var source := player.inventory.get_slot(from)
	if source == null or bag.slots[from].stack == null or (not world_drop and player.inventory.get_slot(to) != null):
		return false
	var before := _slot_layout(player)
	var revision := player.item_state_revision
	var origin := bag.slots[from].get_global_rect().get_center()
	var destination := Vector2(5, 5) if world_drop else bag.slots[to].get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = origin
	motion.global_position = origin
	get_viewport().push_input(motion, true)
	var button := InputEventMouseButton.new()
	button.position = origin
	button.global_position = origin
	button.button_index = MOUSE_BUTTON_LEFT
	button.button_mask = MOUSE_BUTTON_MASK_LEFT
	button.pressed = true
	get_viewport().push_input(button, true)
	var previous := origin
	for position: Vector2 in [origin + Vector2(15, 0), destination]:
		motion = InputEventMouseMotion.new()
		motion.position = position
		motion.global_position = position
		motion.relative = position - previous
		motion.button_mask = MOUSE_BUTTON_MASK_LEFT
		get_viewport().push_input(motion, true)
		await get_tree().process_frame
		previous = position
	button = button.duplicate() as InputEventMouseButton
	button.position = destination
	button.global_position = destination
	button.button_mask = 0
	button.pressed = false
	get_viewport().push_input(button, true)
	var sequence := presenter._pending_sequence
	if sequence <= 0 or not bag._pending or not bag._sort.disabled:
		return false
	if not offline and (_slot_layout(player) != before or bag.slots[from].stack == null \
			or (not world_drop and bag.slots[to].stack != null)):
		return false
	# A second gesture and an older result must not replace the pending action.
	bag._request_sort()
	presenter._on_slot_result(sequence - 1, false, "old response")
	if presenter._pending_sequence != sequence or not bag._status.text.begins_with("Waiting") \
			or PlayerItemReplicationService._next_local_sequence != sequence or bag.selected_slot != from:
		return false
	if not await _wait(func() -> bool: return presenter._pending_sequence == -1):
		return false
	if command.get("reject", false):
		return not bag._pending and player.item_state_revision == revision and _slot_layout(player) == before \
			and bag.slots[from].stack != null and bag.slots[to].stack == null and bag.selected_slot == from \
			and bag._status.text.contains("world to finish loading")
	if world_drop:
		var manager := _visible_loot_manager()
		if manager == null or not await _wait(func() -> bool: return manager.entity_ids().size() == 1):
			return false
		var loot := manager.get_loot(manager.entity_ids()[0])
		return not bag._pending and bag._status.text.is_empty() and player.item_state_revision == revision + 1 \
			and player.inventory.get_slot(from) == null and bag.slots[from].stack == null \
			and loot != null and loot.stack.to_dict() == source.to_dict()
	var moved := player.inventory.get_slot(to)
	return not bag._pending and bag._status.text.is_empty() and player.item_state_revision == revision + 1 \
		and player.inventory.get_slot(from) == null and moved != null and moved.to_dict() == source.to_dict() \
		and bag.slots[from].stack == null and bag.slots[to].stack != null \
		and bag.slots[to].stack.to_dict() == source.to_dict()

func _reject_foreign_equip(instance_id: String) -> bool:
	if NetworkManager.is_server():
		return false
	var service := _item_service()
	var player := GameSession.get_local_player()
	var before := _slot_layout(player)
	var replies: Array[bool] = []
	var receive := func(success: bool, _message: String) -> void: replies.append(success)
	service.equip_result.connect(receive)
	var sent := service.request_equip(instance_id)
	var rejected := sent and await _wait(func() -> bool: return not replies.is_empty()) and not replies[0]
	service.equip_result.disconnect(receive)
	return rejected and _slot_layout(player) == before

func _craft_field_gear(action: String, sequence_offset: int) -> bool:
	var service := get_tree().get_first_node_in_group(&"settlement_replication_service") as SettlementReplicationService
	var player := GameSession.get_local_player()
	var storage := GameSession.settlement.storage
	if service == null or NetworkManager.is_server():
		return false
	var race := action == "field_gear_race"
	var replay := action == "field_gear_replay"
	if not race and not await _wait(func() -> bool:
		return storage.count(&"moss_fiber") >= 2 and storage.count(&"rusty_scrap") >= 1
	):
		return false
	var revision := player.item_state_revision
	var before := _slot_layout(player)
	var inputs := storage.to_slot_dict()
	var moss := storage.count(&"moss_fiber")
	var scrap := storage.count(&"rusty_scrap")
	var replies: Array[CommandResult] = []
	var receive := func(success: bool, message: String) -> void: replies.append(CommandResult.make(success, message))
	service.craft_result.connect(receive)
	if replay:
		service._request_craft.rpc_id(1, &"field_gear_recipe", _field_gear_sequence + sequence_offset)
	elif role == "B" or not NetworkManager.is_multiplayer_active():
		var hud := app.get_node("UILayer/GameHUD")
		if not LocalInputContext.is_gameplay_blocked():
			service.craft_result.disconnect(receive)
			return false
		var craft_button: Button
		for button in hud.network_settlement_buttons:
			if button.text == "Craft: field_gear_recipe":
				craft_button = button
				break
		if craft_button == null or not await _click(craft_button):
			service.craft_result.disconnect(receive)
			return false
		_field_gear_sequence = SettlementReplicationService._next_local_sequence
	else:
		service.request_craft(&"field_gear_recipe")
		_field_gear_sequence = SettlementReplicationService._next_local_sequence
	var received := await _wait(func() -> bool: return replies.size() == 1)
	service.craft_result.disconnect(receive)
	if not received:
		return false
	_field_gear_won = replies[0].success
	if replay or race and not _field_gear_won:
		return not _field_gear_won and player.item_state_revision == revision and _slot_layout(player) == before \
			and (not replay or (replies[0].message.contains("stale sequence") and storage.to_slot_dict() == inputs))
	if not _field_gear_won:
		print("Field gear crafting rejected: ", replies[0].message)
		return false
	return await _wait(func() -> bool:
		return player.item_state_revision == revision + 1 and player.inventory.count(&"leaf_hat") == 1 \
			and player.inventory.count(&"acorn_necklace") == 1 and player.inventory.count(&"seed_ring") == 1 \
			and storage.count(&"moss_fiber") == (0 if race else moss - 2) \
			and storage.count(&"rusty_scrap") == (0 if race else scrap - 1)
	)

func _item_ui(command: Dictionary) -> bool:
	var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	var bag := items.inventory_window
	var gear := items.equipment_window
	var player := GameSession.get_local_player()
	var action := String(command.operation)
	var item_id := StringName(command.get("item", "leaf_vest" if action != "use" else "berry"))
	var definition := ContentRegistry.get_item(item_id) as EquipmentDefinition
	var gear_slot := definition.equipment_slot if definition != null else EquipmentDefinition.EquipmentSlot.BODY
	var stat_id := StringName(command.get("stat", "defense"))
	var target: ItemSlotView
	var instance_id := ""
	if action == "unequip":
		if not gear.visible:
			await _item_key(KEY_P)
		target = gear.slot_views[gear_slot]
	else:
		if not bag.visible:
			await _item_key(KEY_I)
		var tab := InventoryWindow.Tab.EQUIPMENT if action == "equip" else InventoryWindow.Tab.CONSUMABLE
		if not bag.visible or not await _click(bag.tab_buttons[tab]):
			return false
		if not await _wait(func() -> bool:
			return bag.slots.any(func(view: ItemSlotView) -> bool: return view.stack != null and view.stack.item_id == item_id)
		):
			return false
		for view in bag.slots:
			if view.stack != null and view.stack.item_id == item_id:
				target = view
				break
	if target == null or target.stack == null:
		return false
	var before := _slot_layout(player)
	var revision := player.item_state_revision
	var berry_count := player.inventory.count(&"berry")
	instance_id = target.stack.instance_id
	if action != "use" and instance_id.is_empty():
		return false
	if not await _click(target):
		return false
	var projected: StatBlock
	if action == "equip":
		projected = player.preview_equipment_stats(target.stack)
		if projected == null or not items.tooltip.body_label.text.contains("Change if equipped"):
			return false
	var hold_response := bool(command.get("hold_response", false))
	var delay_response := hold_response or bool(command.get("delay_response", false))
	if delay_response:
		get_tree().multiplayer_poll = false
	var event := InputEventMouseButton.new()
	event.position = target.get_global_rect().get_center()
	event.global_position = event.position
	event.button_index = MOUSE_BUTTON_LEFT
	event.double_click = true
	event.button_mask = MOUSE_BUTTON_MASK_LEFT
	event.pressed = true
	get_viewport().push_input(event, true)
	var up := event.duplicate() as InputEventMouseButton
	up.button_mask = 0
	up.pressed = false
	up.double_click = false
	get_viewport().push_input(up, true)
	if not NetworkManager.is_authoritative_simulation():
		var sequence := PlayerItemReplicationService._next_local_sequence
		var locked := items._pending_item_type >= 0 and bag._pending and _slot_layout(player) == before
		get_viewport().push_input(event, true)
		get_viewport().push_input(up, true)
		locked = locked and PlayerItemReplicationService._next_local_sequence == sequence
		if delay_response:
			var changed_tab := await _click(bag.tab_buttons[InventoryWindow.Tab.QUEST])
			await get_tree().create_timer(0.2).timeout
			locked = locked and changed_tab and bag._pending and player.item_state_revision == revision and _slot_layout(player) == before
			if not hold_response or not locked:
				get_tree().multiplayer_poll = true
		if not locked:
			print("Item GUI did not lock or submitted twice: pending=%s seq=%s->%s revision=%s->%s status=%s" % [
				bag._pending, sequence, PlayerItemReplicationService._next_local_sequence, revision, player.item_state_revision, bag._status.text])
			return false
	if hold_response:
		return true
	if not await _wait(func() -> bool: return items._pending_item_type == -1):
		return false
	if command.get("reject", false):
		return not bag._pending and player.item_state_revision == revision and _slot_layout(player) == before \
			and bag._status.text.contains("world to finish loading")
	if bag._pending or player.item_state_revision != revision + 1:
		return false
	match action:
		"equip":
			var equipped := player.equipment.equipped(gear_slot)
			return equipped != null and equipped.instance_id == instance_id and equipped.durability == int(command.get("durability", 37)) \
				and gear.slot_views[gear_slot].stack.instance_id == instance_id \
				and player.stats.value(stat_id) == float(command.get("value", 2.0)) \
				and player.stats.value(stat_id) == projected.value(stat_id) \
				and gear._stat_values[stat_id].text == "%.1f" % player.stats.value(stat_id)
		"unequip":
			return player.equipment.equipped(gear_slot) == null and gear.slot_views[gear_slot].stack == null \
				and player.inventory.stacks().any(func(stack: ItemStack) -> bool: return stack.instance_id == instance_id) \
				and player.stats.value(&"defense") == 0.0
		"use": return player.inventory.count(&"berry") == berry_count - 1
	return false

func _resume_pending_item() -> bool:
	var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	var was_pending := items.inventory_window._pending
	get_tree().multiplayer_poll = true
	return was_pending and await _wait(func() -> bool:
		return _ready_world() and items._state == GameSession.get_local_player() and not items.inventory_window._pending
	)

func _check_equipped_display() -> bool:
	var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	var gear := items.equipment_window
	if not gear.visible:
		await _item_key(KEY_P)
	var player := GameSession.get_local_player()
	if not gear.visible or items._state != player or items.inventory_window._pending or not _unique_item_instances(player):
		return false
	for item_id in [&"leaf_hat", &"acorn_necklace", &"seed_ring"]:
		var definition := ContentRegistry.get_item(item_id) as EquipmentDefinition
		var equipped := player.equipment.equipped(definition.equipment_slot)
		var view := gear.slot_views[definition.equipment_slot]
		if equipped == null or equipped.item_id != item_id or view.stack == null \
				or view.stack.instance_id != equipped.instance_id or view.stack.durability != equipped.durability \
				or not gear._durability[definition.equipment_slot].text.contains(str(equipped.durability)):
			return false
	for stat_id in gear._stat_values:
		if gear._stat_values[stat_id].text != "%.1f" % player.stats.value(stat_id):
			return false
	return true

func _item_windows_visible() -> bool:
	var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	return items.get_instance_id() == _item_presenter_id and items.inventory_window.visible \
		and items.equipment_window.visible and items._state == GameSession.get_local_player()

func _item_snapshot() -> Dictionary:
	var player := GameSession.get_local_player()
	return {"inventory": player.inventory.to_array(), "protected": player.protected_inventory.to_array(), "equipment": player.equipment.to_dict()}

func _set_input_windows(command: Dictionary) -> bool:
	var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	var bag := bool(command.bag)
	var gear := bool(command.gear)
	var connection := NetworkManager.state
	var session := GameSession.session_id
	if command.get("escape", false):
		await _item_key(KEY_ESCAPE)
	else:
		var focus := get_viewport().gui_get_focus_owner()
		if focus != null:
			focus.release_focus()
		if items.inventory_window.visible != bag:
			await _item_key(KEY_I)
		if items.equipment_window.visible != gear:
			await _item_key(KEY_P)
	return items.inventory_window.visible == bag and items.equipment_window.visible == gear \
		and LocalInputContext.is_gameplay_blocked() == (bag or gear) and not get_tree().paused \
		and NetworkManager.state == connection and GameSession.session_id == session

func _check_blocked_storage() -> bool:
	var player := GameSession.get_local_player()
	var service := _item_service()
	if not LocalInputContext.is_gameplay_blocked() or service == null or player.inventory.count(&"berry") == 0:
		return false
	var carried := player.inventory.count(&"berry")
	var storage := GameSession.settlement.storage
	var stored := storage.count(&"berry")
	var results: Array[bool] = []
	var receive := func(success: bool, _message: String) -> void: results.append(success)
	service.transfer_result.connect(receive)
	service.request_transfer(PlayerItemCommandService.TransferDirection.DEPOSIT, &"berry", 1)
	var deposited := await _wait(func() -> bool:
		return results == [true] and player.inventory.count(&"berry") == carried - 1 and storage.count(&"berry") == stored + 1
	)
	var restored := false
	if deposited:
		service.request_transfer(PlayerItemCommandService.TransferDirection.WITHDRAW, &"berry", 1)
		restored = await _wait(func() -> bool:
			return results == [true, true] and player.inventory.count(&"berry") == carried and storage.count(&"berry") == stored
		)
	service.transfer_result.disconnect(receive)
	return restored and LocalInputContext.is_gameplay_blocked()

func _probe_key(physical: Key, pressed: bool) -> void:
	var event := InputEventKey.new()
	event.keycode = physical
	event.physical_keycode = physical
	event.pressed = pressed
	if physical == KEY_SHIFT:
		event.location = KEY_LOCATION_LEFT
	Input.parse_input_event(event)
	Input.flush_buffered_events()

func _tap_probe_key(physical: Key) -> void:
	_probe_key(physical, true)
	await get_tree().process_frame
	_probe_key(physical, false)
	await get_tree().process_frame

func _check_blocked_edges() -> bool:
	var actor := _actor(_player_id)
	if actor == null or not LocalInputContext.is_gameplay_blocked():
		return false
	var leaked: Array[bool] = []
	var edge := func() -> void: leaked.append(true)
	var dodge := func(_direction: float) -> void: leaked.append(true)
	var signals := [actor.input.jump_requested, actor.input.attack_requested,
		actor.input.interact_requested, actor.input.quick_item_requested]
	for input_signal: Signal in signals:
		input_signal.connect(edge)
	actor.input.dodge_requested.connect(dodge)
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()
	for name in ["jump", "attack", "dodge", "interact", "quick"]:
		_probe_key(INPUT_KEYS[name], true)
		await get_tree().process_frame
		_probe_key(INPUT_KEYS[name], false)
	for input_signal: Signal in signals:
		input_signal.disconnect(edge)
	actor.input.dodge_requested.disconnect(dodge)
	return leaked.is_empty() and actor.input.move_vector == Vector2.ZERO

func _check_authoritative_input(player_id: StringName, command: Dictionary) -> bool:
	if not NetworkManager.is_authoritative_simulation() \
			or (command.get("held_right", false) and not Input.is_action_pressed(&"move_right")):
		return false
	var peer := GameSession.get_local_peer_id() if player_id == _player_id or player_id.is_empty() else NetworkManager.peer_id_for_player(player_id)
	var actor := NetworkManager.authoritative_actor(peer)
	if actor == null or not actor.is_simulation_authority():
		return false
	var actor_id := actor.get_instance_id()
	if not _input_edges.has(actor_id):
		var edges := [0, 0, 0]
		_input_edges[actor_id] = edges
		actor.input.jump_requested.connect(func() -> void: edges[0] += 1)
		actor.input_buffer.attack_executed.connect(func(_sequence: int, _facing: float) -> void: edges[1] += 1)
		actor.input_buffer.dodge_executed.connect(func(_sequence: int, _direction: float) -> void: edges[2] += 1)
	var direction := float(command.get("axis", 0))
	if not await _wait(func() -> bool:
		_record_authoritative_input(actor)
		var axis_matches := actor.input.move_vector == Vector2.ZERO
		if not is_zero_approx(direction):
			# A slow runner can sample after the actor reaches a collider. Measure
			# the authoritative displacement from before the key press instead.
			var displacement := actor.position.x - float(command.from_x)
			axis_matches = actor.input.move_axis * direction > 0.5 and displacement * direction > 5.0
		return axis_matches and _input_sample.sequence > int(command.get("after", -2)) \
			and _input_sample.jump >= int(command.get("jump", 0)) \
			and _input_sample.attack >= int(command.get("attack", -1)) \
			and _input_sample.dodge >= int(command.get("dodge", -1)) \
			and _input_sample.attack_executed >= int(command.get("attack_executed", 0)) \
			and _input_sample.dodge_executed >= int(command.get("dodge_executed", 0)) \
			and (not command.get("ready_action", false) or (actor.combat_action.is_idle() and actor.is_on_floor())) \
			and (not is_zero_approx(direction) or absf(actor.velocity.x) < 0.01)
	):
		return false
	if is_zero_approx(direction):
		var stopped_x := actor.position.x
		await get_tree().create_timer(0.1).timeout
		_record_authoritative_input(actor)
		return actor.input.move_vector == Vector2.ZERO and absf(actor.velocity.x) < 0.01 \
			and is_equal_approx(actor.position.x, stopped_x)
	return true

func _record_authoritative_input(actor: PlayerActor) -> void:
	var state := actor.player_state()
	var effect: ActiveEffect = state.effects.active_effects.get(&"quick_paws")
	var edges := _input_edges[actor.get_instance_id()]
	_input_sample = {"sequence": actor.network._last_received_sequence, "jump": edges[0],
		"attack_executed": edges[1], "dodge_executed": edges[2],
		"attack": actor.network_combat._last_server_sequence, "dodge": actor.network_dodge._last_server_sequence,
		"axes": str(actor.input.move_vector), "x": actor.position.x,
		"position": str(actor.position), "velocity": str(actor.velocity),
		"hunger": state.survival.hunger, "thirst": state.survival.thirst, "quick_paws": effect.remaining if effect != null else -1.0,
		"snapshot": actor.network._snapshot_sequence}

func _check_blocked_enemy_tick(player_id: StringName) -> bool:
	if not NetworkManager.is_server() or not LocalInputContext.is_gameplay_blocked():
		return false
	var root := app.get_node("ServerWorldRoot") as ServerWorldRoot
	var runtime := root.runtime(GameSession.get_peer_world_id(NetworkManager.peer_id_for_player(player_id)))
	var manager := runtime.enemy_manager() if runtime != null else null
	if manager == null or manager._enemies.is_empty():
		return false
	var enemy: EnemyAgent = manager._enemies.values()[0]
	var origin := enemy.position
	var sequence := enemy.network._sequence
	return await _wait(func() -> bool:
		return LocalInputContext.is_gameplay_blocked() and is_instance_valid(enemy) and enemy.is_simulation_authority() \
			and enemy.position.distance_to(origin) > 2.0 and enemy.network._sequence > sequence
	)

func _item_key(key: Key) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = key
	event.pressed = true
	get_viewport().push_input(event, true)
	event = event.duplicate()
	event.pressed = false
	get_viewport().push_input(event, true)
	await get_tree().process_frame
	await get_tree().process_frame

func _check_item_windows() -> bool:
	var items: InventoryPresenter = app.get_node("UILayer/GameHUD").inventory_presenter
	_item_presenter_id = items.get_instance_id()
	var focus := get_viewport().gui_get_focus_owner()
	if focus != null:
		focus.release_focus()
	var before := _item_snapshot()
	if not items.inventory_window.visible:
		await _item_key(KEY_I)
	if not items.equipment_window.visible:
		await _item_key(KEY_P)
	if not _item_windows_visible() or items.inventory_window.slots.size() != 24 or items.equipment_window.slot_views.keys() != [0, 1, 2, 3, 4]:
		return false
	var bag := items.inventory_window
	if not await _click(bag.tab_buttons[InventoryWindow.Tab.CONSUMABLE]):
		return false
	var berry := -1
	for cell in bag.slots.size():
		var stack := bag.slots[cell].stack
		if stack != null and stack.item_id == &"berry":
			berry = cell
			break
	if berry < 0 or not await _click(bag.slots[berry]):
		return false
	if bag.selected_slot != berry or bag.slots[berry].item_icon.texture == null \
			or not items.tooltip.visible or not items.tooltip.body_label.text.contains("Quantity"):
		return false
	for tab in [InventoryWindow.Tab.EQUIPMENT, InventoryWindow.Tab.OTHER, InventoryWindow.Tab.QUEST, InventoryWindow.Tab.CONSUMABLE]:
		if not await _click(bag.tab_buttons[tab]) or bag.current_tab != tab:
			return false
	await _item_key(KEY_I)
	await _item_key(KEY_P)
	if bag.visible or items.equipment_window.visible:
		return false
	await _item_key(KEY_I)
	await _item_key(KEY_P)
	_expect_item_windows = true
	return _item_windows_visible() and _item_snapshot() == before

func _click(button: Button) -> bool:
	var received := [false]
	var listener := func() -> void: received[0] = true
	button.pressed.connect(listener, CONNECT_ONE_SHOT)
	var position := button.get_global_rect().get_center()
	var motion := InputEventMouseMotion.new()
	motion.position = position
	motion.global_position = position
	button.get_viewport().push_input(motion, true)
	var down := InputEventMouseButton.new()
	down.position = position
	down.global_position = position
	down.button_index = MOUSE_BUTTON_LEFT
	down.button_mask = MOUSE_BUTTON_MASK_LEFT
	down.pressed = true
	button.get_viewport().push_input(down, true)
	await get_tree().process_frame
	var up := down.duplicate() as InputEventMouseButton
	up.pressed = false
	up.button_mask = 0
	button.get_viewport().push_input(up, true)
	await get_tree().process_frame
	await get_tree().process_frame
	if button.pressed.is_connected(listener):
		button.pressed.disconnect(listener)
	return received[0]

func _state_dump() -> Dictionary:
	var presented: Array[Dictionary] = []
	var manager := _manager()
	if manager != null:
		for peer in manager._actors:
			var actor := manager.get_actor(peer)
			presented.append({"peer": peer, "player_id": String(GameSession.get_player_id(peer)),
				"position": str(actor.position) if actor != null else "invalid", "visible": actor != null and actor.visible,
				"process": actor.process_mode if actor != null else -1, "simulation": actor != null and actor.simulation_enabled})
	var worlds: Array[Dictionary] = []
	for peer in GameSession.players:
		var world := GameSession.get_peer_world(peer)
		worlds.append({"peer": peer, "world": String(world.world_id) if world != null else "", "revision": world.revision if world != null else -1})
	var runtimes: Dictionary = {}
	if app != null:
		var root := app.get_node("ServerWorldRoot") as ServerWorldRoot
		for id in root.world_ids():
			runtimes[String(id)] = root.runtime(id).player_manager()._actors.keys()
	return {"NetworkManager": {"state": int(NetworkManager.state), "players": NetworkManager.players.keys(),
		"attachments": NetworkManager.peer_to_player, "ready": NetworkManager.world_ready_peers.keys(),
		"pending": NetworkManager._pending_world_transitions.keys(), "spawns": NetworkManager._spawn_assignments.keys(),
		"generation": NetworkManager._transport_generation, "error": NetworkManager.last_error},
		"GameSession": {"phase": int(GameSession.phase), "session_id": GameSession.session_id,
		"players": GameSession.players.keys(), "worlds": worlds, "adventures": GameSession._adventure_sessions_by_world.keys()},
		"SceneRouter": {"world": String(SceneRouter.current_world_id()), "session": SceneRouter._assignment_session_id,
		"revision": SceneRouter._assignment_revision},
		"PlayerSpawnManager": {"world": String(manager.world_id) if manager != null else "", "actors": presented, "runtimes": runtimes}}

func _wait(predicate: Callable) -> bool:
	var until := Time.get_ticks_msec() + 10000
	while not _failed and Time.get_ticks_msec() < until:
		if predicate.call():
			return true
		await get_tree().process_frame
	return false

func _write(status: String, error: String = "") -> void:
	var data := {"sequence": _sequence, "status": status, "error": error, "role": role,
		"profile_id": String(_player_id), "protocol": NetworkProtocol.VERSION, "save": SaveManager.CURRENT_VERSION,
		"profile": LocalPlayerProfile.PROFILE_VERSION, "display_server": DisplayServer.get_name(),
		"world": String(SceneRouter.current_world_id()), "peer_id": NetworkManager.local_peer_id(),
		"process_id": OS.get_process_id(), "rendering_method": RenderingServer.get_current_rendering_method(),
		"rendered_frames": Engine.get_frames_drawn(),
		"session_id": GameSession.session_id, "field_gear_won": _field_gear_won, "input_sample": _input_sample,
		"state": _state_dump(), "export_context": _context}
	var file := FileAccess.open(result_path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	var deadline := Time.get_ticks_msec() + 3000
	while DirAccess.rename_absolute(result_path + ".tmp", result_path) != OK:
		# Retry publication only. Gameplay commands have already run exactly once.
		if Time.get_ticks_msec() >= deadline:
			push_error("PLAYER ROSTER RESULT publication failed: %s" % result_path)
			get_tree().quit(1)
			return
		await get_tree().process_frame

func _fail(message: String) -> void:
	_failed = true
	print("SESSION FAILURE STATE %s" % JSON.stringify(_state_dump()))
	await _write("fail", message)
	push_error("PLAYER ROSTER PROBE FAIL %s: %s" % [role, message])
	get_tree().quit(1)
