class_name SettlementState
extends RefCounted

var storage: InventoryModel
var facility_levels: Dictionary[StringName, int] = {}
var resident_states: Dictionary[StringName, ResidentState] = {}

func _init(resolver: Callable) -> void:
	storage = InventoryModel.new(0, resolver)

func reset(start: GameStartDefinition, registry: Node) -> void:
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
	return {"settlement_storage": storage.to_array(), "facility_levels": facilities, "resident_states": residents}

func restore(data: Dictionary, start: GameStartDefinition, registry: Node) -> PackedStringArray:
	var errors := PackedStringArray()
	storage.capacity = start.storage_capacity
	errors.append_array(storage.restore(SaveData.array(data, "settlement_storage", errors)))
	facility_levels.clear()
	var facilities: Dictionary = SaveData.dictionary(data, "facility_levels", errors)
	for key in facilities:
		var definition := registry.get_definition(StringName(str(key))) as FacilityDefinition
		if not SaveData.is_text(key) or definition == null or not SaveData.is_number(facilities[key]):
			errors.append("unknown or invalid facility in save: %s" % key)
			continue
		facility_levels[StringName(key)] = clampi(int(facilities[key]), 0, definition.max_level)
	resident_states.clear()
	var residents: Dictionary = SaveData.dictionary(data, "resident_states", errors)
	for key in residents:
		if not SaveData.is_text(key) or String(key).is_empty() or not residents[key] is Dictionary:
			errors.append("invalid resident in save: %s" % key)
			continue
		var resident := ResidentState.new(StringName(key))
		errors.append_array(resident.restore(residents[key]))
		resident_states[resident.resident_id] = resident
	return errors
