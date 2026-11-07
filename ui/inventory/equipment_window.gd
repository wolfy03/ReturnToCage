class_name EquipmentWindow
extends ItemWindowFrame

signal item_hovered(view: ItemSlotView)
signal item_unhovered(view: ItemSlotView)
signal unequip_requested(slot: int)
@export var slot_layout: Array[EquipmentSlotViewDefinition] = []
class EquippedDrag extends RefCounted:
	var slot: int
	var view_epoch: int

const SLOT_SCENE := preload("res://ui/inventory/item_slot_view.tscn")
var slot_views: Dictionary[int, ItemSlotView] = {}
var _names: Dictionary[int, Label] = {}
var _durability: Dictionary[int, Label] = {}

func _ready() -> void:
	super._ready()
	for entry in slot_layout:
		if entry == null or slot_views.has(entry.slot):
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		%Slots.add_child(row)
		var slot := SLOT_SCENE.instantiate() as ItemSlotView
		slot.show_quantity = false
		row.add_child(slot)
		slot_views[entry.slot] = slot
		slot.item_hovered.connect(item_hovered.emit)
		slot.item_unhovered.connect(item_unhovered.emit)
		slot.item_activated.connect(_on_item_activated.bind(entry.slot))
		var text := VBoxContainer.new()
		text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(text)
		var title := Label.new()
		title.text = entry.label.to_upper()
		title.add_theme_font_size_override("font_size", 11)
		title.add_theme_color_override("font_color", ItemUIStyle.MUTED)
		text.add_child(title)
		var name_label := Label.new()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		name_label.text = "Empty slot"
		text.add_child(name_label)
		_names[entry.slot] = name_label
		var durability := Label.new()
		durability.add_theme_font_size_override("font_size", 12)
		durability.add_theme_color_override("font_color", ItemUIStyle.MUTED)
		text.add_child(durability)
		_durability[entry.slot] = durability
	display_equipment({})

func _on_item_activated(_view: ItemSlotView, slot: int) -> void:
	unequip_requested.emit(slot)

func show_status(message: String) -> void:
	%Status.text = message
	%Status.tooltip_text = message

func display_equipment(items: Dictionary[int, ItemStack]) -> void:
	for id in slot_views:
		var stack: ItemStack = items.get(id)
		var definition := ContentRegistry.get_item(stack.item_id) as EquipmentDefinition if stack != null else null
		slot_views[id].display_item(stack, definition)
		_names[id].text = definition.display_name if definition != null else "Empty slot"
		_durability[id].text = "Durability %d / %d" % [stack.durability, definition.max_durability] \
			if stack != null and definition != null and definition.max_durability > 0 else "—"
