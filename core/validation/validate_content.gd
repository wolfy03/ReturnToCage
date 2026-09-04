extends Node

func _ready() -> void:
	run_validation()

func run_validation() -> void:
	var errors := ContentRegistry.reload_all()
	if errors.is_empty():
		print("CONTENT VALIDATION PASS (%d resources)" % ContentRegistry.all_definitions().size())
		get_tree().quit(0)
	else:
		for error in errors:
			push_error(error)
		print("CONTENT VALIDATION FAIL (%d errors)" % errors.size())
		get_tree().quit(1)
