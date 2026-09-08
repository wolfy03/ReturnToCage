class_name DeathResolutionService
extends RefCounted

static func resolve(player: PlayerState, settlement: SettlementState, adventure: AdventureState, rules: DifficultyDefinition, death_position: Vector2, policy: RespawnPolicy, survival_config: SurvivalConfig, session_id: String, resolver: Callable, include_shared_adventure_loot: bool = true) -> RespawnResult:
	var result := RespawnResult.new()
	result.in_adventure = adventure.active_session != null
	if result.in_adventure:
		var carried := DeathLossPolicy.apply(player.inventory.stacks(), rules, resolver)
		var loot := DeathLossPolicy.apply(adventure.active_session.unsecured_loot.stacks(), rules, resolver) if include_shared_adventure_loot else DeathLossResult.new()
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
		if include_shared_adventure_loot:
			settlement.secure_loot(loot.kept)
		var dropped: Array[ItemStack] = carried.world_drops + loot.world_drops
		if rules.recovery_policy == DifficultyDefinition.RecoveryPolicy.DROP_AT_DEATH:
			dropped.append_array(gear.equipment_lost)
			if not dropped.is_empty():
				var record := DeathDropRecord.new()
				record.id = "%s-%s-%s" % [session_id, Time.get_ticks_usec(), randi()]
				record.session_id = session_id
				record.region_id = adventure.active_session.context.region_id
				record.position = death_position
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
