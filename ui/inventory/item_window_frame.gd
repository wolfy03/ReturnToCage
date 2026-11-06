class_name ItemWindowFrame
extends PanelContainer

signal closed
var _dragging := false
var _drag_offset := Vector2.ZERO
@onready var title_bar: Control = %TitleBar
@onready var close_button: Button = %CloseButton

func _ready() -> void:
	theme = ItemUIStyle.make_theme()
	title_bar.gui_input.connect(_on_title_input)
	close_button.pressed.connect(hide_window)
	visibility_changed.connect(_on_visibility_changed)
	get_viewport().size_changed.connect(fit_to_viewport)
	call_deferred("fit_to_viewport")

func _exit_tree() -> void:
	if get_viewport().size_changed.is_connected(fit_to_viewport):
		get_viewport().size_changed.disconnect(fit_to_viewport)

func show_window() -> void:
	show()
	fit_to_viewport()
	get_parent().move_child(self, -1)

func hide_window() -> void:
	hide()
	_dragging = false
	closed.emit()

func _on_visibility_changed() -> void:
	if not visible:
		_dragging = false

func fit_to_viewport() -> void:
	var bounds := get_viewport_rect().size
	var factor := minf(1.0, minf((bounds.x - 16.0) / size.x, (bounds.y - 16.0) / size.y))
	scale = Vector2.ONE * maxf(0.1, factor)
	position = position.clamp(Vector2(8, 8), (bounds - size * scale - Vector2(8, 8)).max(Vector2(8, 8)))

func _on_title_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_dragging = true
		_drag_offset = get_global_mouse_position() - position
		get_parent().move_child(self, -1)
		title_bar.accept_event()

func _input(event: InputEvent) -> void:
	if not visible or not _dragging:
		return
	if event is InputEventMouseMotion:
		position = event.position - _drag_offset
		fit_to_viewport()
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		_dragging = false
		get_viewport().set_input_as_handled()
