class_name SettlementState
extends RefCounted

signal changed(revision: int)

var pending_loot: Array[ItemStack] = []
var _claim_in_progress: bool = false
var storage: InventoryModel
var _facility_levels: Dictionary[StringName, int] = {}
var facility_levels: Dictionary[StringName, int]:
	get:
		return _facility_levels if _can_mutate_domain() else _facility_levels.duplicate()
	set(value):
		if _can_mutate_domain():
			_facility_levels = value
var _resident_states: Dictionary[StringName, ResidentState] = {}
var resident_states: Dictionary[StringName, ResidentState]:
	get:
		if _can_mutate_domain():
			return _resident_states
		var mirror: Dictionary[StringName, ResidentState] = {}
		for resident_id in _resident_states:
			var source: ResidentState = _resident_states[resident_id]
			var copy := ResidentState.new(source.resident_id)
			copy.unlocked = source.unlocked
			copy.current_state = source.current_state
			mirror[resident_id] = copy
		return mirror
	set(value):
		if _can_mutate_domain():
			_resident_states = value
var revision: int = 0
var _update_depth: int = 0
var _change_pending: bool = false
var _applying_snapshot: bool = false
var _mutation_guard: Callable

func _init(resolver: Callable, mutation_guard: Callable = Callable()) -> void:
	_mutation_guard = mutation_guard
	storage = InventoryModel.new(0, resolver, Callable(self, "_can_mutate_storage"))
	storage.changed.connect(_on_storage_changed)

func set_mutation_guard(guard: Callable) -> void:
	_mutation_guard = guard

func reset(start: GameStartDefinition, registry: Node) -> void:
	_applying_snapshot = true
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
	revision = 0
	_update_depth = 0
	_change_pending = false
	_applying_snapshot = false

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
	_applying_snapshot = true
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
	revision = 0
	_update_depth = 0
	_change_pending = false
	_applying_snapshot = false
	return errors

func begin_update() -> void:
	_update_depth += 1
	storage.begin_update()

func end_update() -> void:
	if _update_depth <= 0:
		return
	storage.end_update()
	_update_depth -= 1
	if _update_depth == 0 and _change_pending:
		_change_pending = false
		_commit_change()

func set_facility_level(facility_id: StringName, level: int) -> bool:
	if not _can_mutate_domain() or facility_id.is_empty() or level < 0 or facility_levels.get(facility_id, -1) == level:
		return false
	facility_levels[facility_id] = level
	mark_changed()
	return true

func set_resident_state(resident_id: StringName, unlocked: bool, current_state: StringName) -> bool:
	if not _can_mutate_domain() or resident_id.is_empty() or current_state.is_empty():
		return false
	var resident: ResidentState = resident_states.get(resident_id)
	if resident == null:
		resident = ResidentState.new(resident_id)
		resident_states[resident_id] = resident
	if resident.unlocked == unlocked and resident.current_state == current_state:
		return false
	resident.unlocked = unlocked
	resident.current_state = current_state
	mark_changed()
	return true

func mark_changed() -> void:
	if _applying_snapshot or not _can_mutate_domain():
		return
	if _update_depth > 0:
		_change_pending = true
	else:
		_commit_change()

func apply_network_mirror(snapshot: SettlementStateSnapshot) -> bool:
	if snapshot == null or not snapshot.error_message.is_empty() or snapshot.revision <= revision:
		return false
	_applying_snapshot = true
	storage.begin_update()
	storage.capacity = snapshot.storage_capacity
	var initialized := storage.initialize(snapshot.storage)
	if not initialized.success:
		storage.end_update()
		_applying_snapshot = false
		return false
	facility_levels = snapshot.facility_levels.duplicate()
	resident_states.clear()
	for resident_id in snapshot.resident_states:
		var source: ResidentState = snapshot.resident_states[resident_id]
		var resident := ResidentState.new(source.resident_id)
		resident.unlocked = source.unlocked
		resident.current_state = source.current_state
		resident_states[resident_id] = resident
	revision = snapshot.revision
	storage.end_update()
	_applying_snapshot = false
	changed.emit(revision)
	return true

func _on_storage_changed() -> void:
	mark_changed()

func _commit_change() -> void:
	revision += 1
	changed.emit(revision)

func _can_mutate_storage() -> bool:
	return _can_mutate_domain()

func _can_mutate_domain() -> bool:
	return _applying_snapshot or not _mutation_guard.is_valid() or bool(_mutation_guard.call())

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
	storage.begin_update()
	var result: CommandResult = storage.exchange([], pending_loot)
	if result.success:
		pending_loot.clear()
	storage.end_update()
	_claim_in_progress = false
	return result
