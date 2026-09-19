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

## The only schemes a build may read from or write to. A build tool that
## accepts a bare filesystem path is a tool that can overwrite anything on the
## machine, which is not what this one is for.
const SUPPORTED_SCHEMES: PackedStringArray = ["res://", "user://"]

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

## One spelling per file, so that protection cannot be stepped around by
## writing the same path differently.
##
## `foo/../bar.tres`, `./bar.tres` and `a//bar.tres` all name the file that
## `bar.tres` names, and a raw string comparison says none of them is it. That
## is the whole bypass: a production build that reaches the shipped resource
## through a detour passes a check that was supposed to stop it.
##
## Resolution is textual and self-contained rather than going through
## [method ProjectSettings.globalize_path], because the policy is a pure
## function tested in memory and must not depend on where — or whether — the
## project is mounted on disk. `res://` and `user://` stay distinct: they are
## different roots, and collapsing them would let a preview path claim to be
## the shipped one.
##
## Returns an empty string for anything that is not a usable project path: an
## empty path, an unsupported scheme, a path that climbs out of its own root,
## or one that resolves to the root itself. Callers treat that as a refusal.
static func canonical_resource_path(path: String) -> String:
	var scheme := ""
	for candidate in SUPPORTED_SCHEMES:
		if path.begins_with(candidate):
			scheme = candidate
			break
	if scheme.is_empty():
		return ""
	# split(..., false) drops empty pieces, which is what collapses `a//b`.
	var segments := path.substr(scheme.length()).split("/", false)
	var resolved := PackedStringArray()
	for segment in segments:
		if segment == ".":
			continue
		if segment == "..":
			if resolved.is_empty():
				# Climbing above res:// or user:// names nothing this tool owns.
				return ""
			resolved.remove_at(resolved.size() - 1)
			continue
		resolved.append(segment)
	if resolved.is_empty():
		return ""
	return scheme + "/".join(resolved)

## Whether [param path] names the resource the game ships, however it is spelled.
static func is_production_output(path: String) -> bool:
	var canonical := canonical_resource_path(path)
	return not canonical.is_empty() and canonical == canonical_resource_path(DEFAULT_OUTPUT)

## Whether [param path] names the manifest the repository check regenerates from.
static func is_production_manifest(path: String) -> bool:
	var canonical := canonical_resource_path(path)
	return not canonical.is_empty() and canonical == canonical_resource_path(DEFAULT_MANIFEST)

## [param manifest] is null when there is no manifest to build from at all,
## which is the normal state before the art exists and is not a failure.
## [param manifest_path] is where that manifest was loaded from; it decides
## whether this build is allowed to write the shipped resource at all.
##
## The paths are judged before the manifest is. "This file does not exist yet"
## and "you typed a path this tool cannot use" are different answers, and
## checking existence first collapses them: with no art committed, every
## `--manifest=C:/typo.tres` would load nothing, skip, and exit 0 as though the
## argument had been fine. A path the tool cannot own is wrong whether or not
## anything happens to be sitting at it.
static func decide(
	manifest: PlayerSpriteManifest,
	manifest_path: String,
	output_path: String,
	allow_incomplete: bool
) -> Result:
	var canonical_manifest := canonical_resource_path(manifest_path)
	if canonical_manifest.is_empty():
		return Result.new(
			Decision.REJECT,
			"'%s' is not a readable project path; --manifest must be a res:// or user:// path" % manifest_path
		)
	var canonical_output := canonical_resource_path(output_path)
	if canonical_output.is_empty():
		return Result.new(
			Decision.REJECT,
			"'%s' is not a writable project path; --output must be a res:// or user:// path" % output_path
		)
	# Both paths are usable; there is simply nothing at this one yet. That is
	# where the project is before the art exists, and it is not a failure.
	if manifest == null:
		return Result.new(Decision.SKIP, "there is no manifest to build from")
	var structural := manifest.validation_errors()
	if not structural.is_empty():
		return Result.new(Decision.REJECT, "; ".join(structural))
	var writes_production := canonical_output == canonical_resource_path(DEFAULT_OUTPUT)
	# Only the manifest the repository check regenerates from may write the
	# resource that check compares against. A complete manifest is no exception:
	# completeness says the art is all there, not that this is the shipped art.
	if writes_production and canonical_manifest != canonical_resource_path(DEFAULT_MANIFEST):
		return Result.new(
			Decision.REJECT,
			"only %s may write the production path %s; '%s' must choose another --output"
				% [DEFAULT_MANIFEST, DEFAULT_OUTPUT, manifest_path]
		)
	# A preview build never writes the shipped resource, complete or not. The
	# flag is how someone says "this output is not the real thing".
	if allow_incomplete and writes_production:
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
