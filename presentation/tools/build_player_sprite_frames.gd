extends Node
## Headless entry point for regenerating a character's SpriteFrames from its
## manifest, so CI can rebuild and diff rather than trusting a committed file.
##
## Usage:
##   godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
##       --manifest=res://assets/characters/player_hamster/player_hamster_sprite_manifest.tres \
##       --output=res://assets/characters/player_hamster/player_hamster_sprite_frames.tres
##
## With no manifest argument it reports that there is nothing to build and
## succeeds: the pipeline exists before the art does, and an absent manifest is
## a normal state rather than a broken build.

const DEFAULT_MANIFEST := "res://assets/characters/player_hamster/player_hamster_sprite_manifest.tres"
const DEFAULT_OUTPUT := "res://assets/characters/player_hamster/player_hamster_sprite_frames.tres"

func _ready() -> void:
	get_tree().quit(_run())

func _run() -> int:
	var manifest_path := _argument("--manifest=", DEFAULT_MANIFEST)
	var output_path := _argument("--output=", DEFAULT_OUTPUT)
	if not ResourceLoader.exists(manifest_path):
		print("SPRITE BUILD SKIPPED: no manifest at %s" % manifest_path)
		return 0
	var manifest := load(manifest_path) as PlayerSpriteManifest
	if manifest == null:
		printerr("SPRITE BUILD FAIL: %s is not a PlayerSpriteManifest" % manifest_path)
		return 1
	var errors := manifest.validation_errors()
	if not errors.is_empty():
		for error in errors:
			printerr("SPRITE BUILD FAIL: %s" % error)
		return 1
	for warning in manifest.preferred_layout_warnings():
		print("SPRITE BUILD WARNING: %s" % warning)
	# Completeness is reported, not enforced: a partial manifest still builds so
	# the art in hand can be previewed. Activating it in the shipped profile is
	# the step that requires every clip.
	var missing := manifest.missing_required_semantics()
	if not missing.is_empty():
		print("SPRITE BUILD INCOMPLETE: missing %s" % ", ".join(missing))
	var frames := PlayerSpriteFramesBuilder.build(manifest)
	if frames == null:
		printerr("SPRITE BUILD FAIL: builder rejected the manifest")
		return 1
	var status := ResourceSaver.save(frames, output_path)
	if status != OK:
		printerr("SPRITE BUILD FAIL: could not write %s (error %d)" % [output_path, status])
		return 1
	print("SPRITE BUILD PASS: %d clips -> %s" % [frames.get_animation_names().size(), output_path])
	return 0

func _argument(prefix: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.substr(prefix.length())
	return fallback
