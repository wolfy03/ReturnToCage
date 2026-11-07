class_name InventoryWindow
extends ItemWindowFrame

signal item_hovered(view: ItemSlotView)
signal item_unhovered(view: ItemSlotView)
signal tab_changed
signal bag_changed
signal slot_command_requested(action: int, kind: int, from: int, to: int, amount: int, revision: int)

const Bag := PlayerItemCommandService.SlotInventory
const Action := PlayerItemCommandService.SlotAction

class SlotDrag extends RefCounted:
	var kind: int
	var index: int
	var category: int
	var view_epoch: int
	var split: bool

enum Tab { EQUIPMENT, CONSUMABLE, OTHER, QUEST }
const SLOT_SCENE := preload("res://ui/inventory/item_slot_view.tscn")
const PAGE_SIZE := 24
const TAB_NAMES := ["Equip", "Use", "Etc", "Quest"]
var slots: Array[ItemSlotView] = []
var tab_buttons: Array[Button] = []
var current_tab: Tab = Tab.CONSUMABLE
var inventory_kind: int = Bag.MAIN
var page := 0
var selected_slot := -1
var _items: Array[ItemStack] = []
var _filtered: Array[ItemStack] = []
var _fixed_slots := false
var _revision := -1
var _view_epoch := 0
var _pending := false
var _split_drag: SlotDrag
var _split_target := -1
@onready var _bag_picker: OptionButton = %BagPicker
@onready var _sort: Button = %Sort
@onready var _status: Label = %Status
@onready var _split_dialog: ConfirmationDialog = %SplitDialog
@onready var _split_amount: LineEdit = %SplitAmount

func _ready() -> void:
	super._ready()
	for index in TAB_NAMES.size():
		var button := Button.new()
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.pressed.connect(select_tab.bind(index))
		%Tabs.add_child(button)
		tab_buttons.append(button)
	for index in PAGE_SIZE:
		var slot := SLOT_SCENE.instantiate() as ItemSlotView
		%Grid.add_child(slot)
		slot.pressed.connect(_select_slot.bind(index))
		slot.set_drag_forwarding(_drag_data.bind(slot, index), _can_drop.bind(index), _drop.bind(index))
		slot.item_hovered.connect(item_hovered.emit)
		slot.item_unhovered.connect(item_unhovered.emit)
		slots.append(slot)
	%Previous.pressed.connect(_change_page.bind(-1))
	%Next.pressed.connect(_change_page.bind(1))
	_bag_picker.add_item("Main bag", Bag.MAIN)
	_bag_picker.add_item("Protected bag", Bag.PROTECTED)
	_bag_picker.item_selected.connect(_select_bag)
	_sort.pressed.connect(_request_sort)
	_split_dialog.confirmed.connect(_confirm_split)
	_split_dialog.canceled.connect(_clear_split)
	_split_dialog.register_text_enter(_split_amount)
	closed.connect(invalidate_gesture)
	display_items([], "")

static func tab_for(definition: ItemDefinition) -> Tab:
	if definition is EquipmentDefinition:
		return Tab.EQUIPMENT
	if definition != null:
		if definition.category == ItemDefinition.ItemCategory.QUEST:
			return Tab.QUEST
		if definition.category in [ItemDefinition.ItemCategory.FOOD, ItemDefinition.ItemCategory.DRINK, ItemDefinition.ItemCategory.RETURN_ITEM] or definition.is_consumable():
			return Tab.CONSUMABLE
	return Tab.OTHER

func display_items(items: Array[ItemStack], capacity_text: String) -> void:
	invalidate_gesture()
	_fixed_slots = false
	_revision = -1
	_items = items
	%Capacity.text = capacity_text
	_refresh()

## Category tabs hide other kinds in place; they never renumber model slots.
func display_slots(items: Array[ItemStack], capacity_text: String, revision: int = -1) -> void:
	if _revision != revision:
		invalidate_gesture()
	_revision = revision
	_fixed_slots = true
	_items = items
	%Capacity.text = capacity_text
	_refresh()

func select_tab(index: int) -> void:
	invalidate_gesture()
	current_tab = index as Tab
	page = 0
	selected_slot = -1
	_refresh()
	tab_changed.emit()

func _refresh() -> void:
	if not is_node_ready():
		return
	var counts := [0, 0, 0, 0]
	_filtered.clear()
	for stack in _items:
		if stack == null:
			if _fixed_slots:
				_filtered.append(null)
			continue
		var tab := tab_for(ContentRegistry.get_item(stack.item_id))
		counts[tab] += 1
		if tab == current_tab:
			_filtered.append(stack)
		elif _fixed_slots:
			_filtered.append(null)
	for index in tab_buttons.size():
		tab_buttons[index].text = "%s %d" % [TAB_NAMES[index], counts[index]]
		tab_buttons[index].set_pressed_no_signal(index == current_tab)
	var pages := maxi(1, ceili(float(_filtered.size()) / PAGE_SIZE))
	page = clampi(page, 0, pages - 1)
	%Page.text = "%d / %d" % [page + 1, pages]
	%Previous.disabled = page == 0
	%Next.disabled = page == pages - 1
	_sort.disabled = not _fixed_slots or _revision < 0 or _items.is_empty() or _pending
	if selected_slot >= 0 and _visible_stack(selected_slot) == null:
		selected_slot = -1
	for index in slots.size():
		var stack := _visible_stack(index)
		slots[index].display_item(stack, ContentRegistry.get_item(stack.item_id) if stack != null else null)
		slots[index].set_selected(index == selected_slot)

func _select_slot(index: int) -> void:
	selected_slot = index if _visible_stack(index) != null else -1
	for slot_index in slots.size():
		slots[slot_index].set_selected(slot_index == selected_slot)

func _change_page(direction: int) -> void:
	page += direction
	selected_slot = -1
	_refresh()
	tab_changed.emit()

func _slot_index(cell: int) -> int:
	return page * PAGE_SIZE + cell

func _visible_stack(cell: int) -> ItemStack:
	var index := _slot_index(cell)
	return _filtered[index] if index < _filtered.size() else null

func _select_bag(index: int) -> void:
	invalidate_gesture()
	inventory_kind = _bag_picker.get_item_id(index)
	page = 0
	selected_slot = -1
	bag_changed.emit()
	tab_changed.emit()

func reset_interaction() -> void:
	invalidate_gesture()
	inventory_kind = Bag.MAIN
	_bag_picker.select(0)
	page = 0
	selected_slot = -1
	set_pending(false)
	show_status("")

func invalidate_gesture() -> void:
	_view_epoch += 1
	_clear_split()

func set_pending(pending: bool) -> void:
	_pending = pending
	_sort.disabled = pending or not _fixed_slots or _revision < 0 or _items.is_empty()

func show_status(message: String) -> void:
	_status.text = message
	_status.tooltip_text = message

func _drag_data(_position: Vector2, view: ItemSlotView, cell: int) -> Variant:
	if _pending or _revision < 0 or not _fixed_slots or _visible_stack(cell) == null:
		return null
	var drag := SlotDrag.new()
	drag.kind = inventory_kind
	drag.index = _slot_index(cell)
	drag.category = current_tab
	drag.view_epoch = _view_epoch
	drag.split = view.shift_drag or Input.is_key_pressed(KEY_SHIFT)
	_select_slot(cell)
	show_status("")
	item_unhovered.emit(view)
	var preview := TextureRect.new()
	preview.texture = view.item_icon.texture
	preview.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.size = Vector2(40, 40)
	view.set_drag_preview(preview)
	return drag

func _can_drop(_position: Vector2, data: Variant, cell: int) -> bool:
	if not data is SlotDrag or data.index == _slot_index(cell) and data.kind == inventory_kind:
		return false
	var message := _drop_error(data, _slot_index(cell))
	if not message.is_empty() and not _pending:
		show_status(message)
	elif message.is_empty():
		show_status("")
	return message.is_empty()

func _drop(_position: Vector2, data: Variant, cell: int) -> void:
	if not _can_drop(_position, data, cell):
		return
	var drag := data as SlotDrag
	var target_index := _slot_index(cell)
	var source := _items[drag.index]
	var target := _items[target_index]
	if drag.split:
		_split_drag = drag
		_split_target = target_index
		%SplitRange.text = "Amount (1–%d)" % (source.quantity - 1)
		_split_amount.text = "1"
		_split_dialog.popup_centered(Vector2i(250, 110))
		_split_amount.grab_focus()
		_split_amount.select_all()
		return
	var action := Action.MOVE
	if target != null:
		action = Action.MERGE if _can_merge(source, target) else Action.SWAP
	slot_command_requested.emit(action, inventory_kind, drag.index, target_index, 0, _revision)

func _drop_error(drag: SlotDrag, to: int) -> String:
	if _pending:
		return "Waiting for the inventory update."
	if drag.kind != inventory_kind:
		return "Items can only move within the same bag."
	if drag.category != current_tab or drag.view_epoch != _view_epoch or _revision < 0:
		return "Inventory changed. Start the drag again."
	if to == drag.index:
		return "Choose another slot."
	if to < 0 or to >= _items.size() or drag.index < 0 or drag.index >= _items.size():
		return "This slot is outside the bag."
	var source := _items[drag.index]
	var target := _items[to]
	if target != null and tab_for(ContentRegistry.get_item(target.item_id)) != current_tab:
		return "That slot is occupied by an item in another tab."
	if source == null:
		return "Source slot is empty."
	var definition := ContentRegistry.get_item(source.item_id)
	if definition == null or tab_for(definition) != current_tab:
		return "The source item changed. Start the drag again."
	if drag.split:
		if source.quantity < 2 or not source.instance_id.is_empty() or definition is EquipmentDefinition:
			return "Only stacks of two or more ordinary items can split."
		if target != null:
			return "Choose an empty slot to split the stack."
	elif target != null and _can_merge(source, target) and target.quantity >= definition.max_stack:
		return "That stack is already full."
	return ""

static func _can_merge(source: ItemStack, target: ItemStack) -> bool:
	return InventoryModel.stacks_match_for_merge(source, target) and not ContentRegistry.get_item(source.item_id) is EquipmentDefinition

func _clear_split() -> void:
	_split_drag = null
	_split_target = -1
	_split_dialog.hide()

func _confirm_split() -> void:
	if _split_drag == null:
		return
	var drag := _split_drag
	var to := _split_target
	var text := _split_amount.text.strip_edges()
	var amount := text.to_int() if text.is_valid_int() else 0
	_clear_split()
	var message := _drop_error(drag, to)
	if not message.is_empty():
		show_status(message)
		return
	if amount < 1 or amount >= _items[drag.index].quantity:
		show_status("Choose an amount from 1 to %d." % (_items[drag.index].quantity - 1))
		return
	slot_command_requested.emit(Action.SPLIT, inventory_kind, drag.index, to, amount, _revision)

func _request_sort() -> void:
	if not _pending and _revision >= 0:
		slot_command_requested.emit(Action.SORT, inventory_kind, -1, -1, 0, _revision)
