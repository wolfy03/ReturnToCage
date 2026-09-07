class_name SessionSnapshot
extends RefCounted
## Detached staging area; no live signals or models are changed during validation.
var player: PlayerState
var settlement: SettlementState
var progression: ProgressionState
var difficulty: DifficultyState
var adventure: AdventureState
var session_id: String
var play_time_seconds: float
var warnings: PackedStringArray = PackedStringArray()
var fatal_error: String = ""

static func build(data: Dictionary, start: GameStartDefinition, registry: Node) -> SessionSnapshot:
	var snapshot := SessionSnapshot.new()
	for key in ["player_stats", "equipment"]:
		if data.has(key) and not data[key] is Dictionary:
			snapshot.fatal_error = "Invalid core save object: %s" % key
			return snapshot
	for key in ["player_inventory", "settlement_storage", "protected_inventory"]:
		if data.has(key) and not data[key] is Array:
			snapshot.fatal_error = "Invalid core save array: %s" % key
			return snapshot
	var resolver := Callable(registry, "get_item")
	snapshot.player = PlayerState.new(resolver)
	snapshot.settlement = SettlementState.new(resolver)
	snapshot.progression = ProgressionState.new()
	snapshot.difficulty = DifficultyState.new()
	snapshot.adventure = AdventureState.new()
	snapshot.session_id = SaveData.text_value(data, "session_id", "restored", snapshot.warnings)
	snapshot.play_time_seconds = maxf(0.0, SaveData.number(data, "play_time_seconds", 0.0, snapshot.warnings))
	snapshot.warnings.append_array(snapshot.player.restore(data, start))
	snapshot.warnings.append_array(snapshot.settlement.restore(data, start, registry))
	snapshot.warnings.append_array(snapshot.progression.restore(data, registry))
	snapshot.warnings.append_array(snapshot.difficulty.restore(data, start, registry))
	snapshot.warnings.append_array(snapshot.adventure.restore(data))
	snapshot.settlement.pending_loot.append_array(snapshot.player.inventory.restore_overflow)
	snapshot.settlement.pending_loot.append_array(snapshot.player.protected_inventory.restore_overflow)
	var p: PlayerState = snapshot.player
	var max_health: float = maxf(1.0, p.stats.value(&"max_health"))
	var health: float = clampf(p.health, 1.0, max_health)
	var hunger: float = clampf(p.survival.hunger, 0.0, start.survival_config.max_hunger)
	var thirst: float = clampf(p.survival.thirst, 0.0, start.survival_config.max_thirst)
	if health != p.health or hunger != p.survival.hunger or thirst != p.survival.thirst or p.survival.progression_reduction < 0.0 or p.survival.progression_reduction > 0.9:
		snapshot.warnings.append("player vitals clamped to safe ranges")
	p.health = health
	p.survival.hunger = hunger
	p.survival.thirst = thirst
	p.survival.progression_reduction = clampf(p.survival.progression_reduction, 0.0, 0.9)
	return snapshot
