class_name DeathResolutionService
extends RefCounted

static func resolve(player: PlayerState, settlement: SettlementState, adventure: AdventureState, rules: DifficultyDefinition, death_position: Vector2, policy: RespawnPolicy, survival_config: SurvivalConfig, session_id: String, resolver: Callable, finish_adventure: bool = true, player_adventure: PlayerAdventureState = null, owner_peer_id: int = 0, owner_player_id: StringName = &"", world_session: AdventureSession = null) -> RespawnResult:
	var result := RespawnResult.new()
	var active_session := world_session if world_session != null else adventure.active_session
	result.in_adventure = active_session != null
	if result.in_adventure:
		var carried := DeathLossPolicy.apply(player.inventory.stacks(), rules, resolver)
		var loot_source := player_adventure if player_adventure != null else active_session.get_player_adventure(owner_peer_id if owner_peer_id > 0 else 1)
		var loot := DeathLossPolicy.apply(loot_source.unsecured_loot.stacks(), rules, resolver) if loot_source != null else DeathLossResult.new()
		var gear := DeathLossPolicy.apply_equipment(player.equipment.all_equipped(), rules)
		result.inventory_lost = carried.lost + loot.lost
		result.inventory_kept = carried.kept + loot.kept
		result.equipment_lost = gear.equipment_lost
		for kept in gear.equipment_kept:
			for original in player.equipment.all_equipped():
				if original.item_id == kept.item_id and kept.durability < original.durability:
					result.equipment_damaged.append(kept)
		player.inventory.initialize(carried.kept)
		player.equipment.restore({})
		for kept in gear.equipment_kept:
			player.equipment.equip(kept)
		if finish_adventure:
			settlement.secure_loot(loot.kept)
		elif loot_source != null:
			loot_source.unsecured_loot.initialize(loot.kept)
		var dropped: Array[ItemStack] = carried.world_drops + loot.world_drops
		if rules.recovery_policy == DifficultyDefinition.RecoveryPolicy.DROP_AT_DEATH:
			dropped.append_array(gear.equipment_lost)
			if not dropped.is_empty():
				var record := DeathDropRecord.new()
				record.id = "%s-%s-%s" % [session_id, Time.get_ticks_usec(), randi()]
				record.session_id = session_id
				record.region_id = active_session.context.region_id
				record.position = death_position
				record.owner_peer_id = owner_peer_id
				record.owner_player_id = owner_player_id
				record.items = dropped
				adventure.death_drops.append(record)
				result.drops.append(record)
	else:
		# Settlement deaths recover vitals without expedition inventory penalties.
		result.inventory_kept = player.inventory.stacks()
	result.inventory_kept.append_array(player.protected_inventory.stacks())
	result.health = maxf(1.0, player.stats.value(&"max_health") * policy.health_ratio)
	result.hunger = survival_config.max_hunger * policy.hunger_ratio
	result.thirst = survival_config.max_thirst * policy.thirst_ratio
	result.position = player.last_safe_position
	player.set_health(result.health)
	player.survival.hunger = result.hunger
	player.survival.thirst = result.thirst
	return result
