class_name SettlementCommandService
extends RefCounted

var settlement: SettlementState
var progression: ProgressionState
var registry: Node
var quest_event_reporter: Callable

func _init(
	p_settlement: SettlementState,
	p_progression: ProgressionState,
	p_registry: Node,
	p_quest_event_reporter: Callable
) -> void:
	settlement = p_settlement
	progression = p_progression
	registry = p_registry
	quest_event_reporter = p_quest_event_reporter

func try_craft(recipe_id: StringName, actor_player_id: StringName) -> CommandResult:
	if actor_player_id.is_empty() or recipe_id.is_empty():
		return CommandResult.make(false, "Craft command requires a known player and recipe")
	var recipe := registry.get_definition(recipe_id) as RecipeDefinition
	if recipe == null:
		return CommandResult.make(false, "Unknown recipe")
	settlement.begin_update()
	var result := CraftingService.craft(recipe, settlement, progression)
	settlement.end_update()
	return result

func try_upgrade_facility(facility_id: StringName, actor_player_id: StringName) -> CommandResult:
	if actor_player_id.is_empty() or facility_id.is_empty():
		return CommandResult.make(false, "Facility command requires a known player and facility")
	var check := ProgressionService.facility_check(facility_id, settlement, progression, registry)
	if not check.success:
		return check
	var definition := registry.get_definition(facility_id) as FacilityDefinition
	var next_level: int = settlement.facility_levels.get(facility_id, 0) + 1
	var level := definition.get_level_data(next_level) if definition != null else null
	if definition == null or level == null:
		return CommandResult.make(false, "Missing facility level data")
	var costs := ProgressionService.item_amounts(level.cost_item_ids, level.cost_amounts)
	settlement.begin_update()
	var payment := settlement.storage.exchange(costs, [])
	if not payment.success:
		settlement.end_update()
		return payment
	# All failure-prone validation is complete before the deterministic commit.
	settlement.set_facility_level(facility_id, next_level)
	var unlock_changed := false
	for flag in level.unlock_flags:
		if not progression.unlocked_flags.has(flag):
			progression.unlocked_flags.append(flag)
			unlock_changed = true
	settlement.end_update()
	if unlock_changed:
		progression.mark_shared_changed()
	if quest_event_reporter.is_valid():
		quest_event_reporter.call(GameplayEvent.new(
			QuestObjectiveDefinition.ObjectiveType.UPGRADE_FACILITY,
			actor_player_id,
			facility_id,
			1
		))
	return CommandResult.make(true, "%s upgraded to level %d" % [definition.display_name, next_level])
