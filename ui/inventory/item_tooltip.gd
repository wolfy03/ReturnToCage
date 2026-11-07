class_name ItemTooltip
extends PanelContainer

var _anchor: Control

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

func show_item(stack: ItemStack, definition: ItemDefinition, owner: PlayerState = null, anchor: Control = null) -> void:
	if stack == null:
		clear()
		return
	_anchor = anchor
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
		if stack.durability == 0:
			lines.append("Broken · equipment stats inactive")
		if owner != null:
			lines.append_array(_comparison(owner, stack, definition))
	body_label.text = "\n\n".join(lines)
	reset_size()
	show()
	_place()
	call_deferred("_place")

func _comparison(owner: PlayerState, stack: ItemStack, definition: EquipmentDefinition) -> Array[String]:
	var projected := owner.preview_equipment_stats(stack)
	if projected == null:
		return []
	var equipped := owner.equipment.equipped(definition.equipment_slot)
	var current := ContentRegistry.get_item(equipped.item_id) as EquipmentDefinition if equipped != null else null
	var name_text := current.display_name if current != null else "Empty slot"
	if equipped != null and equipped.durability == 0:
		name_text += " (broken)"
	var current_lines: Array[String] = ["Equipped: " + name_text]
	if current != null and equipped.durability != 0:
		for stat_id: StringName in ItemUIStyle.STAT_LABELS:
			if current.stat_modifiers.has(stat_id):
				current_lines.append("%s  %+.1f" % [ItemUIStyle.STAT_LABELS[stat_id], current.stat_modifiers[stat_id]])
	var changes: Array[String] = ["Change if equipped"]
	for stat_id: StringName in ItemUIStyle.STAT_LABELS:
		var before := owner.stats.value(stat_id)
		var after := projected.value(stat_id)
		if not is_equal_approx(before, after):
			changes.append("%s  %+.1f  (%.1f → %.1f)" % [ItemUIStyle.STAT_LABELS[stat_id], after - before, before, after])
	if changes.size() == 1:
		changes.append("No stat change")
	return ["\n".join(current_lines), "\n".join(changes)]

func clear() -> void:
	_anchor = null
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
	var origin := get_global_mouse_position()
	if is_instance_valid(_anchor) and _anchor.is_visible_in_tree():
		var rect := _anchor.get_global_rect()
		origin = Vector2(rect.end.x, rect.position.y)
	position = (origin + Vector2(18, 18)).clamp(Vector2(8, 8), (bounds - size * scale - Vector2(8, 8)).max(Vector2(8, 8)))
