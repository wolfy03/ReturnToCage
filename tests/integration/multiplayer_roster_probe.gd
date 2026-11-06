extends Node

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
var _saw_motion := false
var _saw_run := false
var _remembered: Dictionary[StringName, int] = {}

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
	app = (load("res://core/boot.tscn") as PackedScene).instantiate() as AppRoot
	add_child(app)
	await get_tree().process_frame
	await get_tree().process_frame
	_player_id = GameSession.get_local_player_id()
	_write("ready")

func _process(_delta: float) -> void:
	if _failed:
		return
	var watched := _actor(_watched_id)
	if watched != null:
		_saw_motion = _saw_motion or watched.position.distance_to(_watch_origin) > 12.0
		var visual := watched.player_visual().get_node("PlayerAnimationPresenter") as PlayerAnimationPresenter
		_saw_run = _saw_run or visual != null and visual._current_animation == &"run" and watched.facing == 1.0
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
	_execute(command)

func _execute(command: Dictionary) -> void:
	var action := String(command.action)
	var target := StringName(command.get("player", ""))
	match action:
		"host":
			app._host_game(port)
			if not await _wait(_ready_world):
				_fail("host world not ready")
				return
		"join":
			app._join_game(String(command.get("address", "127.0.0.1")), port)
			if not await _wait(_ready_world):
				_fail("join failed: %s" % NetworkManager.last_error)
				return
		"inspect":
			if not await _wait(func() -> bool: return _roster_issue(command).is_empty()):
				_fail("%s: %s" % [command.get("label", "inspect"), _roster_issue(command)])
				return
		"watch":
			var actor := _actor(target)
			if actor == null:
				_fail("missing actor to watch")
				return
			_watched_id = target
			_watch_origin = actor.position
			_saw_motion = false
			_saw_run = false
		"move":
			Input.action_press(&"move_right")
			await get_tree().create_timer(0.6).timeout
			Input.action_release(&"move_right")
			await get_tree().create_timer(0.15).timeout
		"assert_motion":
			if not await _wait(func() -> bool: return _saw_motion and _saw_run):
				var actor := _actor(_watched_id)
				var authority := NetworkManager.authoritative_actor(NetworkManager.peer_id_for_player(_watched_id)) if NetworkManager.is_server() else null
				_fail("transform/run animation missing for %s motion=%s run=%s pos=%s received=%s authority=%s" % [
					_watched_id, _saw_motion, _saw_run, actor.position if actor != null else Vector2.INF,
					actor.network._last_received_sequence if actor != null else -1,
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
			app._leave_game()
			if not await _wait(func() -> bool: return not app._menu_transition_pending and app.world_layer.get_child_count() == 0):
				_fail("scene cleanup failed")
				return
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
				_write("pass")
				print("PLAYER ROSTER PROBE PASS %s" % role)
				get_tree().quit(0)
				return
		_:
			_fail("unknown action %s" % action)
			return
	if GameSession.get_local_player_id() != _player_id:
		_fail("persistent local identity changed")
		return
	_write("pass")
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
	return manager.get_actor(NetworkManager.peer_id_for_player(id)) if manager != null and not id.is_empty() else null

func _ready_world() -> bool:
	return not app.menu.visible and NetworkManager.is_local_world_ready() and _manager() != null

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
		"world": String(SceneRouter.current_world_id()), "peer_id": NetworkManager.local_peer_id()}
	var file := FileAccess.open(result_path + ".tmp", FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "\t"))
	file.close()
	DirAccess.rename_absolute(result_path + ".tmp", result_path)

func _fail(message: String) -> void:
	_failed = true
	_write("fail", message)
	push_error("PLAYER ROSTER PROBE FAIL %s: %s" % [role, message])
	get_tree().quit(1)
