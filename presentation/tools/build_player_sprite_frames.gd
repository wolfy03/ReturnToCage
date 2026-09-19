extends Node
## Headless entry point for regenerating a character's SpriteFrames from its
## manifest, so CI can rebuild and diff rather than trusting a committed file.
##
## Production build (the default) refuses an incomplete manifest:
##
##   godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn
##
## Preview build, for art that is still arriving. It must name its own output;
## the shipped resource is off limits to it:
##
##   godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
##       --allow-incomplete --output=user://player_hamster_preview_frames.tres
##
## A build from a manifest other than the shipped one is a preview by
## definition and must name its own output, whether or not it is complete:
##
##   godot --headless --path . res://presentation/tools/build_player_sprite_frames.tscn -- \
##       --manifest=res://sandbox/experiment_manifest.tres \
##       --output=user://experiment_frames.tres
##
## With no manifest at all it reports that there is nothing to build and
## succeeds: the pipeline exists before the art does, and an absent manifest is
## a normal state rather than a broken build.

func _ready() -> void:
	get_tree().quit(_run())

func _run() -> int:
	var manifest_path := _argument("--manifest=", PlayerSpriteBuildPolicy.DEFAULT_MANIFEST)
	var output_path := _argument("--output=", PlayerSpriteBuildPolicy.DEFAULT_OUTPUT)
	var allow_incomplete := _flag("--allow-incomplete")
	var manifest: PlayerSpriteManifest = null
	if ResourceLoader.exists(manifest_path):
		manifest = load(manifest_path) as PlayerSpriteManifest
		if manifest == null:
			printerr("SPRITE BUILD FAIL: %s is not a PlayerSpriteManifest" % manifest_path)
			return 1
	var decision := PlayerSpriteBuildPolicy.decide(manifest, manifest_path, output_path, allow_incomplete)
	if decision.is_skip():
		print("SPRITE BUILD SKIPPED: %s (%s)" % [manifest_path, decision.reason])
		return 0
	if decision.is_reject():
		printerr("SPRITE BUILD FAIL: %s" % decision.reason)
		return 1
	for warning in manifest.preferred_layout_warnings():
		print("SPRITE BUILD WARNING: %s" % warning)
	if allow_incomplete:
		var missing := manifest.missing_required_semantics()
		if not missing.is_empty():
			print("SPRITE BUILD PREVIEW: missing %s" % ", ".join(missing))
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

func _flag(name: String) -> bool:
	return OS.get_cmdline_user_args().has(name)
