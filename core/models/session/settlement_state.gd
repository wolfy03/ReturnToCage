class_name SettlementState
extends RefCounted

var pending_loot: Array[ItemStack] = []
var _claim_in_progress: bool = false
var storage: InventoryModel
var facility_levels: Dictionary[StringName, int] = {}
var resident_states: Dictionary[StringName, ResidentState] = {}

func _init(resolver: Callable) -> void:
	storage = InventoryModel.new(0, resolver)

func reset(start: GameStartDefinition, registry: Node) -> void:
	pending_loot.clear()
	storage.capacity = start.storage_capacity
	storage.initialize(start.create_stacks(start.storage_items, registry))
	facility_levels = start.facility_levels.duplicate()
	resident_states.clear()
	for entry in start.residents:
		var resident := ResidentState.new(entry.resident_id)
		resident.unlocked = entry.unlocked
		resident.current_state = entry.current_state
		resident_states[resident.resident_id] = resident

func to_save_dict() -> Dictionary:
	var facilities: Dictionary = {}
	for key in facility_levels:
		facilities[String(key)] = facility_levels[key]
	var residents: Dictionary = {}
	for key in resident_states:
		residents[String(key)] = resident_states[key].to_dict()
	var pending: Array[Dictionary] = []
	for stack in pending_loot:
		pending.append(stack.to_dict())
	return {"pending_loot": pending, "settlement_storage": storage.to_array(), "facility_levels": facilities, "resident_states": residents}

func restore(data: Dictionary, start: GameStartDefinition, registry: Node, instances: Dictionary[String, String] = {}) -> PackedStringArray:
	var errors := PackedStringArray()
	storage.capacity = start.storage_capacity
	errors.append_array(storage.restore(SaveData.array(data, "settlement_storage", errors), instances, "settlement_storage"))
	facility_levels.clear()
	var facilities: Dictionary = SaveData.dictionary(data, "facility_levels", errors)
	for key in facilities:
		var definition := registry.get_definition(StringName(str(key))) as FacilityDefinition
		if not SaveData.is_text(key) or definition == null or not SaveData.is_integer(facilities[key]):
			errors.append("unknown or invalid facility in save: %s" % key)
			continue
		facility_levels[StringName(key)] = clampi(int(facilities[key]), 0, definition.max_level)
		if facility_levels[StringName(key)] != int(facilities[key]):
			errors.append("facility level clamped: %s" % key)
	resident_states.clear()
	var residents: Dictionary = SaveData.dictionary(data, "resident_states", errors)
	for key in residents:
		if not SaveData.is_text(key) or String(key).is_empty() or not residents[key] is Dictionary:
			errors.append("invalid resident in save: %s" % key)
			continue
		var resident := ResidentState.new(StringName(key))
		errors.append_array(resident.restore(residents[key]))
		resident_states[resident.resident_id] = resident
	pending_loot.clear()
	var pending: Array = SaveData.array(data, "pending_loot", errors)
	for index in pending.size():
		var context: String = "pending_loot[%d]" % index
		var stack: ItemStack = StackValidation.from_record(pending[index], storage.definition_resolver, errors, context)
		if stack != null and StackValidation.accept_instance(stack, instances, errors, context):
			pending_loot.append(stack)
	# Overflow is already validated and reserved in instances; transfer it once.
	pending_loot.append_array(storage.take_restore_overflow())
	return errors

func secure_loot(items: Array[ItemStack]) -> CommandResult:
	var result: CommandResult = storage.exchange([], items)
	if not result.success:
		for stack in items:
			pending_loot.append(stack.duplicate_stack())
	return result

func claim_pending_loot() -> CommandResult:
	if _claim_in_progress:
		return CommandResult.make(false, "Pending loot claim already in progress")
	_claim_in_progress = true
	var result: CommandResult = storage.exchange([], pending_loot)
	if result.success:
		pending_loot.clear()
	_claim_in_progress = false
	return result
