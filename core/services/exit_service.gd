class_name ExitService
extends RefCounted

static func check(exit_id: StringName, region_id: StringName, progression: ProgressionState, settlement: SettlementState, adventure: AdventureState, registry: Node) -> CommandResult:
	if adventure.active_session != null:
		return CommandResult.make(false, "An expedition is already active")
	var exit := registry.get_definition(exit_id) as SettlementExitDefinition
	var region := registry.get_definition(region_id) as RegionDefinition
	if exit == null or region == null:
		return CommandResult.make(false, "Unknown exit or region")
	if exit.development_locked:
		return CommandResult.make(false, "Route under development")
	if not progression.unlocked_exits.has(exit_id) or not progression.unlocked_regions.has(region_id):
		return CommandResult.make(false, "Route is locked")
	if not exit.connected_region_ids.has(region_id):
		return CommandResult.make(false, "Exit is not connected to this region")
	for flag in exit.required_flags + region.unlock_flags:
		if not progression.unlocked_flags.has(flag):
			return CommandResult.make(false, "Missing route unlock: %s" % flag)
	for facility_id in exit.required_facility_levels:
		if settlement.facility_levels.get(facility_id, 0) < exit.required_facility_levels[facility_id]:
			return CommandResult.make(false, "Required facility level: %s" % facility_id)
	if not region.entry_point_ids.has(exit.entry_point_id):
		return CommandResult.make(false, "Invalid entry point")
	return CommandResult.make(true)
