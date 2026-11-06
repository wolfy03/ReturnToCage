class_name ItemTooltip
extends PanelContainer

@onready var title_label: Label = %Title
@onready var body_label: Label = %Body

func _ready() -> void:
	theme = ItemUIStyle.make_theme()
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	get_viewport().size_changed.connect(_place)

func _exit_tree() -> void:
	if get_viewport().size_changed.is_connected(_place):
		get_viewport().size_changed.disconnect(_place)

static func category_name(definition: ItemDefinition) -> String:
	if definition == null:
		return "Unknown item"
	return ["Resource", "Food", "Drink", "Return item", "Weapon", "Armor", "Quest item"][definition.category]

func show_item(stack: ItemStack, definition: ItemDefinition) -> void:
	if stack == null:
		clear()
		return
	title_label.text = definition.display_name if definition != null else String(stack.item_id)
	var lines: Array[String] = [category_name(definition)]
	lines.append(definition.description if definition != null and not definition.description.is_empty() else "No description available.")
	lines.append("Quantity  %d" % stack.quantity)
	if definition != null:
		lines.append("Weight  %.2f each  /  %.2f total" % [definition.weight, definition.weight * stack.quantity])
		lines.append("Base value  %d" % definition.base_value)
	if definition is EquipmentDefinition:
		var keys: Array = definition.stat_modifiers.keys()
		keys.sort()
		for key in keys:
			lines.append("%s  %+.1f" % [String(key).replace("_", " ").capitalize(), definition.stat_modifiers[key]])
		if definition is WeaponDefinition:
			lines.append("Damage  %.1f" % definition.base_damage)
			lines.append("Stamina cost  %.1f" % definition.stamina_cost)
		lines.append("Durability  %d / %d" % [stack.durability, definition.max_durability] if definition.max_durability > 0 else "Durability  —")
	body_label.text = "\n\n".join(lines)
	reset_size()
	show()
	_place()
	call_deferred("_place")

func clear() -> void:
	hide()
	if is_node_ready():
		title_label.text = ""
		body_label.text = ""

func _process(_delta: float) -> void:
	if visible:
		_place()

func _place() -> void:
	if not is_inside_tree():
		return
	var bounds := get_viewport_rect().size
	var factor := minf(1.0, minf((bounds.x - 16.0) / size.x, (bounds.y - 16.0) / size.y))
	scale = Vector2.ONE * maxf(0.1, factor)
	position = (get_global_mouse_position() + Vector2(18, 18)).clamp(Vector2(8, 8), (bounds - size * scale - Vector2(8, 8)).max(Vector2(8, 8)))
