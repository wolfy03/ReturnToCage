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
## a normal state rather than a broken build. A path the tool cannot use is a
## different answer — that fails whether or not a file happens to sit at it.

func _ready() -> void:
	get_tree().quit(_run())

func _run() -> int:
	# Both spellings are kept. The policy is handed what was typed, so a refusal
	# can name it; the loader and the saver are handed the resolved form, which
	# is what the policy resolves that same argument to. One path, one verdict.
	var raw_manifest_path := _argument("--manifest=", PlayerSpriteBuildPolicy.DEFAULT_MANIFEST)
	var raw_output_path := _argument("--output=", PlayerSpriteBuildPolicy.DEFAULT_OUTPUT)
	var manifest_path := PlayerSpriteBuildPolicy.canonical_resource_path(raw_manifest_path)
	var output_path := PlayerSpriteBuildPolicy.canonical_resource_path(raw_output_path)
	var allow_incomplete := _flag("--allow-incomplete")

	# An unusable path resolves to nothing, and the loader is never asked about
	# it: `ResourceLoader.exists("C:/typo.tres")` answers false, and with no art
	# committed that false would read as "no manifest yet" and exit 0 on a
	# mistyped argument. The policy says what an unusable path means; this only
	# keeps the loader out of that decision.
	var manifest: PlayerSpriteManifest = null
	if not manifest_path.is_empty() and ResourceLoader.exists(manifest_path):
		# A file that is there but is something else is not an absent manifest.
		manifest = ResourceLoader.load(manifest_path, "", ResourceLoader.CACHE_MODE_IGNORE) as PlayerSpriteManifest
		if manifest == null:
			printerr("SPRITE BUILD FAIL: %s is not a PlayerSpriteManifest" % manifest_path)
			return 1

	var decision := PlayerSpriteBuildPolicy.decide(manifest, raw_manifest_path, raw_output_path, allow_incomplete)
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
