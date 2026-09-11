class_name IdentityRecoveryDialog
extends CanvasLayer

signal recover_requested(player_id: StringName)
signal create_new_requested
signal canceled

@onready var overlay: Control = %Overlay
@onready var message_label: Label = %MessageLabel
@onready var saved_at_label: Label = %SavedAtLabel
@onready var candidate_list: ItemList = %CandidateList
@onready var error_label: Label = %RecoveryErrorLabel
@onready var recover_button: Button = %RecoverButton
@onready var create_button: Button = %CreateNewButton
@onready var cancel_button: Button = %CancelButton
@onready var create_confirmation: ConfirmationDialog = %CreateConfirmation

var _candidates: Array[StringName] = []
var _selected_player_id: StringName = &""

func _ready() -> void:
	candidate_list.item_selected.connect(_on_candidate_selected)
	recover_button.pressed.connect(_on_recover_pressed)
	create_button.pressed.connect(_on_create_pressed)
	cancel_button.pressed.connect(canceled.emit)
	create_confirmation.confirmed.connect(create_new_requested.emit)
	overlay.visible = false

func present_inspection(result: Dictionary) -> void:
	_candidates.clear()
	_selected_player_id = &""
	candidate_list.clear()
	error_label.visible = false
	recover_button.text = "Recover"
	recover_button.disabled = true
	create_button.disabled = false
	cancel_button.disabled = false
	var status: int = int(result.get("status", SaveManager.IdentityInspectionStatus.INVALID_SAVE))
	var saved_at := String(result.get("saved_at", ""))
	saved_at_label.text = "Saved: %s" % saved_at if not saved_at.is_empty() else ""
	saved_at_label.visible = not saved_at.is_empty()
	match status:
		SaveManager.IdentityInspectionStatus.SINGLE_CANDIDATE, SaveManager.IdentityInspectionStatus.MULTIPLE_CANDIDATES:
			message_label.text = "Choose the persistent player identity to recover."
			for candidate in result.get("candidates", []):
				var player_id := StringName(candidate)
				_candidates.append(player_id)
				var index := candidate_list.item_count
				candidate_list.add_item(_candidate_label(player_id))
				candidate_list.set_item_tooltip(index, String(player_id))
			candidate_list.visible = true
			if status == SaveManager.IdentityInspectionStatus.SINGLE_CANDIDATE and _candidates.size() == 1:
				candidate_list.select(0)
				_select_candidate(0)
		SaveManager.IdentityInspectionStatus.SAVE_NOT_FOUND:
			message_label.text = "No Save v4 file is available to recover the previous identity."
			candidate_list.visible = false
		_:
			message_label.text = "The current Save cannot be used for identity recovery."
			candidate_list.visible = false
			var backend_error := String(result.get("error", ""))
			if not backend_error.is_empty():
				show_error(backend_error)
	overlay.visible = true

func close_dialog() -> void:
	create_confirmation.hide()
	overlay.visible = false

func is_open() -> bool:
	return overlay.visible

func selected_player_id() -> StringName:
	return _selected_player_id

func candidate_count() -> int:
	return _candidates.size()

func select_candidate(index: int) -> bool:
	if index < 0 or index >= _candidates.size():
		return false
	candidate_list.select(index)
	_select_candidate(index)
	return true

func show_error(message: String) -> void:
	error_label.text = message
	error_label.visible = not message.is_empty()

func set_busy(busy: bool) -> void:
	candidate_list.mouse_filter = Control.MOUSE_FILTER_IGNORE if busy else Control.MOUSE_FILTER_STOP
	recover_button.disabled = busy or _selected_player_id.is_empty()
	create_button.disabled = busy
	cancel_button.disabled = busy

func set_activation_retry(message: String) -> void:
	show_error(message)
	recover_button.text = "Retry Activation"
	recover_button.disabled = false
	create_button.disabled = true

func _on_candidate_selected(index: int) -> void:
	_select_candidate(index)

func _select_candidate(index: int) -> void:
	_selected_player_id = _candidates[index] if index >= 0 and index < _candidates.size() else &""
	recover_button.disabled = _selected_player_id.is_empty()

func _on_recover_pressed() -> void:
	if not _selected_player_id.is_empty():
		recover_requested.emit(_selected_player_id)

func _on_create_pressed() -> void:
	create_confirmation.dialog_text = "Create a new identity? Existing Save player records will not be linked automatically."
	create_confirmation.popup_centered(Vector2i(520, 180))

static func _candidate_label(player_id: StringName) -> String:
	var value := String(player_id)
	var suffix := value.right(12)
	return "Player  •  %s" % suffix
