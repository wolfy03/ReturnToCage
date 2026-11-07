class_name ItemUIStyle
extends RefCounted

const STAT_LABELS := {
	&"max_health": "Max health",
	&"attack_power": "Attack power",
	&"defense": "Defense",
	&"move_speed": "Move speed",
	&"max_stamina": "Max stamina",
	&"stamina_regen": "Stamina regen",
}

const TEXT := Color("eadcc0")
const MUTED := Color("a9b39a")
const ACCENT := Color("d7bb7a")

static func box(fill: Color, edge: Color, border: int = 1) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = edge
	style.set_border_width_all(border)
	style.set_corner_radius_all(2)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 5
	style.content_margin_bottom = 5
	return style

static func make_theme() -> Theme:
	var result := Theme.new()
	result.default_font_size = 14
	result.set_color("font_color", "Label", TEXT)
	result.set_color("font_color", "Button", TEXT)
	result.set_color("font_hover_color", "Button", Color("fff0cb"))
	result.set_color("font_pressed_color", "Button", Color("fff0cb"))
	result.set_color("font_disabled_color", "Button", MUTED.darkened(0.2))
	result.set_stylebox("normal", "Button", box(Color("293c30"), Color("647058")))
	result.set_stylebox("hover", "Button", box(Color("3b5140"), ACCENT))
	result.set_stylebox("pressed", "Button", box(Color("465b41"), ACCENT, 2))
	result.set_stylebox("disabled", "Button", box(Color("222c25"), Color("404a3e")))
	result.set_stylebox("focus", "Button", box(Color(0, 0, 0, 0), ACCENT, 2))
	var panel := box(Color("2d2a20"), Color("8f825e"), 2)
	panel.shadow_color = Color(0, 0, 0, 0.4)
	panel.shadow_size = 5
	panel.shadow_offset = Vector2(2, 3)
	result.set_stylebox("panel", "PanelContainer", panel)
	return result
