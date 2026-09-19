extends Node
## CI entry point for the sprite pipeline repository check. Runs from
## tools/check_project.py, never from the game.

func _ready() -> void:
	get_tree().quit(_run())

func _run() -> int:
	var errors := PlayerSpritePipelineValidator.validate_repository()
	if not errors.is_empty():
		# One header and every finding under it, so a run tells an author
		# everything that is wrong rather than the first thing.
		printerr("SPRITE PIPELINE FAIL:")
		for error in errors:
			printerr("  - %s" % error)
		return 1
	# An in-progress state is legal and must not look like a problem: printing it
	# as a warning would fail check_project.py, which treats warnings as errors.
	if not ResourceLoader.exists(PlayerSpritePipelineValidator.MANIFEST_PATH):
		print("SPRITE PIPELINE INCOMPLETE: no manifest yet; the placeholder is active")
	print("SPRITE PIPELINE VALIDATION PASS")
	return 0
