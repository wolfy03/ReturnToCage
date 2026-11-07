class_name InventoryPresenter
extends CanvasLayer
## Only reads the local owner's models. No command or mutation API belongs here.

const INVENTORY_SCENE := preload("res://ui/inventory/inventory_window.tscn")
const EQUIPMENT_SCENE := preload("res://ui/inventory/equipment_window.tscn")
const TOOLTIP_SCENE := preload("res://ui/inventory/item_tooltip.tscn")
var inventory_window: InventoryWindow
var equipment_window: EquipmentWindow
var tooltip: ItemTooltip
var _state: PlayerState
var _hovered: ItemSlotView
var _refresh_queued := false

func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	inventory_window = INVENTORY_SCENE.instantiate() as InventoryWindow
	equipment_window = EQUIPMENT_SCENE.instantiate() as EquipmentWindow
	tooltip = TOOLTIP_SCENE.instantiate() as ItemTooltip
	root.add_child(inventory_window)
	root.add_child(equipment_window)
	root.add_child(tooltip)
	for window in [inventory_window, equipment_window]:
		window.item_hovered.connect(_show_tooltip)
		window.item_unhovered.connect(_hide_tooltip_for)
		window.closed.connect(_hide_tooltip)
	inventory_window.tab_changed.connect(_hide_tooltip)
	GameSession.phase_changed.connect(_on_phase_changed)
	GameSession.session_reset.connect(_on_session_reset)
	ContentRegistry.registry_reloaded.connect(_on_registry_reloaded)
	_on_phase_changed()

func _exit_tree() -> void:
	_bind_state(null)
	if GameSession.phase_changed.is_connected(_on_phase_changed):
		GameSession.phase_changed.disconnect(_on_phase_changed)
	if GameSession.session_reset.is_connected(_on_session_reset):
		GameSession.session_reset.disconnect(_on_session_reset)
	if ContentRegistry.registry_reloaded.is_connected(_on_registry_reloaded):
		ContentRegistry.registry_reloaded.disconnect(_on_registry_reloaded)

func _active() -> bool:
	return GameSession.phase != GameSession.Phase.MENU and not GameSession.session_id.is_empty() \
		and GameSession.get_local_player() != null

func _bind_state(value: PlayerState) -> void:
	if _state == value:
		return
	if _state != null:
		for model in [_state.inventory, _state.protected_inventory, _state.equipment]:
			if model.changed.is_connected(queue_refresh):
				model.changed.disconnect(queue_refresh)
	_state = value
	if _state != null:
		for model in [_state.inventory, _state.protected_inventory, _state.equipment]:
			model.changed.connect(queue_refresh)

func _on_phase_changed() -> void:
	if not _active():
		close_all()
		_bind_state(null)
	else:
		_bind_state(GameSession.get_local_player())
	refresh()

func _on_session_reset() -> void:
	close_all()
	_on_phase_changed()

func _on_registry_reloaded(_errors: PackedStringArray) -> void:
	queue_refresh()

func queue_refresh() -> void:
	if not _refresh_queued:
		_refresh_queued = true
		call_deferred("refresh")

func refresh() -> void:
	_refresh_queued = false
	var items: Array[ItemStack] = []
	var equipped: Dictionary[int, ItemStack] = {}
	var capacity_text := ""
	if _state != null and _active():
		items = _state.inventory.slots()
		items.append_array(_state.protected_inventory.slots())
		capacity_text = "Bag %d/%d · Protected %d/%d" % [_state.inventory.stacks().size(), _state.inventory.capacity,
			_state.protected_inventory.stacks().size(), _state.protected_inventory.capacity]
		for entry in equipment_window.slot_layout:
			if entry != null:
				equipped[entry.slot] = _state.equipment.equipped(entry.slot)
	inventory_window.display_slots(items, capacity_text)
	equipment_window.display_equipment(equipped)
	if is_instance_valid(_hovered) and _hovered.is_visible_in_tree():
		tooltip.show_item(_hovered.stack, _hovered.definition)

func close_all() -> void:
	if inventory_window != null:
		inventory_window.hide_window()
		equipment_window.hide_window()
		inventory_window.selected_slot = -1
		_hide_tooltip()

func _unhandled_key_input(event: InputEvent) -> void:
	if not _active() or event.is_echo():
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	if event.is_action_pressed(&"open_inventory"):
		_toggle(inventory_window)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"open_equipment"):
		_toggle(equipment_window)
		get_viewport().set_input_as_handled()

func _toggle(window: ItemWindowFrame) -> void:
	if window.visible:
		window.hide_window()
	else:
		refresh()
		window.show_window()

func _show_tooltip(view: ItemSlotView) -> void:
	_hovered = view
	tooltip.show_item(view.stack, view.definition)

func _hide_tooltip_for(view: ItemSlotView) -> void:
	if _hovered == view:
		_hide_tooltip()

func _hide_tooltip() -> void:
	_hovered = null
	tooltip.clear()
