extends Node

enum ProbeState { WAITING, SETTLEMENT_UPGRADE, SETTLEMENT_CRAFT, ITEM_EQUIP, ITEM_USE, ITEM_DEPOSIT, ITEM_WITHDRAW, ITEM_RACE, PENDING_OVERFLOW, PENDING_CLAIM, HORIZONTAL, JUMPING, PREPARE_CLIMB, CLIMBING, COMBAT, ENEMY_DEATH, PICKUP, HEALTH, RESPAWN, CLEANUP, RECONNECT, FINISHED }

var role: String = ""
var port: int = NetworkManager.DEFAULT_PORT
var expected_players: int = 2
var disconnect_host: bool = false
var world: Node2D
var spawner: PlayerSpawnManager
var ladder: ClimbableArea2D
var state: ProbeState = ProbeState.WAITING
var selected_peer: int = 0
var start_position: Vector2
var deadline_msec: int
var phase_started_msec: int
var diagnostic_printed: bool = false
var client_start_position: Vector2
var client_saw_authoritative_snapshot: bool = false
var health_test_peer: int = 0
var health_confirmation_sent: bool = false
var health_confirmations: Dictionary[int, bool] = {}
var respawn_test_peer: int = 0
var client_old_actor_id: int = 0
var respawn_confirmation_sent: bool = false
var respawn_confirmations: Dictionary[int, bool] = {}
var server_old_actor_id: int = 0
var server_old_life_id: int = -1
var server_death_phase: int
var session_end_verified: bool = false
var reconnecting: bool = false
var initial_local_peer_id: int = 0
var initial_local_player_id: StringName = &""
var reconnect_confirmations: Dictionary[int, bool] = {}
var reconnect_state_refs: Dictionary[StringName, PlayerState] = {}
var reconnect_personal_refs: Dictionary[StringName, PersonalProgressionState] = {}
var reconnect_old_peers: Dictionary[StringName, int] = {}
var reconnect_item_revisions: Dictionary[StringName, int] = {}
var reconnect_hunger_values: Dictionary[StringName, float] = {}
var reconnect_thirst_values: Dictionary[StringName, float] = {}
var reconnect_speed_values: Dictionary[StringName, float] = {}
var reconnect_safe_positions: Dictionary[StringName, Vector2] = {}
var reconnect_water_counts: Dictionary[StringName, int] = {}
var reconnect_reattach_verified: Dictionary[StringName, bool] = {}
var expected_reconnect_hunger: float = -1.0
var expected_reconnect_thirst: float = -1.0
var expected_reconnect_speed: float = -1.0
var expected_reconnect_safe_position: Vector2 = Vector2(INF, INF)
var enemy_roster_confirmation_sent: bool = false
var enemy_roster_confirmations: Dictionary[int, bool] = {}
var combat_enemy_id: int = 0
var combat_enemy_health: float = 0.0
var lethal_attack_sent: bool = false
var pickup_item_id: StringName
var pickup_quantity: int = 0
var pickup_count_before: int = 0
var pickup_confirmations: Dictionary[int, bool] = {}
var quest_sync_confirmation_sent: bool = false
var quest_sync_confirmations: Dictionary[int, bool] = {}
var expected_killer_peer: int = 0
var quest_progress_confirmation_sent: bool = false
var quest_progress_confirmations: Dictionary[int, bool] = {}
var quest_result_requested: bool = false
var settlement_upgrade_expected: bool = false
var settlement_craft_expected: bool = false
var settlement_upgrade_confirmation_sent: bool = false
var settlement_craft_confirmation_sent: bool = false
var settlement_upgrade_confirmations: Dictionary[int, bool] = {}
var settlement_craft_confirmations: Dictionary[int, bool] = {}
var pending_overflow_expected: bool = false
var pending_claim_expected: bool = false
var pending_overflow_confirmation_sent: bool = false
var pending_claim_confirmation_sent: bool = false
var pending_overflow_confirmations: Dictionary[int, bool] = {}
var pending_claim_confirmations: Dictionary[int, bool] = {}
var item_equip_expected: bool = false
var item_use_expected: bool = false
var item_deposit_expected: bool = false
var item_withdraw_expected: bool = false
var item_race_expected: bool = false
var item_equip_confirmation_sent: bool = false
var item_use_confirmation_sent: bool = false
var item_deposit_confirmation_sent: bool = false
var item_withdraw_confirmation_sent: bool = false
var item_race_confirmation_sent: bool = false
var item_equip_confirmations: Dictionary[int, bool] = {}
var item_use_confirmations: Dictionary[int, bool] = {}
var item_deposit_confirmations: Dictionary[int, bool] = {}
var item_withdraw_confirmations: Dictionary[int, bool] = {}
var item_race_counts: Dictionary[int, int] = {}
const PROBE_VEST_INSTANCE := "probe_owner_vest"
const PROBE_PERSONAL_QUEST_ID: StringName = &"_probe_personal_kill"
const PROBE_PARTY_QUEST_ID: StringName = &"_probe_party_kill"
const PROBE_PERSONAL_UPGRADE_QUEST_ID: StringName = &"_probe_personal_upgrade"
const PROBE_PARTY_UPGRADE_QUEST_ID: StringName = &"_probe_party_upgrade"

func _ready() -> void:
	_parse_arguments()
	_install_probe_personal_quest()
	deadline_msec = Time.get_ticks_msec() + 15000
	NetworkManager.server_disconnected.connect(_on_server_disconnected)
	NetworkManager.multiplayer_session_ended.connect(_on_multiplayer_session_ended)
	if role == "host":
		if NetworkManager.host_game(port, expected_players) != OK or not GameSession.start_new_game():
			_fail("host setup failed")
			return
		if NetworkManager.player_id_for_peer(1) != NetworkManager.local_profile_player_id():
			_fail("host did not attach its persistent local profile identity")
			return
		NetworkManager.peer_joined.connect(_on_probe_peer_joined)
		NetworkManager.peer_left.connect(_on_probe_peer_left)
		GameSession.start_quest(&"sewer_supplies", GameSession.get_local_player_id())
		GameSession.start_quest(PROBE_PERSONAL_QUEST_ID, GameSession.get_local_player_id())
		GameSession.start_quest(PROBE_PARTY_QUEST_ID, GameSession.get_local_player_id())
		GameSession.start_quest(PROBE_PERSONAL_UPGRADE_QUEST_ID, GameSession.get_local_player_id())
		GameSession.start_quest(PROBE_PARTY_UPGRADE_QUEST_ID, GameSession.get_local_player_id())
		GameSession.settlement.storage.add_item(&"rusty_scrap", 3)
		GameSession.settlement.storage.add_item(&"berry", 2)
		GameSession.settlement.storage.add_item(&"moss_fiber", 1)
		_build_world()
		print("PROBE HOST READY")
	elif role == "client":
		NetworkManager.session_synchronized.connect(_on_session_synchronized)
		NetworkManager.connection_failed.connect(func() -> void: _fail(NetworkManager.last_error))
		if NetworkManager.join_game("127.0.0.1", port) != OK:
			_fail("client setup failed")
	else:
		_fail("missing --role=host|client")

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > deadline_msec:
		_fail("probe timed out in state %s players=%d actors=%d enemy_roster=%d quest_sync=%d" % [
			ProbeState.keys()[state], GameSession.players.size(),
			get_tree().get_nodes_in_group(&"player").size(), enemy_roster_confirmations.size(),
			quest_sync_confirmations.size(),
		])
		return
	if role == "client" and world != null:
		if not _remote_private_placeholders_are_empty():
			_fail("client received another player's private item state")
			return
		if settlement_upgrade_expected and not settlement_upgrade_confirmation_sent:
			var personal_upgrade := GameSession.progression.get_personal_progression(GameSession.get_local_player_id())
			var personal_upgrade_state: QuestState = personal_upgrade.quest_states.get(PROBE_PERSONAL_UPGRADE_QUEST_ID) if personal_upgrade != null else null
			var shared_upgrade_state: QuestState = GameSession.progression.shared_quest_states.get(PROBE_PARTY_UPGRADE_QUEST_ID)
			var expected_personal := 1 if NetworkManager.local_peer_id() == selected_peer else 0
			if GameSession.settlement.facility_levels.get(&"workbench", 0) == 1 \
					and GameSession.settlement.storage.count(&"rusty_scrap") == 0 \
					and GameSession.progression.unlocked_flags.has(&"basic_crafting") \
					and personal_upgrade_state != null and personal_upgrade_state.progress[0] == expected_personal \
					and shared_upgrade_state != null and shared_upgrade_state.progress[0] == 1:
				settlement_upgrade_confirmation_sent = true
				_confirm_settlement_upgrade.rpc_id(1)
		if settlement_craft_expected and not settlement_craft_confirmation_sent \
				and GameSession.settlement.storage.count(&"mushroom_stew") == 1 \
				and GameSession.settlement.storage.count(&"berry") == 0 \
				and GameSession.settlement.storage.count(&"moss_fiber") == 0:
			settlement_craft_confirmation_sent = true
			_confirm_settlement_craft.rpc_id(1)
		if item_equip_expected and not item_equip_confirmation_sent:
			var local_equipped := GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY)
			var owns_probe_vest := local_equipped != null and local_equipped.instance_id == PROBE_VEST_INSTANCE
			if owns_probe_vest == (NetworkManager.local_peer_id() == selected_peer):
				item_equip_confirmation_sent = true
				_confirm_item_equip.rpc_id(1)
		if item_use_expected and not item_use_confirmation_sent:
			var expected_use_berries := 1 if NetworkManager.local_peer_id() == selected_peer else 2
			if GameSession.player.inventory.count(&"berry") == expected_use_berries:
				item_use_confirmation_sent = true
				_confirm_item_use.rpc_id(1)
		if item_deposit_expected and not item_deposit_confirmation_sent:
			var expected_deposit_berries := 0 if NetworkManager.local_peer_id() == selected_peer else 2
			if GameSession.player.inventory.count(&"berry") == expected_deposit_berries \
					and GameSession.settlement.storage.count(&"berry") == 1:
				item_deposit_confirmation_sent = true
				_confirm_item_deposit.rpc_id(1)
		if item_withdraw_expected and not item_withdraw_confirmation_sent:
			var expected_withdraw_berries := 1 if NetworkManager.local_peer_id() == selected_peer else 2
			if GameSession.player.inventory.count(&"berry") == expected_withdraw_berries \
					and GameSession.settlement.storage.count(&"berry") == 0:
				item_withdraw_confirmation_sent = true
				_confirm_item_withdraw.rpc_id(1)
		if item_race_expected and not item_race_confirmation_sent \
				and GameSession.settlement.storage.count(&"rusty_scrap") == 1:
			item_race_confirmation_sent = true
			_confirm_item_race.rpc_id(1, GameSession.player.inventory.count(&"rusty_scrap"))
		if pending_overflow_expected and not pending_overflow_confirmation_sent \
				and GameSession.settlement.pending_loot.size() == 1 \
				and GameSession.settlement.pending_loot[0].item_id == &"water_drop" \
				and GameSession.settlement.pending_loot[0].quantity == 1:
			var exposed := GameSession.settlement.pending_loot
			exposed[0].quantity = 999
			exposed.clear()
			if GameSession.settlement.pending_loot.size() == 1 \
					and GameSession.settlement.pending_loot[0].quantity == 1:
				pending_overflow_confirmation_sent = true
				_confirm_pending_overflow.rpc_id(1)
		if pending_claim_expected and not pending_claim_confirmation_sent \
				and GameSession.settlement.pending_loot.is_empty() \
				and GameSession.settlement.storage.count(&"water_drop") == 1:
			pending_claim_confirmation_sent = true
			_confirm_pending_claim.rpc_id(1)
		if not quest_sync_confirmation_sent:
			var local_player_id := GameSession.get_local_player_id()
			var personal := GameSession.progression.get_personal_progression(local_player_id)
			var personal_state_count := 0
			for candidate in GameSession.progression.personal_progression.values():
				if (candidate as PersonalProgressionState).quest_states.has(PROBE_PERSONAL_QUEST_ID):
					personal_state_count += 1
			if not local_player_id.is_empty() and personal != null \
					and personal.quest_states.has(PROBE_PERSONAL_QUEST_ID) \
					and GameSession.progression.shared_quest_states.has(&"sewer_supplies") \
					and GameSession.progression.shared_quest_states.has(PROBE_PARTY_QUEST_ID) \
					and personal_state_count == 1:
				quest_sync_confirmation_sent = true
				_confirm_quest_sync.rpc_id(1, local_player_id)
		if expected_killer_peer > 0 and not quest_progress_confirmation_sent:
			var shared_state: QuestState = GameSession.progression.shared_quest_states.get(PROBE_PARTY_QUEST_ID)
			var own_progression := GameSession.progression.get_personal_progression(GameSession.get_local_player_id())
			var own_state: QuestState = own_progression.quest_states.get(PROBE_PERSONAL_QUEST_ID) if own_progression != null else null
			var expected_personal_progress := 1 if NetworkManager.local_peer_id() == expected_killer_peer else 0
			if shared_state != null and shared_state.progress[0] == 1 and own_state != null \
					and own_state.progress[0] == expected_personal_progress:
				quest_progress_confirmation_sent = true
				_confirm_quest_progress.rpc_id(1)
		if not enemy_roster_confirmation_sent:
			for candidate in world.get_children():
				if candidate is EnemyAgent and candidate.network_entity_id > 0 and not candidate.is_simulation_authority():
					enemy_roster_confirmation_sent = true
					_confirm_enemy_roster.rpc_id(1, candidate.network_entity_id)
					break
		var local_actor := _actor(NetworkManager.local_peer_id())
		if local_actor != null and local_actor.global_position.distance_to(client_start_position) > 15.0:
			client_saw_authoritative_snapshot = true
		if health_test_peer > 0 and not health_confirmation_sent:
			var health_actor := _actor(health_test_peer)
			var health_state := GameSession.get_player(health_test_peer)
			if health_actor != null and health_state != null \
				and is_equal_approx(health_actor.health.current_health, 40.0) \
				and is_equal_approx(health_state.health, 40.0):
				health_confirmation_sent = true
				_confirm_health_presentation.rpc_id(1)
		if respawn_test_peer > 0 and not respawn_confirmation_sent:
			var respawn_actor := _actor(respawn_test_peer)
			if respawn_actor != null and respawn_actor.get_instance_id() != client_old_actor_id:
				respawn_confirmation_sent = true
				_confirm_respawn_presentation.rpc_id(1)
	if role != "host" or world == null:
		return
	var actors := get_tree().get_nodes_in_group(&"player")
	match state:
		ProbeState.WAITING:
			if GameSession.players.size() == expected_players and actors.size() == expected_players \
				and enemy_roster_confirmations.size() == expected_players - 1 \
				and quest_sync_confirmations.size() == expected_players - 1:
				if not _verify_host_save_v4():
					_fail("host-authoritative Save v4 probe failed")
					return
				print("PROBE HOST PLAYERS %d" % expected_players)
				if disconnect_host:
					print("PROBE HOST EXITING")
					get_tree().quit(0)
					return
				var ids: Array[int] = []
				ids.assign(GameSession.players.keys())
				ids.sort()
				selected_peer = ids[1]
				var actor := _actor(selected_peer)
				start_position = actor.global_position
				_expect_settlement_upgrade.rpc(selected_peer)
				state = ProbeState.SETTLEMENT_UPGRADE

		ProbeState.SETTLEMENT_UPGRADE:
			if settlement_upgrade_confirmations.size() == expected_players - 1 \
					and GameSession.settlement.facility_levels.get(&"workbench", 0) == 1 \
					and GameSession.progression.unlocked_flags.has(&"basic_crafting"):
				print("PROBE SETTLEMENT UPGRADE AUTHORITY OK")
				_expect_settlement_craft.rpc(selected_peer)
				state = ProbeState.SETTLEMENT_CRAFT
		ProbeState.SETTLEMENT_CRAFT:
			if settlement_craft_confirmations.size() == expected_players - 1 \
					and GameSession.settlement.storage.count(&"mushroom_stew") == 1:
				print("PROBE SETTLEMENT CRAFT AUTHORITY OK")
				var vest := ItemStack.new(&"leaf_vest", 1)
				vest.instance_id = PROBE_VEST_INSTANCE
				vest.durability = 45
				if not GameSession.get_player(selected_peer).inventory.add_stack(vest).success:
					_fail("player item equip fixture failed")
					return
				_expect_item_equip.rpc(selected_peer)
				state = ProbeState.ITEM_EQUIP
		ProbeState.ITEM_EQUIP:
			if item_equip_confirmations.size() == expected_players - 1:
				print("PROBE OWNER-ONLY EQUIP OK")
				_expect_item_use.rpc(selected_peer)
				state = ProbeState.ITEM_USE
		ProbeState.ITEM_USE:
			if item_use_confirmations.size() == expected_players - 1:
				print("PROBE OWNER-ONLY ITEM USE OK")
				_expect_item_deposit.rpc(selected_peer)
				state = ProbeState.ITEM_DEPOSIT
		ProbeState.ITEM_DEPOSIT:
			if item_deposit_confirmations.size() == expected_players - 1:
				print("PROBE PLAYER STORAGE DEPOSIT OK")
				_expect_item_withdraw.rpc(selected_peer)
				state = ProbeState.ITEM_WITHDRAW
		ProbeState.ITEM_WITHDRAW:
			if item_withdraw_confirmations.size() == expected_players - 1:
				print("PROBE PLAYER STORAGE WITHDRAW OK")
				GameSession.settlement.storage.add_item(&"rusty_scrap", 5)
				_expect_item_race.rpc()
				state = ProbeState.ITEM_RACE
		ProbeState.ITEM_RACE:
			if item_race_counts.size() == expected_players - 1:
				var winners := 0
				for peer_id in item_race_counts:
					if item_race_counts[peer_id] == 4 and GameSession.get_player(peer_id).inventory.count(&"rusty_scrap") == 4:
						winners += 1
					elif item_race_counts[peer_id] != 0 or GameSession.get_player(peer_id).inventory.count(&"rusty_scrap") != 0:
						_fail("private inventory isolation failed during withdraw race")
						return
				if winners != 1 or GameSession.settlement.storage.count(&"rusty_scrap") != 1:
					_fail("concurrent withdraw did not produce exactly one winner")
					return
				print("PROBE CONCURRENT WITHDRAW OK")
				GameSession.settlement.storage.capacity = GameSession.settlement.storage.stacks().size()
				GameSession.adventure.active_session.get_player_adventure(selected_peer).unsecured_loot.add_item(&"water_drop", 1)
				var before_revision := GameSession.settlement.revision
				GameSession.finish_adventure(AdventureSession.Result.NORMAL_ESCAPE)
				if GameSession.settlement.pending_loot.size() != 1 \
						or GameSession.settlement.revision != before_revision + 1:
					_fail("storage-full pending loot commit failed")
					return
				_expect_pending_overflow.rpc()
				state = ProbeState.PENDING_OVERFLOW
		ProbeState.PENDING_OVERFLOW:
			if pending_overflow_confirmations.size() == expected_players - 1:
				print("PROBE PENDING LOOT MIRROR OK")
				GameSession.settlement.storage.capacity = 48
				var before_revision := GameSession.settlement.revision
				var result := GameSession.claim_pending_loot()
				if not result.success or GameSession.settlement.revision != before_revision + 1:
					_fail("pending loot claim commit failed")
					return
				_expect_pending_claim.rpc()
				state = ProbeState.PENDING_CLAIM
		ProbeState.PENDING_CLAIM:
			if pending_claim_confirmations.size() == expected_players - 1:
				print("PROBE PENDING LOOT CLAIM OK")
				_ensure_probe_adventure()
				var actor := _actor(selected_peer)
				start_position = actor.global_position
				state = ProbeState.HORIZONTAL
		ProbeState.HORIZONTAL:
			var actor := _actor(selected_peer)
			if actor != null and actor.global_position.x > start_position.x + 20.0:
				print("PROBE HOST HORIZONTAL OK")
				start_position = actor.global_position
				_begin_jump_test.rpc_id(selected_peer)
				state = ProbeState.JUMPING
		ProbeState.JUMPING:
			var actor := _actor(selected_peer)
			if actor != null and actor.global_position.y < start_position.y - 10.0:
				print("PROBE HOST JUMP OK")
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.PREPARE_CLIMB
		ProbeState.PREPARE_CLIMB:
			if Time.get_ticks_msec() - phase_started_msec > 250:
				var actor := _actor(selected_peer)
				actor.global_position = ladder.bottom() + Vector2(15, 0)
				actor.velocity = Vector2.ZERO
				actor.movement.add_climb_area(ladder)
				start_position = actor.global_position
				_begin_climb_test.rpc_id(selected_peer)
				state = ProbeState.CLIMBING
		ProbeState.CLIMBING:
			var actor := _actor(selected_peer)
			if not diagnostic_printed and Time.get_ticks_msec() - phase_started_msec > 1500:
				diagnostic_printed = true
				print("PROBE CLIMB DIAGNOSTIC axis=%.2f mode=%s pos=%s ladder=%s overlaps=%s monitoring=%s masks=%d/%d areas=%d" % [actor.input.vertical_axis, MovementComponent.Mode.keys()[actor.movement.mode], actor.global_position, ladder.global_position, ladder.overlaps_body(actor), ladder.monitoring, actor.collision_layer, ladder.collision_mask, actor.movement.climb_areas.size()])
			if actor != null and actor.global_position.y < start_position.y - 20.0:
				print("PROBE HOST CLIMB OK")
				var enemy := _enemy()
				if enemy == null:
					_fail("authoritative enemy is missing")
					return
				Input.action_release(&"move_up")
				actor.movement.exit_climb()
				actor.global_position = Vector2(700, 520)
				actor.velocity = Vector2.ZERO
				actor.facing = 1.0
				enemy.global_position = actor.global_position + Vector2(38, 0)
				enemy.health.invulnerable_remaining = 0.0
				combat_enemy_id = enemy.network_entity_id
				combat_enemy_health = enemy.health.current_health
				_begin_attack_test.rpc_id(selected_peer)
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.COMBAT
		ProbeState.COMBAT:
			var enemy := _enemy()
			if enemy != null and enemy.health.current_health < combat_enemy_health:
				print("PROBE CLIENT ATTACK AUTHORITY OK")
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.ENEMY_DEATH
		ProbeState.ENEMY_DEATH:
			var enemy := _enemy()
			if enemy != null and not lethal_attack_sent and Time.get_ticks_msec() - phase_started_msec > 800:
				lethal_attack_sent = true
				enemy.health.current_health = 1.0
				enemy.health.invulnerable_remaining = 0.0
				_begin_attack_test.rpc_id(selected_peer)
			var loot_manager := world.get_node("LootSpawnManager") as LootSpawnManager
			if lethal_attack_sent and enemy == null and not quest_result_requested:
				var killer_id := GameSession.get_player_id(selected_peer)
				var personal := GameSession.progression.get_personal_progression(killer_id)
				if personal == null or not personal.quest_states[PROBE_PERSONAL_QUEST_ID].completed \
						or not GameSession.progression.shared_quest_states[PROBE_PARTY_QUEST_ID].completed:
					_fail("server quest attribution failed")
					return
				quest_result_requested = true
				_expect_quest_result.rpc(selected_peer)
			if quest_result_requested and quest_progress_confirmations.size() == expected_players - 1 \
					and enemy == null and not loot_manager.entity_ids().is_empty():
				var loot_id := loot_manager.entity_ids()[0]
				var loot := loot_manager.get_loot(loot_id)
				var actor := _actor(selected_peer)
				loot.global_position = actor.global_position
				pickup_item_id = loot.stack.item_id
				pickup_quantity = loot.stack.quantity
				pickup_count_before = GameSession.adventure.active_session.get_player_adventure(selected_peer).unsecured_loot.count(pickup_item_id)
				_begin_pickup_test.rpc_id(selected_peer, loot_id)
				state = ProbeState.PICKUP
		ProbeState.PICKUP:
			var loot_manager := world.get_node("LootSpawnManager") as LootSpawnManager
			var personal := GameSession.adventure.active_session.get_player_adventure(selected_peer)
			if loot_manager.entity_ids().is_empty() and pickup_confirmations.has(selected_peer) \
				and personal.unsecured_loot.count(pickup_item_id) == pickup_count_before + pickup_quantity:
				print("PROBE LOOT CLAIM AUTHORITY OK")
				GameSession.get_player(selected_peer).set_health(40.0)
				_begin_health_test.rpc(selected_peer)
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.HEALTH
		ProbeState.HEALTH:
			if health_confirmations.size() == expected_players - 1:
				print("PROBE CLIENT HEALTH PRESENTATION OK")
				var actor := _actor(selected_peer)
				server_old_actor_id = actor.get_instance_id()
				server_old_life_id = GameSession.get_player_life_id(selected_peer)
				server_death_phase = GameSession.phase
				_begin_respawn_test.rpc(selected_peer)
				actor.health.receive_damage(DamageContext.new(10000.0, &"probe", self, &"test"))
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.RESPAWN
		ProbeState.RESPAWN:
			var actor := _actor(selected_peer)
			if actor != null and actor.get_instance_id() != server_old_actor_id \
				and GameSession.get_player_life_id(selected_peer) > server_old_life_id \
				and GameSession.phase == server_death_phase \
				and respawn_confirmations.size() == expected_players - 1:
				print("PROBE REMOTE PLAYER RESPAWN OK")
				GameSession.settlement.storage.capacity = GameSession.settlement.storage.stacks().size()
				var pending_result := GameSession.settlement.secure_loot([ItemStack.new(&"moss_fiber", 1)])
				if pending_result.success or GameSession.settlement.pending_loot.size() != 1:
					_fail("reconnect pending loot fixture failed")
					return
				if not _prepare_reconnect_state():
					return
				_probe_done.rpc()
				phase_started_msec = Time.get_ticks_msec()
				state = ProbeState.CLEANUP
		ProbeState.CLEANUP:
			if GameSession.players.size() == 1 and Time.get_ticks_msec() - phase_started_msec > 250:
				for player_id in reconnect_state_refs:
					if GameSession.get_player_state_by_player_id(player_id) != reconnect_state_refs[player_id] \
							or NetworkManager.peer_id_for_player(player_id) != 0:
						_fail("disconnect did not preserve a detached PlayerState with no active peer mapping")
						return
				print("PROBE HOST CLEANUP OK")
				state = ProbeState.RECONNECT
		ProbeState.RECONNECT:
			if GameSession.players.size() == expected_players \
				and get_tree().get_nodes_in_group(&"player").size() == expected_players \
				and reconnect_reattach_verified.size() == expected_players - 1 \
				and reconnect_confirmations.size() == expected_players - 1:
				print("PROBE FRESH RECONNECT OK")
				_reconnect_done.rpc()
				print("MULTIPLAYER PROBE PASS")
				state = ProbeState.FINISHED
				get_tree().create_timer(0.75).timeout.connect(func() -> void: get_tree().quit(0))

func _verify_host_save_v4() -> bool:
	var path := "user://multiplayer_host_save_v4_probe.json"
	# The combat probe builds its adventure subtree before changing the session
	# phase. Temporarily remove that fixture so this check exercises the real
	# settlement-only host save policy without changing gameplay state.
	var active_adventure := GameSession.adventure.active_session
	GameSession.adventure.active_session = null
	var saved_ok := SaveManager.save_game(path)
	GameSession.adventure.active_session = active_adventure
	if not saved_ok:
		print("PROBE HOST SAVE DENIED: %s" % SaveManager.can_save().message)
		return false
	var file := FileAccess.open(path, FileAccess.READ)
	var parser := JSON.new()
	var valid: bool = file != null and parser.parse(file.get_as_text()) == OK and parser.data is Dictionary \
		and parser.data.get("format_version") == 4.0 \
		and parser.data.get("players", {}).size() == expected_players
	if not valid:
		print("PROBE HOST SAVE INVALID: parsed=%s version=%s players=%s expected=%s" % [
			parser.data is Dictionary,
			parser.data.get("format_version", -1) if parser.data is Dictionary else -1,
			parser.data.get("players", {}).size() if parser.data is Dictionary else -1,
			expected_players,
		])
	for suffix in ["", ".tmp", ".bak"]:
		if FileAccess.file_exists(path + suffix):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path + suffix))
	return valid

func _parse_arguments() -> void:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--role="):
			role = argument.trim_prefix("--role=")
		elif argument.begins_with("--port="):
			port = int(argument.trim_prefix("--port="))
		elif argument.begins_with("--players="):
			expected_players = int(argument.trim_prefix("--players="))
		elif argument == "--disconnect-host":
			disconnect_host = true

func _install_probe_personal_quest() -> void:
	var objective := QuestObjectiveDefinition.new()
	objective.type = QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY
	objective.target_id = &"sewer_beetle"
	objective.required_amount = 1
	var definition := QuestDefinition.new()
	definition.id = PROBE_PERSONAL_QUEST_ID
	definition.title = "Probe Personal Kill"
	definition.scope = QuestDefinition.Scope.PERSONAL
	definition.objectives = [objective]
	ContentRegistry._definitions[definition.id] = definition
	var party := definition.duplicate() as QuestDefinition
	party.id = PROBE_PARTY_QUEST_ID
	party.title = "Probe Party Kill"
	party.scope = QuestDefinition.Scope.PARTY
	ContentRegistry._definitions[party.id] = party
	var upgrade_objective := QuestObjectiveDefinition.new()
	upgrade_objective.type = QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY
	upgrade_objective.target_id = &"workbench"
	upgrade_objective.required_amount = 1
	var personal_upgrade := QuestDefinition.new()
	personal_upgrade.id = PROBE_PERSONAL_UPGRADE_QUEST_ID
	personal_upgrade.title = "Probe Personal Upgrade"
	personal_upgrade.scope = QuestDefinition.Scope.PERSONAL
	personal_upgrade.objectives = [upgrade_objective]
	ContentRegistry._definitions[personal_upgrade.id] = personal_upgrade
	var party_upgrade := personal_upgrade.duplicate() as QuestDefinition
	party_upgrade.id = PROBE_PARTY_UPGRADE_QUEST_ID
	party_upgrade.title = "Probe Party Upgrade"
	party_upgrade.scope = QuestDefinition.Scope.PARTY
	ContentRegistry._definitions[party_upgrade.id] = party_upgrade

func _on_probe_peer_joined(peer_id: int) -> void:
	var player_id := GameSession.get_player_id(peer_id)
	if state == ProbeState.RECONNECT and reconnect_state_refs.has(player_id):
		var attached := GameSession.get_player(peer_id)
		var personal := GameSession.progression.get_personal_progression(player_id)
		var attached_vest := attached.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY) if attached != null else null
		var adventure_state := GameSession.adventure.active_session.get_player_adventure(peer_id) \
			if GameSession.adventure.active_session != null else null
		if attached != reconnect_state_refs[player_id] \
				or personal != reconnect_personal_refs[player_id] \
				or not is_equal_approx(attached.health, 37.0) \
				or not is_equal_approx(attached.survival.hunger, reconnect_hunger_values[player_id]) \
				or not is_equal_approx(attached.survival.thirst, reconnect_thirst_values[player_id]) \
				or not is_equal_approx(attached.stats.base_values[&"move_speed"], reconnect_speed_values[player_id]) \
				or not attached.effects.active_effects.has(&"quick_paws") \
				or attached.last_safe_position != reconnect_safe_positions[player_id] \
				or attached.inventory.count(&"water_drop") != reconnect_water_counts[player_id] \
				or attached.protected_inventory.count(&"berry") != 1 \
				or attached_vest == null or not attached_vest.instance_id.begins_with("reconnect_vest_") \
				or attached.item_state_revision != reconnect_item_revisions[player_id] \
				or adventure_state == null or not adventure_state.unsecured_loot.stacks().is_empty():
			_fail("persistent reattach mismatch state=%s personal=%s health=%s hunger=%s safe=%s water=%s protected=%s vest=%s revision=%s/%s adventure=%s loot=%s" % [
				attached == reconnect_state_refs[player_id], personal == reconnect_personal_refs[player_id],
				attached.health if attached != null else -1, attached.survival.hunger if attached != null else -1,
				attached.last_safe_position if attached != null else Vector2.ZERO,
				attached.inventory.count(&"water_drop") if attached != null else -1,
				attached.protected_inventory.count(&"berry") if attached != null else -1,
				attached_vest.instance_id if attached_vest != null else "missing",
				attached.item_state_revision if attached != null else -1, reconnect_item_revisions[player_id],
				adventure_state != null, adventure_state.unsecured_loot.stacks().size() if adventure_state != null else -1,
			])
			return
		reconnect_reattach_verified[player_id] = true
	if not player_id.is_empty():
		GameSession.start_quest(PROBE_PERSONAL_QUEST_ID, player_id)
		GameSession.start_quest(PROBE_PERSONAL_UPGRADE_QUEST_ID, player_id)

func _on_probe_peer_left(peer_id: int) -> void:
	for player_id in reconnect_old_peers:
		if reconnect_old_peers[player_id] == peer_id:
			if GameSession.has_player(peer_id) or GameSession.get_player_runtime(peer_id) != null:
				_fail("disconnect left an active player or runtime attachment")
			var detached := GameSession.get_player_state_by_player_id(player_id)
			if detached != null:
				# Active-world survival may drain between fixture setup and transport
				# detach. Freeze the detached canonical record at the announced values
				# so the reconnect payload has a deterministic process-probe oracle.
				detached.survival.hunger = reconnect_hunger_values[player_id]
				detached.survival.thirst = reconnect_thirst_values[player_id]
			return

func _prepare_reconnect_state() -> bool:
	var peer_ids: Array[int] = []
	peer_ids.assign(GameSession.players.keys())
	peer_ids.sort()
	for peer_id in peer_ids:
		if peer_id == 1:
			continue
		var player_id := GameSession.get_player_id(peer_id)
		var player_state := GameSession.get_player(peer_id)
		var personal := GameSession.progression.get_personal_progression(player_id)
		var player_adventure := GameSession.adventure.active_session.get_player_adventure(peer_id) \
			if GameSession.adventure.active_session != null else null
		if player_id.is_empty() or player_state == null or personal == null or player_adventure == null:
			_fail("reconnect persistence fixture could not resolve player ownership")
			return false
		player_state.set_health(37.0)
		var private_index := peer_ids.find(peer_id)
		var speed := 231.0 + float(private_index)
		var hunger := 31.0 + float(private_index)
		var thirst := 41.0 + float(private_index)
		var safe_position := Vector2(321 + private_index * 7, 432 + private_index * 11)
		player_state.stats.set_base(&"move_speed", speed)
		player_state.survival.hunger = hunger
		player_state.survival.thirst = thirst
		player_state.effects.apply_effect(ContentRegistry.get_definition(&"quick_paws") as EffectDefinition, ItemDefinition.FoodSlot.SNACK)
		player_state.last_safe_position = safe_position
		if not player_state.inventory.add_item(&"water_drop", 1).success:
			_fail("reconnect persistence item fixture failed")
			return false
		if not player_state.protected_inventory.add_item(&"berry", 1).success:
			_fail("reconnect protected inventory fixture failed")
			return false
		var reconnect_vest := ItemStack.new(&"leaf_vest", 1)
		reconnect_vest.instance_id = "reconnect_vest_%s" % String(player_id).trim_prefix("player_")
		reconnect_vest.durability = 33
		player_state.equipment.equip(reconnect_vest)
		player_adventure.unsecured_loot.add_item(&"moss_fiber", 2)
		reconnect_state_refs[player_id] = player_state
		reconnect_personal_refs[player_id] = personal
		reconnect_old_peers[player_id] = peer_id
		reconnect_item_revisions[player_id] = player_state.item_state_revision
		reconnect_hunger_values[player_id] = player_state.survival.hunger
		reconnect_thirst_values[player_id] = player_state.survival.thirst
		reconnect_speed_values[player_id] = player_state.stats.base_values[&"move_speed"]
		reconnect_safe_positions[player_id] = player_state.last_safe_position
		reconnect_water_counts[player_id] = player_state.inventory.count(&"water_drop")
		_expect_reconnect_private.rpc_id(peer_id, speed, hunger, thirst, safe_position)
	return true

@rpc("authority", "call_remote", "reliable")
func _expect_reconnect_private(speed: float, hunger: float, thirst: float, safe_position: Vector2) -> void:
	expected_reconnect_speed = speed
	expected_reconnect_hunger = hunger
	expected_reconnect_thirst = thirst
	expected_reconnect_safe_position = safe_position

@rpc("authority", "call_remote", "reliable")
func _expect_settlement_upgrade(command_peer_id: int) -> void:
	selected_peer = command_peer_id
	settlement_upgrade_expected = true
	if NetworkManager.local_peer_id() == command_peer_id:
		var service := get_tree().get_first_node_in_group(&"settlement_replication_service") as SettlementReplicationService
		if service != null:
			service.request_upgrade_facility(&"workbench")

@rpc("any_peer", "call_remote", "reliable")
func _confirm_settlement_upgrade() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		settlement_upgrade_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _expect_settlement_craft(command_peer_id: int) -> void:
	selected_peer = command_peer_id
	settlement_craft_expected = true
	if NetworkManager.local_peer_id() == command_peer_id:
		var service := get_tree().get_first_node_in_group(&"settlement_replication_service") as SettlementReplicationService
		if service != null:
			service.request_craft(&"stew_recipe")

@rpc("any_peer", "call_remote", "reliable")
func _confirm_settlement_craft() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		settlement_craft_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _expect_item_equip(command_peer_id: int) -> void:
	selected_peer = command_peer_id
	item_equip_expected = true
	if NetworkManager.local_peer_id() == command_peer_id:
		var service := get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
		if service != null:
			service.request_equip(PROBE_VEST_INSTANCE)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_item_equip() -> void:
	if NetworkManager.is_server():
		item_equip_confirmations[multiplayer.get_remote_sender_id()] = true

@rpc("authority", "call_remote", "reliable")
func _expect_item_use(command_peer_id: int) -> void:
	selected_peer = command_peer_id
	item_use_expected = true
	if NetworkManager.local_peer_id() == command_peer_id:
		var service := get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
		if service != null:
			service.request_use_item(&"berry")

@rpc("any_peer", "call_remote", "reliable")
func _confirm_item_use() -> void:
	if NetworkManager.is_server():
		item_use_confirmations[multiplayer.get_remote_sender_id()] = true

@rpc("authority", "call_remote", "reliable")
func _expect_item_deposit(command_peer_id: int) -> void:
	selected_peer = command_peer_id
	item_deposit_expected = true
	if NetworkManager.local_peer_id() == command_peer_id:
		var service := get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
		if service != null:
			service.request_transfer(PlayerItemCommandService.TransferDirection.DEPOSIT, &"berry", 1)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_item_deposit() -> void:
	if NetworkManager.is_server():
		item_deposit_confirmations[multiplayer.get_remote_sender_id()] = true

@rpc("authority", "call_remote", "reliable")
func _expect_item_withdraw(command_peer_id: int) -> void:
	selected_peer = command_peer_id
	item_withdraw_expected = true
	if NetworkManager.local_peer_id() == command_peer_id:
		var service := get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
		if service != null:
			service.request_transfer(PlayerItemCommandService.TransferDirection.WITHDRAW, &"berry", 1)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_item_withdraw() -> void:
	if NetworkManager.is_server():
		item_withdraw_confirmations[multiplayer.get_remote_sender_id()] = true

@rpc("authority", "call_remote", "reliable")
func _expect_item_race() -> void:
	item_race_expected = true
	var service := get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
	if service != null:
		service.request_transfer(PlayerItemCommandService.TransferDirection.WITHDRAW, &"rusty_scrap", 4)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_item_race(item_count: int) -> void:
	if not NetworkManager.is_server() or item_count < 0 or item_count > 4:
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		item_race_counts[sender] = item_count

@rpc("authority", "call_remote", "reliable")
func _expect_pending_overflow() -> void:
	pending_overflow_expected = true

@rpc("any_peer", "call_remote", "reliable")
func _confirm_pending_overflow() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		pending_overflow_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _expect_pending_claim() -> void:
	pending_claim_expected = true

@rpc("any_peer", "call_remote", "reliable")
func _confirm_pending_claim() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		pending_claim_confirmations[sender] = true

@rpc("any_peer", "call_remote", "reliable")
func _confirm_quest_sync(player_id: StringName) -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.player_id_for_peer(sender) == player_id:
		quest_sync_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _expect_quest_result(killer_peer_id: int) -> void:
	expected_killer_peer = killer_peer_id

@rpc("any_peer", "call_remote", "reliable")
func _confirm_quest_progress() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		quest_progress_confirmations[sender] = true

func _on_session_synchronized() -> void:
	if reconnecting:
		if not is_equal_approx(GameSession.player.stats.base_values.get(&"move_speed", -1.0), expected_reconnect_speed) \
				or not is_equal_approx(GameSession.player.survival.hunger, expected_reconnect_hunger) \
				or not is_equal_approx(GameSession.player.survival.thirst, expected_reconnect_thirst) \
				or not GameSession.player.effects.active_effects.has(&"quick_paws") \
				or GameSession.player.last_safe_position != expected_reconnect_safe_position:
			_fail("owner-private state was incomplete before session_synchronized speed=%s/%s hunger=%s/%s thirst=%s/%s effect=%s safe=%s/%s" % [
				GameSession.player.stats.base_values.get(&"move_speed", -1.0), expected_reconnect_speed,
				GameSession.player.survival.hunger, expected_reconnect_hunger,
				GameSession.player.survival.thirst, expected_reconnect_thirst,
				GameSession.player.effects.active_effects.has(&"quick_paws"),
				GameSession.player.last_safe_position, expected_reconnect_safe_position,
			])
			return
		print("PROBE OWNER-PRIVATE RECONNECT SYNC OK")
	_build_world()
	await get_tree().create_timer(0.5).timeout
	var local_actor := _actor(NetworkManager.local_peer_id())
	if local_actor == null:
		_fail("client local actor was not spawned by the server roster")
		return
	if reconnecting:
		var reconnect_weapon := GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND)
		var reconnect_vest := GameSession.player.equipment.equipped(EquipmentDefinition.EquipmentSlot.BODY)
		var reconnect_personal := GameSession.progression.get_personal_progression(GameSession.get_local_player_id())
		var reconnect_kill_state: QuestState = reconnect_personal.quest_states.get(PROBE_PERSONAL_QUEST_ID) if reconnect_personal != null else null
		var expected_personal_kills := 1 if initial_local_peer_id == expected_killer_peer else 0
		if NetworkManager.local_peer_id() == initial_local_peer_id \
				or GameSession.get_local_player_id() != initial_local_player_id \
				or GameSession.settlement.facility_levels.get(&"workbench", 0) != 1 \
				or GameSession.settlement.storage.count(&"mushroom_stew") != 1 \
				or not GameSession.progression.unlocked_flags.has(&"basic_crafting") \
				or GameSession.settlement.pending_loot.size() != 1 \
				or GameSession.settlement.pending_loot[0].item_id != &"moss_fiber" \
				or not is_equal_approx(GameSession.player.health, 37.0) \
				or not is_equal_approx(local_actor.health.current_health, 37.0) \
				or GameSession.player.inventory.count(&"water_drop") != 2 \
				or GameSession.player.item_state_revision <= 0 \
				or reconnect_kill_state == null or reconnect_kill_state.progress[0] != expected_personal_kills \
				or reconnect_vest == null or not reconnect_vest.instance_id.begins_with("reconnect_vest_") \
				or reconnect_vest.durability != 33 \
				or reconnect_weapon == null or reconnect_weapon.item_id != &"twig_sword":
			_fail("fresh reconnect did not receive current settlement snapshot peer=%s/%s identity=%s/%s facility=%s storage=%s flag=%s pending=%s health=%s actor_health=%s water=%s item_rev=%s quest=%s/%s vest=%s/%s/%s weapon=%s" % [
				NetworkManager.local_peer_id(), initial_local_peer_id,
				GameSession.get_local_player_id(), initial_local_player_id,
				GameSession.settlement.facility_levels.get(&"workbench", 0),
				GameSession.settlement.storage.count(&"mushroom_stew"),
				GameSession.progression.unlocked_flags.has(&"basic_crafting"),
				GameSession.settlement.pending_loot.size(), GameSession.player.health,
				local_actor.health.current_health, GameSession.player.inventory.count(&"water_drop"),
				GameSession.player.item_state_revision,
				reconnect_kill_state.progress[0] if reconnect_kill_state != null else -1,
				expected_personal_kills,
				reconnect_vest.instance_id if reconnect_vest != null else "missing",
				reconnect_vest.durability if reconnect_vest != null else -1,
				GameSession.get_local_player_id(),
				reconnect_weapon.item_id if reconnect_weapon != null else &"missing",
			])
			return
		print("PROBE CLIENT FRESH RECONNECT OK")
		_confirm_reconnect.rpc_id(1)
		return
	initial_local_peer_id = NetworkManager.local_peer_id()
	initial_local_player_id = GameSession.get_local_player_id()
	if initial_local_player_id != NetworkManager.local_profile_player_id():
		_fail("client session identity differs from its persistent local profile")
		return
	if not _remote_private_placeholders_are_empty():
		_fail("client received another player's private item state")
		return
	client_start_position = local_actor.global_position
	Input.action_press(&"move_right")
	print("PROBE CLIENT WORLD READY")

func _build_world() -> void:
	_ensure_probe_adventure()
	world = (load("res://world/adventure/sewer_region.tscn") as PackedScene).instantiate() as Node2D
	world.name = "NetworkProbeWorld"
	world.call("configure", AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", &"normal", GameSession.session_id))
	# The legacy combat probe deliberately presents Sewer while retaining the
	# safe-boundary session model. It runs without Boot's ServerWorldRoot, so its
	# single host scene is also the explicit authoritative runtime fixture.
	var probe_player_spawner := world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	probe_player_spawner.configure_world(&"settlement")
	(world.get_node("EnemySpawnManager") as EnemySpawnManager).configure_world(
		&"settlement", NetworkManager.is_server()
	)
	(world.get_node("LootSpawnManager") as LootSpawnManager).configure_world(
		&"settlement", NetworkManager.is_server()
	)
	if NetworkManager.is_server():
		probe_player_spawner.authoritative_runtime = true
		world.set("server_runtime_mode", true)
	add_child(world)
	ladder = world.get_node("EmergencyLadder") as ClimbableArea2D
	spawner = world.get_node("PlayerSpawnManager") as PlayerSpawnManager
	if not NetworkManager.is_server():
		var spawn_assignment := spawner.local_spawn_assignment()
		if spawn_assignment == null or spawn_assignment.player_id != GameSession.get_local_player_id() \
				or spawn_assignment.session_id != GameSession.session_id:
			_fail("client world did not consume its session-bound authoritative spawn assignment")
			return
		print("PROBE AUTHORITATIVE SPAWN %d %s" % [spawn_assignment.spawn_kind, spawn_assignment.position])
	(world.get_node("LootSpawnManager") as LootSpawnManager).pickup_result.connect(_on_probe_pickup_result)
	for enemy in get_tree().get_nodes_in_group(&"enemy"):
		enemy.set_physics_process(false)

func _remote_private_placeholders_are_empty() -> bool:
	var start := GameSession.get_start_definition()
	for peer_id in GameSession.players:
		if peer_id == NetworkManager.local_peer_id():
			continue
		var state := GameSession.get_player(peer_id)
		if state == null or not state.inventory.stacks().is_empty() \
				or not state.protected_inventory.stacks().is_empty() \
				or not state.equipment.all_equipped().is_empty() \
				or state.stats.to_dict() != _start_stats_payload(start) \
				or state.survival.to_dict() != _start_survival_payload(start) \
				or not state.effects.active_effects.is_empty() \
				or state.last_safe_position != start.last_safe_position:
			return false
	return true

func _start_stats_payload(start: GameStartDefinition) -> Dictionary:
	var stats := StatBlock.new()
	stats.base_values = start.player_stats.duplicate()
	return stats.to_dict()

func _start_survival_payload(start: GameStartDefinition) -> Dictionary:
	var survival := SurvivalState.new()
	survival.reset(start)
	return survival.to_dict()

func _ensure_probe_adventure() -> void:
	if GameSession.adventure.active_session != null:
		return
	var probe_context := AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", &"normal", GameSession.session_id)
	GameSession.adventure.active_session = AdventureSession.new(probe_context, Callable(ContentRegistry, "get_item"))
	GameSession.adventure.active_session.set_compatibility_peer_id(GameSession.get_local_peer_id(), Callable(ContentRegistry, "get_item"))
	for peer_id in GameSession.players:
		GameSession.adventure.active_session.register_player(peer_id, Callable(ContentRegistry, "get_item"))
	# This legacy probe keeps its participants in the Settlement world while it
	# exercises the old combat/loot fixture. Bind that fixture explicitly to the
	# authoritative world registry used by current gameplay services.
	GameSession._adventure_sessions_by_world[&"settlement"] = GameSession.adventure.active_session

func _actor(peer_id: int) -> PlayerActor:
	return world.get_node_or_null("Player_%d" % peer_id) as PlayerActor

func _enemy() -> EnemyAgent:
	if world == null:
		return null
	for child in world.get_children():
		if child is EnemyAgent:
			return child
	return null

@rpc("authority", "call_remote", "reliable")
func _begin_attack_test() -> void:
	Input.action_release(&"move_right")
	Input.action_release(&"move_up")
	var event := InputEventAction.new()
	event.action = &"primary_attack"
	event.pressed = true
	var actor := _actor(NetworkManager.local_peer_id())
	if actor != null:
		actor.input._unhandled_input(event)

@rpc("authority", "call_remote", "reliable")
func _begin_pickup_test(entity_id: int) -> void:
	var manager := world.get_node("LootSpawnManager") as LootSpawnManager
	var attempts := 0
	while manager.get_loot(entity_id) == null and attempts < 30:
		await get_tree().process_frame
		attempts += 1
	manager.request_pickup(entity_id)

func _on_probe_pickup_result(success: bool, _item_id: StringName, _quantity: int, _message: String) -> void:
	if success:
		_confirm_pickup.rpc_id(1)

@rpc("any_peer", "call_remote", "reliable")
func _confirm_pickup() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		pickup_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _begin_jump_test() -> void:
	Input.action_release(&"move_right")
	var event := InputEventAction.new()
	event.action = &"jump"
	event.pressed = true
	var actor := _actor(NetworkManager.local_peer_id())
	if actor != null:
		actor.input._unhandled_input(event)
	print("PROBE CLIENT JUMP INPUT")

@rpc("authority", "call_remote", "reliable")
func _begin_climb_test() -> void:
	Input.action_release(&"move_right")
	Input.action_press(&"move_up")
	print("PROBE CLIENT CLIMB INPUT")

@rpc("authority", "call_remote", "reliable")
func _begin_health_test(peer_id: int) -> void:
	health_test_peer = peer_id

@rpc("any_peer", "call_remote", "reliable")
func _confirm_health_presentation() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		health_confirmations[sender] = true

@rpc("any_peer", "call_remote", "reliable")
func _confirm_enemy_roster(entity_id: int) -> void:
	if not NetworkManager.is_server() or entity_id <= 0:
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		enemy_roster_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _begin_respawn_test(peer_id: int) -> void:
	respawn_test_peer = peer_id
	var actor := _actor(peer_id)
	client_old_actor_id = actor.get_instance_id() if actor != null else 0

@rpc("any_peer", "call_remote", "reliable")
func _confirm_respawn_presentation() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		respawn_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _probe_done() -> void:
	Input.action_release(&"move_right")
	Input.action_release(&"move_up")
	var peer_ids: Array[int] = []
	peer_ids.assign(GameSession.players.keys())
	peer_ids.sort()
	var disconnect_delay := 0.2 + maxf(0.0, float(peer_ids.find(NetworkManager.local_peer_id()) - 1)) * 0.5
	await get_tree().create_timer(disconnect_delay).timeout
	if not client_saw_authoritative_snapshot:
		_fail("client did not display an authoritative transform snapshot")
		return
	print("PROBE CLIENT MOVEMENT OK")
	NetworkManager.leave_game()
	if not session_end_verified:
		_fail("manual leave did not complete the network session lifecycle")
		return
	var retired_world := world
	world = null
	if is_instance_valid(retired_world):
		remove_child(retired_world)
		retired_world.queue_free()
	await get_tree().create_timer(1.0).timeout
	reconnecting = true
	session_end_verified = false
	if NetworkManager.join_game("127.0.0.1", port) != OK:
		_fail("fresh reconnect setup failed")

@rpc("any_peer", "call_remote", "reliable")
func _confirm_reconnect() -> void:
	if not NetworkManager.is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if NetworkManager.has_peer(sender):
		reconnect_confirmations[sender] = true

@rpc("authority", "call_remote", "reliable")
func _reconnect_done() -> void:
	var peer_ids: Array[int] = []
	peer_ids.assign(GameSession.players.keys())
	peer_ids.sort()
	var leave_delay := 0.1 + maxf(0.0, float(peer_ids.find(NetworkManager.local_peer_id()) - 1)) * 0.2
	await get_tree().create_timer(leave_delay).timeout
	NetworkManager.leave_game()
	if not session_end_verified:
		_fail("fresh reconnect did not end cleanly")
		return
	get_tree().quit(0)

func _on_multiplayer_session_ended(reason: String) -> void:
	if role != "client":
		return
	if NetworkManager.state != NetworkManager.ConnectionState.OFFLINE \
		or not NetworkManager.players.is_empty() or not NetworkManager.world_ready_peers.is_empty() \
		or GameSession.players.size() != 1 or GameSession.persistent_player_count() != 1 \
		or GameSession.get_local_player_id() != NetworkManager.local_profile_player_id() \
		or GameSession.phase != GameSession.Phase.MENU \
		or not GameSession.session_id.is_empty():
		_fail("session-end signal fired before cleanup completed")
		return
	session_end_verified = true
	print("PROBE CLIENT SESSION END OK %s" % reason)

func _on_server_disconnected() -> void:
	if role == "client" and disconnect_host:
		if not session_end_verified:
			_fail("server disconnect did not complete the network session lifecycle")
			return
		print("PROBE CLIENT HOST DISCONNECT OK")
		print("MULTIPLAYER PROBE PASS")
		get_tree().quit(0)
	elif role == "client":
		_fail("server disconnected before probe completion")

func _fail(message: String) -> void:
	push_error("MULTIPLAYER PROBE FAIL: %s" % message)
	get_tree().quit(1)
