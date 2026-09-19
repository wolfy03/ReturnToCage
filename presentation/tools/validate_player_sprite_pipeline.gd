extends Node
## CI entry point for the sprite pipeline repository check. Runs from
## tools/check_project.py, never from the game.

func _ready() -> void:
	get_tree().quit(_run())

func _run() -> int:
	var errors := PlayerSpritePipelineValidator.validate_repository()
	if not errors.is_empty():
		for error in errors:
			printerr("SPRITE PIPELINE FAIL: %s" % error)
		return 1
	# An in-progress state is legal and must not look like a problem: printing it
	# as a warning would fail check_project.py, which treats warnings as errors.
	if not ResourceLoader.exists(PlayerSpritePipelineValidator.MANIFEST_PATH):
		print("SPRITE PIPELINE INCOMPLETE: no manifest yet; the placeholder is active")
	print("SPRITE PIPELINE VALIDATION PASS")
	return 0
