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
	var instances: Dictionary[String, String] = {}
	var resolver := Callable(registry, "get_item")
	snapshot.player = PlayerState.new(resolver)
	snapshot.settlement = SettlementState.new(resolver)
	snapshot.progression = ProgressionState.new()
	snapshot.difficulty = DifficultyState.new()
	snapshot.adventure = AdventureState.new()
	snapshot.session_id = SaveData.text_value(data, "session_id", "restored", snapshot.warnings)
	snapshot.play_time_seconds = maxf(0.0, SaveData.number(data, "play_time_seconds", 0.0, snapshot.warnings))
	snapshot.warnings.append_array(snapshot.player.restore(data, start, instances))
	snapshot.warnings.append_array(snapshot.settlement.restore(data, start, registry, instances))
	snapshot.warnings.append_array(snapshot.progression.restore(data, registry))
	snapshot.warnings.append_array(snapshot.difficulty.restore(data, start, registry))
	snapshot.warnings.append_array(snapshot.adventure.restore(data, instances))
	snapshot.settlement.append_restore_overflow(snapshot.player.inventory.take_restore_overflow())
	snapshot.settlement.append_restore_overflow(snapshot.player.protected_inventory.take_restore_overflow())
	var p: PlayerState = snapshot.player
	# SaveManager resumes a settlement, which must spawn a living actor. Direct
	# PlayerState.restore still preserves the domain's valid zero-health state.
	if p.health <= 0.0:
		p.set_health(1.0)
		snapshot.warnings.append("settlement resume health recovered from 0 to 1")
	return snapshot
