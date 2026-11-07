class_name InventoryPresenter
extends CanvasLayer
## Displays the local owner mirror and forwards inventory intents to the item service.

const INVENTORY_SCENE := preload("res://ui/inventory/inventory_window.tscn")
const EQUIPMENT_SCENE := preload("res://ui/inventory/equipment_window.tscn")
const Command := PlayerItemReplicationService.CommandType
const TOOLTIP_SCENE := preload("res://ui/inventory/item_tooltip.tscn")
var inventory_window: InventoryWindow
var equipment_window: EquipmentWindow
var tooltip: ItemTooltip
var _state: PlayerState
var _stats: StatBlock
var _hovered: ItemSlotView
var _refresh_queued := false
var _service: PlayerItemReplicationService
var _pending_sequence := -1
var _pending_item_type := -1
var _pending_item_revision := -1
var _accepted_item_result: CommandResult
var _displayed_revision := -1

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
	inventory_window.selection_changed.connect(_refresh_tooltip)
	inventory_window.bag_changed.connect(refresh)
	inventory_window.slot_command_requested.connect(_request_slot_command)
	inventory_window.item_activated.connect(_on_inventory_activation)
	equipment_window.unequip_requested.connect(_request_unequip)
	equipment_window.closed.connect(inventory_window.invalidate_gesture)
	inventory_window.unequip_dropped.connect(_request_unequip)
	for slot in equipment_window.slot_views:
		equipment_window.slot_views[slot].set_drag_forwarding(
			_equipment_drag_data.bind(equipment_window.slot_views[slot], slot),
			_can_equip_drop.bind(slot), _equip_drop.bind(slot)
		)
	_service = get_tree().get_first_node_in_group(&"player_item_replication_service") as PlayerItemReplicationService
	# Offline and Host emit the result inside request_slot_command().
	if _service != null:
		_service.slot_result.connect(_on_slot_result, CONNECT_DEFERRED)
		_service.equip_result.connect(_on_item_result.bind(Command.EQUIP))
		_service.unequip_result.connect(_on_item_result.bind(Command.UNEQUIP))
		_service.use_item_result.connect(_on_item_result.bind(Command.USE_ITEM))
	GameSession.player_world_changed.connect(_on_local_world_changed)
	GameSession.player_life_changed.connect(_on_player_life_changed)
	GameSession.phase_changed.connect(_on_phase_changed)
	GameSession.session_reset.connect(_on_session_reset)
	ContentRegistry.registry_reloaded.connect(_on_registry_reloaded)
	_on_phase_changed()

func _exit_tree() -> void:
	_bind_state(null)
	if is_instance_valid(_service) and _service.slot_result.is_connected(_on_slot_result):
		_service.slot_result.disconnect(_on_slot_result)
		_service.equip_result.disconnect(_on_item_result.bind(Command.EQUIP))
		_service.unequip_result.disconnect(_on_item_result.bind(Command.UNEQUIP))
		_service.use_item_result.disconnect(_on_item_result.bind(Command.USE_ITEM))
	if GameSession.player_world_changed.is_connected(_on_local_world_changed):
		GameSession.player_world_changed.disconnect(_on_local_world_changed)
	if GameSession.player_life_changed.is_connected(_on_player_life_changed):
		GameSession.player_life_changed.disconnect(_on_player_life_changed)
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
	_bind_stats(null)
	if _state != null:
		_state.private_state_changed.disconnect(queue_refresh)
		_state.item_state_changed.disconnect(_on_item_state_changed)
		for model in [_state.inventory, _state.protected_inventory, _state.equipment]:
			if model.changed.is_connected(queue_refresh):
				model.changed.disconnect(queue_refresh)
	_reset_item_interaction()
	_state = value
	if _state != null:
		_state.private_state_changed.connect(queue_refresh)
		_state.item_state_changed.connect(_on_item_state_changed)
		for model in [_state.inventory, _state.protected_inventory, _state.equipment]:
			model.changed.connect(queue_refresh)

func _bind_stats(value: StatBlock) -> void:
	if _stats == value:
		return
	if _stats != null:
		_stats.stat_changed.disconnect(_on_stat_changed)
	_stats = value
	if _stats != null:
		_stats.stat_changed.connect(_on_stat_changed)

func _on_item_state_changed(_revision: int) -> void:
	queue_refresh()

func _on_stat_changed(_stat_id: StringName, _value: float) -> void:
	queue_refresh()

func _on_phase_changed() -> void:
	if not _active():
		close_all()
		_bind_state(null)
	else:
		_bind_state(GameSession.get_local_player())
	refresh()

func _on_session_reset() -> void:
	close_all()
	_reset_item_interaction()
	_on_phase_changed()

func _reset_item_interaction() -> void:
	_pending_sequence = -1
	_clear_pending_item()
	inventory_window.reset_interaction()
	equipment_window.show_status("")

func _on_registry_reloaded(_errors: PackedStringArray) -> void:
	inventory_window.invalidate_gesture()
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
	var revision := -1
	if _state != null and _active():
		var model := PlayerItemCommandService.slot_inventory(_state, inventory_window.inventory_kind)
		items = model.slots()
		var occupied := 0
		for stack in items:
			if stack != null:
				occupied += 1
		capacity_text = "%d / %d slots" % [occupied, model.capacity]
		revision = _state.item_state_revision
		for entry in equipment_window.slot_layout:
			if entry != null:
				equipped[entry.slot] = _state.equipment.equipped(entry.slot)
	_bind_stats(_state.stats if _state != null and _active() else null)
	_displayed_revision = revision
	inventory_window.display_slots(items, capacity_text, revision)
	equipment_window.display_equipment(equipped)
	equipment_window.display_stats(_stats)
	_refresh_tooltip()
	if _accepted_item_result != null and revision > _pending_item_revision:
		var message := _accepted_item_result.message
		_clear_pending_item()
		_show_item_status(message)

func close_all() -> void:
	if inventory_window != null:
		inventory_window.hide_window()
		equipment_window.hide_window()
		inventory_window.selected_slot = -1
		_hide_tooltip()

func _unhandled_key_input(event: InputEvent) -> void:
	if not _active() or event.is_echo():
		return
	if event.is_action_pressed(&"pause") and _close_front_item_window():
		get_viewport().set_input_as_handled()
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var hovered := get_viewport().gui_get_hovered_control()
	if event is InputEventKey and event.is_action_pressed(&"dodge") \
			and (event.keycode == KEY_SHIFT or event.physical_keycode == KEY_SHIFT) \
			and inventory_window.is_visible_in_tree() \
			and (hovered != null and inventory_window.is_ancestor_of(hovered) \
				or get_viewport().gui_get_drag_data() is InventoryWindow.SlotDrag):
		# Shift is the split modifier when the pointer is in the inventory.
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"open_inventory"):
		_toggle(inventory_window)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"open_equipment"):
		_toggle(equipment_window)
		get_viewport().set_input_as_handled()

func _close_front_item_window() -> bool:
	var front: ItemWindowFrame
	for window in [inventory_window, equipment_window]:
		if window.is_visible_in_tree() and (front == null or window.get_index() > front.get_index()):
			front = window
	if front == null:
		return false
	front.hide_window()
	return true

func _toggle(window: ItemWindowFrame) -> void:
	if window.visible:
		window.hide_window()
	else:
		refresh()
		window.show_window()

func _show_tooltip(view: ItemSlotView) -> void:
	_hovered = view
	_refresh_tooltip()

func _hide_tooltip_for(view: ItemSlotView) -> void:
	if _hovered == view:
		_hovered = null
		_refresh_tooltip()

func _refresh_tooltip() -> void:
	var view := _hovered if is_instance_valid(_hovered) and _hovered.is_visible_in_tree() else null
	var anchor: Control
	if view == null and inventory_window.is_visible_in_tree() and inventory_window.selected_slot >= 0:
		var selected := inventory_window.slots[inventory_window.selected_slot]
		if selected.definition is EquipmentDefinition:
			view = selected
			anchor = selected
	if view == null or view.stack == null:
		tooltip.clear()
		return
	var owner := _state if inventory_window.is_ancestor_of(view) and view.definition is EquipmentDefinition else null
	tooltip.show_item(view.stack, view.definition, owner, anchor)
	tooltip.get_parent().move_child(tooltip, -1)

func _hide_tooltip() -> void:
	_hovered = null
	tooltip.clear()

func _on_local_world_changed(player_id: StringName, _world: PlayerWorldState) -> void:
	if player_id == GameSession.get_local_player_id():
		inventory_window.invalidate_gesture()
		_hide_tooltip()

func _on_player_life_changed(peer_id: int, _life_id: int, _life_phase: int) -> void:
	if peer_id == NetworkManager.local_peer_id():
		inventory_window.invalidate_gesture()

func _request_slot_command(action: int, kind: int, from: int, to: int, amount: int, revision: int) -> void:
	if _pending_sequence >= 0 or _pending_item_type >= 0 or not inventory_window.is_visible_in_tree():
		return
	if not _active() or _state != GameSession.get_local_player() or not is_instance_valid(_service):
		inventory_window.show_status("Inventory actions are unavailable right now.")
		return
	if kind != inventory_window.inventory_kind or revision != _state.item_state_revision:
		refresh()
		inventory_window.show_status("Inventory changed. Try again.")
		return
	_pending_sequence = _service.request_slot_command(action, kind, from, to, amount)
	inventory_window.set_pending(_pending_sequence >= 0)
	inventory_window.show_status("Waiting for the inventory update…" if _pending_sequence >= 0 else "Cannot send the inventory action. Try again.")

func _on_slot_result(sequence: int, success: bool, message: String) -> void:
	if sequence != _pending_sequence or _pending_sequence < 0:
		return
	_pending_sequence = -1
	inventory_window.set_pending(false)
	refresh()
	if success:
		inventory_window.show_status("")
	elif message.begins_with("Stale") or message.contains("contents changed"):
		inventory_window.show_status("Inventory or world changed. Try again.")
	elif message.contains("pending transition") or message.contains("world is not ready"):
		inventory_window.show_status("Wait for the world to finish loading, then try again.")
	elif message == "Player is busy":
		inventory_window.show_status("Wait until your character finishes the current action.")
	else:
		inventory_window.show_status(message if not message.is_empty() else "That inventory action was rejected.")

func _on_inventory_activation(view: ItemSlotView) -> void:
	if view.definition == null or not inventory_window.is_visible_in_tree():
		return
	if inventory_window.inventory_kind != InventoryWindow.Bag.MAIN:
		_show_item_status("Equip or use items from the main bag.")
	elif view.definition is EquipmentDefinition:
		_request_item(Command.EQUIP, view.stack)
	elif view.definition.category == ItemDefinition.ItemCategory.RETURN_ITEM:
		_show_item_status("Use the return shortcut [Q] in an Adventure.")
	elif view.definition.is_consumable():
		_request_item(Command.USE_ITEM, view.stack)

func _can_equip_drop(_position: Vector2, data: Variant, slot: int) -> bool:
	if not equipment_window.is_visible_in_tree() or _pending_sequence >= 0 or _pending_item_type >= 0:
		return false
	var stack := inventory_window.dragged_equipment(data)
	if stack == null:
		return false
	var definition := ContentRegistry.get_item(stack.item_id) as EquipmentDefinition
	if definition.equipment_slot != slot:
		_show_item_status("This item belongs in a different equipment slot.")
		return false
	return not stack.instance_id.is_empty()

func _equip_drop(position: Vector2, data: Variant, slot: int) -> void:
	if _can_equip_drop(position, data, slot):
		_request_item(Command.EQUIP, inventory_window.dragged_equipment(data))

func _equipment_drag_data(_position: Vector2, view: ItemSlotView, slot: int) -> Variant:
	if _pending_sequence >= 0 or _pending_item_type >= 0 or view.stack == null:
		return null
	if not inventory_window.is_visible_in_tree():
		equipment_window.show_status("Open the inventory [I] to drag gear out.")
		return null
	var drag := EquipmentWindow.EquippedDrag.new()
	drag.slot = slot
	drag.view_epoch = inventory_window._view_epoch
	_hide_tooltip()
	view.preview_item_drag()
	return drag

func _request_unequip(slot: int) -> void:
	if equipment_window.is_visible_in_tree():
		_request_item(Command.UNEQUIP, equipment_window.slot_views[slot].stack, slot)

func _request_item(command: int, stack: ItemStack, slot: int = -1) -> void:
	if _pending_sequence >= 0 or _pending_item_type >= 0 or stack == null:
		return
	if not _active() or _state != GameSession.get_local_player() or not is_instance_valid(_service):
		_show_item_status("Inventory actions are unavailable right now.")
		return
	if _displayed_revision < 0 or _displayed_revision != _state.item_state_revision:
		refresh()
		_show_item_status("Inventory changed. Try again.")
		return
	if command == Command.EQUIP and stack.instance_id.is_empty():
		_show_item_status("This equipment has no item identity.")
		return
	if command == Command.USE_ITEM and not stack.instance_id.is_empty():
		_show_item_status("Items with individual identities cannot be used by item type.")
		return
	_pending_item_type = command
	_pending_item_revision = _displayed_revision
	inventory_window.set_pending(true)
	_show_item_status("Waiting for the inventory update…")
	var sent := false
	match command:
		Command.EQUIP: sent = _service.request_equip(stack.instance_id)
		Command.UNEQUIP: sent = _service.request_unequip(slot)
		Command.USE_ITEM: sent = _service.request_use_item(stack.item_id)
	if not sent:
		_on_item_result(false, "Item action unavailable or already in progress. Try again.", command)

func _on_item_result(success: bool, message: String, command: int) -> void:
	if command != _pending_item_type or _accepted_item_result != null:
		return
	if success:
		# Keep the old layout locked until the authoritative item change is visible.
		if command == Command.UNEQUIP:
			message = "Equipment moved to the first free slot in the main bag."
		_accepted_item_result = CommandResult.make(true, message)
		refresh()
		return
	_clear_pending_item()
	refresh()
	if message.contains("pending transition") or message.contains("world is not ready"):
		message = "Wait for the world to finish loading, then try again."
	elif message.contains("inventory full") or message.contains("Inventory is full"):
		message = "The main bag is full."
	_show_item_status(message)

func _clear_pending_item() -> void:
	_pending_item_type = -1
	_pending_item_revision = -1
	_accepted_item_result = null
	inventory_window.set_pending(false)

func _show_item_status(message: String) -> void:
	inventory_window.show_status(message)
	equipment_window.show_status(message)
