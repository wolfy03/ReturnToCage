class_name PlayerSpriteBuildPolicy
extends RefCounted
## Decides whether a sprite build may run, and where it may write.
##
## Separated from the build scene so the rule can be tested directly instead of
## by launching a process and reading its exit code.
##
## The rule exists because the default output path is the resource the game
## ships. A manifest with three clips in it builds perfectly well — and writing
## that over the production SpriteFrames would leave the repository claiming to
## have art it does not have. So an incomplete build has to say so, and when it
## does it loses the right to the shipped path.
##
## The same reasoning covers where a build reads from. The repository check
## regenerates the shipped resource from the default manifest and diffs it, so
## the shipped resource has to be the default manifest's output and nothing
## else. A build from some other manifest may be entirely valid and still not
## be that file — writing it to the shipped path would produce a resource that
## no longer matches its declared source, which CI would then report as stale
## long after whoever ran the build had moved on.

enum Decision { BUILD, SKIP, REJECT }

const DEFAULT_MANIFEST := "res://assets/characters/player_hamster/player_hamster_sprite_manifest.tres"
const DEFAULT_OUTPUT := "res://assets/characters/player_hamster/player_hamster_sprite_frames.tres"

class Result extends RefCounted:
	var decision: Decision
	var reason: String

	func _init(p_decision: Decision, p_reason: String = "") -> void:
		decision = p_decision
		reason = p_reason

	func is_build() -> bool:
		return decision == Decision.BUILD

	func is_skip() -> bool:
		return decision == Decision.SKIP

	func is_reject() -> bool:
		return decision == Decision.REJECT

## [param manifest] is null when there is no manifest to build from at all,
## which is the normal state before the art exists and is not a failure.
## [param manifest_path] is where that manifest was loaded from; it decides
## whether this build is allowed to write the shipped resource at all.
static func decide(
	manifest: PlayerSpriteManifest,
	manifest_path: String,
	output_path: String,
	allow_incomplete: bool
) -> Result:
	if manifest == null:
		return Result.new(Decision.SKIP, "there is no manifest to build from")
	var structural := manifest.validation_errors()
	if not structural.is_empty():
		return Result.new(Decision.REJECT, "; ".join(structural))
	# Only the manifest the repository check regenerates from may write the
	# resource that check compares against. A complete manifest is no exception:
	# completeness says the art is all there, not that this is the shipped art.
	if output_path == DEFAULT_OUTPUT and manifest_path != DEFAULT_MANIFEST:
		return Result.new(
			Decision.REJECT,
			"only %s may write the production path %s; %s must choose another --output"
				% [DEFAULT_MANIFEST, DEFAULT_OUTPUT, manifest_path]
		)
	# A preview build never writes the shipped resource, complete or not. The
	# flag is how someone says "this output is not the real thing".
	if allow_incomplete and output_path == DEFAULT_OUTPUT:
		return Result.new(
			Decision.REJECT,
			"an incomplete build may not write the production path %s; choose another --output" % DEFAULT_OUTPUT
		)
	if not allow_incomplete:
		var missing := manifest.missing_required_semantics()
		if not missing.is_empty():
			return Result.new(
				Decision.REJECT,
				"a production build needs every clip; missing %s (use --allow-incomplete with a non-production --output to preview)"
					% ", ".join(missing)
			)
	return Result.new(Decision.BUILD)
