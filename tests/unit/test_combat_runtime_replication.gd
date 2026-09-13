extends RefCounted
## Authoritative stamina replication: the server owns CombatRuntimeState, the
## reliable PlayerRuntimeSnapshot corrects it on events, and a throttled
## unreliable PlayerCombatRuntimeSnapshot mirrors regeneration. Clients never
## simulate stamina and the HUD reads the mirror, not a scene component.

const HUD_SCRIPT := preload("res://ui/game_hud.gd")
const PLAYER_TWO: StringName = &"player_22222222222222222222222222222222"
const PLAYER_THREE: StringName = &"player_33333333333333333333333333333333"

func run(t: Node) -> void:
	_test_apply_values(t)
	_test_runtime_snapshot_payload(t)
	_test_combat_snapshot_payload(t)
	_test_sequence_ordering(t)
	_test_packet_suppression(t)
	await _test_client_mirror_and_isolation(t)
	await _test_hud_reads_runtime_mirror(t)

func _test_apply_values(t: Node) -> void:
	var combat := CombatRuntimeState.new()
	combat.reset(100.0)
	t.assert_true(combat.apply_values(42.0, 120.0), "apply_values accepts a valid authoritative pair")
	t.assert_true(combat.stamina == 42.0 and combat.max_stamina == 120.0, "apply_values sets both values without clamp ordering")
	t.assert_true(combat.apply_values(0.0, 0.0), "an empty pair is a valid state")
	combat.apply_values(30.0, 60.0)
	for invalid in [[NAN, 60.0], [30.0, NAN], [INF, 60.0], [30.0, INF], [-1.0, 60.0], [30.0, -60.0], [61.0, 60.0]]:
		t.assert_true(not combat.apply_values(invalid[0], invalid[1]), "apply_values rejects %s" % [invalid])
	t.assert_true(combat.stamina == 30.0 and combat.max_stamina == 60.0, "a rejected apply_values leaves the model untouched")

func _base_runtime_payload() -> Dictionary:
	return {
		"peer_id": 42, "health": 40.0, "max_health": 100.0,
		"life_id": 3, "life_phase": PlayerRuntimeState.LifePhase.ALIVE, "facing": 1.0,
		"stamina": 75.0, "max_stamina": 100.0,
	}

func _test_runtime_snapshot_payload(t: Node) -> void:
	var snapshot := PlayerRuntimeSnapshot.new()
	snapshot.peer_id = 42
	snapshot.health = 40.0
	snapshot.max_health = 100.0
	snapshot.life_id = 3
	snapshot.facing = 1.0
	snapshot.stamina = 75.0
	snapshot.max_stamina = 100.0
	var round_trip := PlayerRuntimeSnapshot.from_payload(snapshot.to_payload())
	t.assert_true(round_trip.error_message.is_empty(), "runtime snapshot round trip keeps a valid payload")
	t.assert_true(round_trip.stamina == 75.0 and round_trip.max_stamina == 100.0, "runtime snapshot carries the authoritative stamina pair")

	for key in ["stamina", "max_stamina"]:
		var missing := _base_runtime_payload()
		missing.erase(key)
		t.assert_equal(PlayerRuntimeSnapshot.from_payload(missing).error_message, "Missing player runtime field: %s" % key, "runtime snapshot rejects a missing %s" % key)
	var invalid_values := {
		"negative stamina": {"stamina": -1.0},
		"negative max_stamina": {"stamina": 0.0, "max_stamina": -100.0},
		"stamina above max": {"stamina": 101.0},
		"NaN stamina": {"stamina": NAN},
		"INF stamina": {"stamina": INF},
		"NaN max_stamina": {"max_stamina": NAN},
		"INF max_stamina": {"max_stamina": INF},
		"String stamina": {"stamina": "75"},
		"Array max_stamina": {"max_stamina": [100.0]},
	}
	for label in invalid_values:
		var payload := _base_runtime_payload()
		payload.merge(invalid_values[label], true)
		t.assert_true(not PlayerRuntimeSnapshot.from_payload(payload).error_message.is_empty(), "runtime snapshot rejects %s" % label)

func _base_combat_payload() -> Dictionary:
	return {"peer_id": 42, "stamina": 75.0, "max_stamina": 100.0, "sequence": 4}

func _test_combat_snapshot_payload(t: Node) -> void:
	var snapshot := PlayerCombatRuntimeSnapshot.new()
	snapshot.peer_id = 42
	snapshot.stamina = 75.0
	snapshot.max_stamina = 100.0
	snapshot.sequence = 4
	var round_trip := PlayerCombatRuntimeSnapshot.from_payload(snapshot.to_payload())
	t.assert_true(round_trip.error_message.is_empty(), "combat snapshot round trip keeps a valid payload")
	t.assert_true(round_trip.peer_id == 42 and round_trip.stamina == 75.0 \
		and round_trip.max_stamina == 100.0 and round_trip.sequence == 4, "combat snapshot preserves every field")

	for key in ["peer_id", "stamina", "max_stamina", "sequence"]:
		var missing := _base_combat_payload()
		missing.erase(key)
		t.assert_equal(PlayerCombatRuntimeSnapshot.from_payload(missing).error_message, "Missing player combat runtime field: %s" % key, "combat snapshot rejects a missing %s" % key)
	var invalid_values := {
		"peer 0": {"peer_id": 0},
		"negative sequence": {"sequence": -1},
		"float sequence": {"sequence": 1.5},
		"String peer": {"peer_id": "42"},
		"negative stamina": {"stamina": -1.0},
		"negative max_stamina": {"stamina": 0.0, "max_stamina": -1.0},
		"stamina above max": {"stamina": 120.0},
		"NaN stamina": {"stamina": NAN},
		"INF max_stamina": {"max_stamina": INF},
		"String stamina": {"stamina": "75"},
		"Array stamina": {"stamina": [75.0]},
	}
	for label in invalid_values:
		var payload := _base_combat_payload()
		payload.merge(invalid_values[label], true)
		t.assert_true(not PlayerCombatRuntimeSnapshot.from_payload(payload).error_message.is_empty(), "combat snapshot rejects %s" % label)

func _test_sequence_ordering(t: Node) -> void:
	var latest := PlayerCombatRuntimeSnapshot.from_payload(_base_combat_payload())
	t.assert_true(latest.is_valid_after(3), "a newer combat sequence is accepted")
	t.assert_true(not latest.is_valid_after(4), "a duplicate combat sequence is ignored")
	t.assert_true(not latest.is_valid_after(9), "a stale combat snapshot cannot overwrite a newer value")
	var broken := _base_combat_payload()
	broken["stamina"] = NAN
	t.assert_true(not PlayerCombatRuntimeSnapshot.from_payload(broken).is_valid_after(0), "an invalid combat snapshot is never applied")

func _test_packet_suppression(t: Node) -> void:
	var component := NetworkPlayerComponent.new()
	t.assert_true(component.combat_state_changed(100.0, 100.0), "the first combat state always sends")
	component.mark_combat_sent(100.0, 100.0)
	var sends := 0
	for _frame in range(60):
		if component.combat_state_changed(100.0, 100.0):
			sends += 1
			component.mark_combat_sent(100.0, 100.0)
	t.assert_equal(sends, 0, "a player resting at full stamina produces no combat packets")
	t.assert_true(component.combat_state_changed(92.0, 100.0), "spending stamina makes the combat state dirty")
	component.mark_combat_sent(92.0, 100.0)
	t.assert_true(not component.combat_state_changed(92.0, 100.0), "an unchanged pair stays suppressed after sending")
	t.assert_true(component.combat_state_changed(92.0, 120.0), "a max_stamina modifier makes the combat state dirty")
	t.assert_true(NetworkPlayerComponent.COMBAT_STATE_INTERVAL >= 0.1, "the combat mirror is throttled well below the transform rate")
	t.assert_true(NetworkPlayerComponent.COMBAT_STATE_INTERVAL > NetworkPlayerComponent.SNAPSHOT_INTERVAL, "stamina replicates less often than position")
	component.free()

func _test_client_mirror_and_isolation(t: Node) -> void:
	GameSession.start_new_game()
	var state_b := GameSession.attach_player(42, PLAYER_TWO)
	var state_c := GameSession.attach_player(43, PLAYER_THREE)
	var runtime_b := GameSession.get_player_runtime(42)
	var runtime_c := GameSession.get_player_runtime(43)
	t.assert_true(state_b != null and state_c != null and runtime_b.combat != runtime_c.combat, "each player owns a distinct combat runtime state")
	var previous_state := NetworkManager.state
	NetworkManager.state = NetworkManager.ConnectionState.CONNECTED

	var identity_b := runtime_b.combat
	var events: Array[Array] = []
	var callback := func(peer_id: int, stamina: float, maximum: float) -> void: events.append([peer_id, stamina, maximum])
	GameSession.player_combat_runtime_changed.connect(callback)

	var payload := _base_combat_payload()
	payload["sequence"] = 1
	var snapshot := PlayerCombatRuntimeSnapshot.from_payload(payload)
	t.assert_true(GameSession.apply_player_combat_runtime_snapshot(snapshot), "client applies an authoritative combat snapshot")
	t.assert_true(runtime_b.combat == identity_b, "applying a snapshot keeps the same CombatRuntimeState object")
	t.assert_equal(GameSession.get_player_stamina(42), 75.0, "client mirrors the authoritative stamina")
	t.assert_equal(GameSession.get_player_max_stamina(42), 100.0, "client mirrors the authoritative max stamina")
	t.assert_equal(events.size(), 1, "a changed mirror emits exactly one combat signal")
	t.assert_true(GameSession.apply_player_combat_runtime_snapshot(snapshot), "reapplying the same values succeeds")
	t.assert_equal(events.size(), 1, "an unchanged mirror emits no extra signal")

	t.assert_equal(GameSession.get_player_stamina(43), runtime_c.combat.stamina, "player C stamina is untouched by player B replication")
	t.assert_true(runtime_c.combat.stamina != 75.0 or runtime_c.combat.max_stamina != 100.0 \
		or state_c.stats.value(&"max_stamina") == 100.0, "player C keeps its own combat values")
	var c_before := runtime_c.combat.stamina
	var b_only := _base_combat_payload()
	b_only["stamina"] = 10.0
	b_only["sequence"] = 2
	GameSession.apply_player_combat_runtime_snapshot(PlayerCombatRuntimeSnapshot.from_payload(b_only))
	t.assert_equal(runtime_c.combat.stamina, c_before, "a B-only combat update never writes into C")

	var unknown := _base_combat_payload()
	unknown["peer_id"] = 999
	t.assert_true(not GameSession.apply_player_combat_runtime_snapshot(PlayerCombatRuntimeSnapshot.from_payload(unknown)), "a snapshot for an unknown peer is rejected")
	var malformed := _base_combat_payload()
	malformed["stamina"] = 999.0
	t.assert_true(not GameSession.apply_player_combat_runtime_snapshot(PlayerCombatRuntimeSnapshot.from_payload(malformed)), "a malformed combat snapshot is rejected")

	var full := PlayerRuntimeSnapshot.from_payload(_base_runtime_payload())
	full.stamina = 100.0
	t.assert_true(GameSession.apply_player_runtime_snapshot(full), "the reliable runtime snapshot is applied on a client")
	t.assert_equal(GameSession.get_player_stamina(42), 100.0, "a reliable correction also carries stamina")
	t.assert_true(runtime_b.combat == identity_b, "the reliable correction keeps the combat state identity")

	GameSession.player_combat_runtime_changed.disconnect(callback)
	NetworkManager.state = previous_state
	GameSession.detach_player(42)
	GameSession.detach_player(43)
	GameSession.remove_player_state(PLAYER_TWO)
	GameSession.remove_player_state(PLAYER_THREE)
	GameSession.start_new_game()
	await t.get_tree().process_frame

func _test_hud_reads_runtime_mirror(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node.new()
	t.add_child(layer)
	SceneRouter.register_world_layer(layer)
	var hud := CanvasLayer.new()
	hud.set_script(HUD_SCRIPT)
	t.add_child(hud)
	t.assert_true(SceneRouter.go_to_settlement(), "HUD fixture loads the settlement")
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	var peer_id := GameSession.get_local_peer_id()
	var runtime := GameSession.get_player_runtime(peer_id)
	t.assert_true(hud.bound_player != null and hud.bound_player.peer_id == peer_id, "HUD binds the local player")
	t.assert_equal(hud.hud_stamina(), runtime.combat.stamina, "HUD stamina source is the runtime mirror")
	t.assert_equal(hud.hud_max_stamina(), runtime.combat.max_stamina, "HUD max stamina source is the runtime mirror")
	t.assert_true(not "stamina" in hud, "HUD owns no stamina copy of its own")
	runtime.combat.apply_values(33.0, 110.0)
	t.assert_equal(hud.hud_stamina(), 33.0, "HUD follows the mirror without owning a copy")
	t.assert_equal(hud.hud_max_stamina(), 110.0, "HUD follows the mirrored maximum")
	hud._update_vitals_label()
	t.assert_true(hud.vitals_label.text.contains("Stamina 33/110"), "HUD renders the mirrored stamina pair")
	GameSession.player_combat_runtime_changed.emit(peer_id, 12.0, 110.0)
	runtime.combat.apply_values(12.0, 110.0)
	hud._on_player_combat_runtime_changed(peer_id, 12.0, 110.0)
	t.assert_true(hud.vitals_label.text.contains("Stamina 12/110"), "the combat signal refreshes the HUD label")
	hud.queue_free()
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()
