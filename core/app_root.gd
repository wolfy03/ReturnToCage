extends Node

@onready var world_layer: Node = %WorldLayer
@onready var menu: Control = %MainMenu
@onready var error_label: Label = %ErrorLabel

func _ready() -> void:
	SceneRouter.register_world_layer(world_layer)
	%NewGameButton.pressed.connect(_start_new_game)
	%LoadGameButton.pressed.connect(_load_game)
	var errors := ContentRegistry.validate_all()
	if not errors.is_empty():
		error_label.text = "Content validation failed:\n%s" % "\n".join(errors)
		error_label.visible = true

func _start_new_game() -> void:
	GameSession.start_new_game()
	menu.visible = false
	SceneRouter.go_to_settlement()

func _load_game() -> void:
	if SaveManager.load_game():
		menu.visible = false
		SceneRouter.go_to_settlement()
	else:
		error_label.text = "No valid save found"
		error_label.visible = true
