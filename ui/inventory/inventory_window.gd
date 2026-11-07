class_name InventoryWindow
extends ItemWindowFrame

signal item_hovered(view: ItemSlotView)
signal item_unhovered(view: ItemSlotView)
signal tab_changed
enum Tab { EQUIPMENT, CONSUMABLE, OTHER, QUEST }
const SLOT_SCENE := preload("res://ui/inventory/item_slot_view.tscn")
const PAGE_SIZE := 24
const TAB_NAMES := ["Equip", "Use", "Etc", "Quest"]
var slots: Array[ItemSlotView] = []
var tab_buttons: Array[Button] = []
var current_tab: Tab = Tab.CONSUMABLE
var page := 0
var selected_slot := -1
var _items: Array[ItemStack] = []
var _filtered: Array[ItemStack] = []
var _fixed_slots := false

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
		slot.item_hovered.connect(item_hovered.emit)
		slot.item_unhovered.connect(item_unhovered.emit)
		slots.append(slot)
	%Previous.pressed.connect(_change_page.bind(-1))
	%Next.pressed.connect(_change_page.bind(1))
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
	_fixed_slots = false
	_items = items
	%Capacity.text = capacity_text
	_refresh()

## Category tabs hide other kinds in place; they never renumber model slots.
func display_slots(items: Array[ItemStack], capacity_text: String) -> void:
	_fixed_slots = true
	_items = items
	%Capacity.text = capacity_text
	_refresh()

func select_tab(index: int) -> void:
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
	for index in slots.size():
		var absolute := page * PAGE_SIZE + index
		var stack := _filtered[absolute] if absolute < _filtered.size() else null
		slots[index].display_item(stack, ContentRegistry.get_item(stack.item_id) if stack != null else null)
		slots[index].set_selected(index == selected_slot)

func _select_slot(index: int) -> void:
	selected_slot = index
	for slot_index in slots.size():
		slots[slot_index].set_selected(slot_index == index)

func _change_page(direction: int) -> void:
	page += direction
	selected_slot = -1
	_refresh()
	tab_changed.emit()
