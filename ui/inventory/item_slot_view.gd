class_name ItemSlotView
extends Button
## A display snapshot only. Selection/hover never issues item commands.

signal item_hovered(view: ItemSlotView)
signal item_unhovered(view: ItemSlotView)

const PLACEHOLDER: Texture2D = preload("res://ui/inventory/item_placeholder.svg")
var stack: ItemStack
var definition: ItemDefinition
var selected := false
var show_quantity := true
@onready var item_icon: TextureRect = %Icon
@onready var quantity_label: Label = %Quantity
@onready var empty_mark: Label = %EmptyMark

func _ready() -> void:
	theme = ItemUIStyle.make_theme()
	mouse_entered.connect(func() -> void: item_hovered.emit(self))
	mouse_exited.connect(func() -> void: item_unhovered.emit(self))
	_refresh()

func display_item(value: ItemStack, item: ItemDefinition) -> void:
	stack = value.duplicate_stack() if value != null else null
	definition = item
	if is_node_ready():
		_refresh()

func set_selected(value: bool) -> void:
	selected = value
	if is_node_ready():
		_refresh()

func _refresh() -> void:
	var occupied := stack != null
	item_icon.texture = (definition.icon if definition != null and definition.icon != null else PLACEHOLDER) if occupied else null
	item_icon.visible = occupied
	empty_mark.visible = not occupied
	quantity_label.text = str(stack.quantity) if occupied and show_quantity else ""
	var edge := ItemUIStyle.ACCENT if selected else Color("58654c") if occupied else Color("3e4c3f")
	var fill := Color("354b37") if selected else Color("24382c") if occupied else Color("1b2a22")
	add_theme_stylebox_override("normal", ItemUIStyle.box(fill, edge, 2 if selected else 1))
	add_theme_stylebox_override("hover", ItemUIStyle.box(Color("3c503b"), ItemUIStyle.ACCENT, 2))
