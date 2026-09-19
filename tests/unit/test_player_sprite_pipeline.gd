extends RefCounted
## Stage-10 sprite asset pipeline. Covers the path from an authored manifest to
## the SpriteFrames the game ships, and the rules that keep art swaps from
## reaching gameplay.
##
## Production art is not required for any of this: the pipeline is tested on
## synthetic sheets, and the shipped profile is checked in whichever state it is
## actually in.

const PLAYER_ANIMATION_PROFILE := preload("res://presentation/player/player_animation_profile.tres")
const CELL := 16

func run(t: Node) -> void:
	_test_entry_validation(t)
	_test_manifest_validation(t)
	_test_builder_slicing(t)
	_test_builder_metadata(t)
	_test_determinism(t)
	_test_save_round_trip(t)
	_test_frame_integrity(t)
	_test_shipped_profile_state(t)
	await _test_presentation_transform(t)

## A sheet whose cells are each a flat, distinct colour, so a frame landing in
## the wrong cell is visible as a wrong colour rather than as a subtle offset.
func _sheet_texture(columns: int, rows: int) -> ImageTexture:
	var image := Image.create(columns * CELL, rows * CELL, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.0, 0.0, 0.0, 0.0))
	for row in rows:
		for column in columns:
			var index := row * columns + column
			image.fill_rect(
				Rect2i(column * CELL, row * CELL, CELL, CELL),
				_cell_color(index)
			)
	return ImageTexture.create_from_image(image)

## Exact 8-bit channel values, so a colour survives the round trip through an
## RGBA8 image without the comparison having to allow for rounding.
func _cell_color(index: int) -> Color:
	return Color8(16 * index + 8, 64, 128, 255)

func _entry(semantic: StringName, columns: int = 4, rows: int = 2, frame_count: int = 8) -> PlayerSpriteAnimationEntry:
	var entry := PlayerSpriteAnimationEntry.new()
	entry.semantic_name = semantic
	entry.texture = _sheet_texture(columns, rows)
	entry.columns = columns
	entry.rows = rows
	entry.frame_count = frame_count
	entry.fps = 12.0
	entry.loop = true
	return entry

func _complete_manifest() -> PlayerSpriteManifest:
	var manifest := PlayerSpriteManifest.new()
	var entries: Array[PlayerSpriteAnimationEntry] = []
	for semantic in PlayerSpriteManifest.REQUIRED_SEMANTICS:
		var entry := _entry(semantic)
		entry.loop = not String(semantic).begins_with("attack_")
		entries.append(entry)
	manifest.animations = entries
	return manifest

func _has(errors: PackedStringArray, needle: String) -> bool:
	for error in errors:
		if error.findn(needle) >= 0:
			return true
	return false

func _test_entry_validation(t: Node) -> void:
	var entry := _entry(&"run")
	t.assert_true(entry.validation_errors().is_empty(), "a 4x2 eight-frame entry validates")
	t.assert_equal(entry.frame_size(), Vector2i(CELL, CELL), "frame size divides the sheet evenly")
	t.assert_true(not "id" in entry, "PlayerSpriteAnimationEntry is a plain Resource, not registry content")

	var unnamed := _entry(&"run")
	unnamed.semantic_name = &""
	t.assert_true(_has(unnamed.validation_errors(), "semantic_name"), "an unnamed entry is rejected")

	var textureless := _entry(&"run")
	textureless.texture = null
	t.assert_true(_has(textureless.validation_errors(), "texture is missing"), "an entry without a texture is rejected")

	var overflowing := _entry(&"run")
	overflowing.frame_count = 9
	t.assert_true(_has(overflowing.validation_errors(), "exceeds"), "more frames than grid cells is rejected")

	# An uneven grid would silently shift every frame after the first.
	var ragged := PlayerSpriteAnimationEntry.new()
	ragged.semantic_name = &"run"
	var ragged_image := Image.create(63, 32, false, Image.FORMAT_RGBA8)
	ragged_image.fill(Color.TRANSPARENT)
	ragged.texture = ImageTexture.create_from_image(ragged_image)
	ragged.columns = 4
	ragged.rows = 2
	ragged.frame_count = 8
	t.assert_true(_has(ragged.validation_errors(), "not divisible by 4 columns"), "a width the columns do not divide is rejected")
	t.assert_equal(ragged.frame_size(), Vector2i.ZERO, "an uneven sheet reports no frame size")
	ragged.columns = 3
	t.assert_true(_has(ragged.validation_errors(), "not divisible by 2 rows") == false, "63x32 divides into 3 columns and 2 rows")

	for invalid_fps in [0.0, -4.0, NAN, INF]:
		var broken := _entry(&"run")
		broken.fps = invalid_fps
		t.assert_true(_has(broken.validation_errors(), "fps"), "fps %s is rejected" % invalid_fps)

	# Fewer frames than cells is normal authoring, not an error.
	var partial := _entry(&"jump", 4, 2, 6)
	t.assert_true(partial.validation_errors().is_empty(), "a six-frame clip on a 4x2 sheet validates")
	t.assert_equal(partial.region_for(5), Rect2(CELL, CELL, CELL, CELL), "frame 5 is the second cell of the second row")
	t.assert_equal(partial.region_for(6), Rect2(), "cells past frame_count have no region")

	# The production canvas is advisory: a different one warns, it does not fail.
	t.assert_true(not partial.preferred_layout_warnings().is_empty(), "a non-production frame canvas warns")
	var production := PlayerSpriteAnimationEntry.new()
	production.semantic_name = &"idle"
	var production_image := Image.create(
		PlayerSpriteAnimationEntry.PREFERRED_SHEET_SIZE.x,
		PlayerSpriteAnimationEntry.PREFERRED_SHEET_SIZE.y,
		false,
		Image.FORMAT_RGBA8
	)
	production_image.fill(Color.TRANSPARENT)
	production.texture = ImageTexture.create_from_image(production_image)
	t.assert_true(production.validation_errors().is_empty(), "the canonical 1024x512 4x2 sheet validates")
	t.assert_equal(production.frame_size(), PlayerSpriteAnimationEntry.PREFERRED_FRAME_SIZE, "the canonical sheet cuts into 256x256 frames")
	t.assert_true(production.preferred_layout_warnings().is_empty(), "the canonical sheet raises no warning")

func _test_manifest_validation(t: Node) -> void:
	var empty := PlayerSpriteManifest.new()
	t.assert_true(_has(empty.validation_errors(), "at least one"), "an empty manifest is rejected")

	var manifest := _complete_manifest()
	t.assert_true(manifest.validation_errors().is_empty(), "a complete manifest validates")
	t.assert_true(manifest.production_readiness_errors().is_empty(), "a complete manifest is production ready")
	t.assert_true(manifest.missing_required_semantics().is_empty(), "a complete manifest is missing no clip")
	t.assert_equal(manifest.entry(&"idle").semantic_name, &"idle", "entries are found by semantic name")
	t.assert_true(manifest.entry(&"nonexistent") == null, "an unknown semantic has no entry")
	t.assert_true(not "id" in manifest, "PlayerSpriteManifest is a plain Resource, not registry content")

	var duplicated := _complete_manifest()
	duplicated.animations.append(_entry(&"idle"))
	t.assert_true(_has(duplicated.validation_errors(), "duplicate"), "a duplicated semantic is rejected")

	var with_null := _complete_manifest()
	with_null.animations.append(null)
	t.assert_true(_has(with_null.validation_errors(), "is null"), "a null entry is rejected")

	# Partial art is structurally fine; it simply is not ready to ship. Keeping
	# these separate is what lets the placeholder stay until every clip exists.
	var partial := PlayerSpriteManifest.new()
	partial.animations = [_entry(&"idle"), _entry(&"run"), _entry(&"attack_1")] as Array[PlayerSpriteAnimationEntry]
	t.assert_true(partial.validation_errors().is_empty(), "a partial manifest is still buildable")
	t.assert_true(not partial.production_readiness_errors().is_empty(), "a partial manifest is not production ready")
	var missing := partial.missing_required_semantics()
	t.assert_equal(missing.size(), PlayerSpriteManifest.REQUIRED_SEMANTICS.size() - 3, "every absent required clip is reported")
	t.assert_true(missing.has(&"death") and missing.has(&"attack_3"), "the report names the clips that are absent")

	for invalid_scale: Vector2 in [Vector2.ZERO, Vector2(-1.0, 1.0), Vector2(1.0, NAN), Vector2(INF, 1.0)]:
		var scaled := _complete_manifest()
		scaled.visual_scale = invalid_scale
		t.assert_true(_has(scaled.validation_errors(), "visual_scale"), "visual_scale %s is rejected" % invalid_scale)
	var offset := _complete_manifest()
	offset.visual_position = Vector2(NAN, 0.0)
	t.assert_true(_has(offset.validation_errors(), "visual_position"), "a non-finite visual_position is rejected")

func _test_builder_slicing(t: Node) -> void:
	var manifest := PlayerSpriteManifest.new()
	manifest.animations = [_entry(&"run")] as Array[PlayerSpriteAnimationEntry]
	var frames := PlayerSpriteFramesBuilder.build(manifest)
	t.assert_true(frames != null, "a valid manifest builds")
	t.assert_true(not frames.has_animation(&"default"), "the builder drops SpriteFrames' default clip")
	t.assert_equal(frames.get_frame_count(&"run"), 8, "every authored frame is added")

	# Row-major, explicitly: the top-right cell is frame 3 and the second row
	# starts at frame 4. Nothing infers snake ordering from the sheet.
	var expected := [
		Rect2(0, 0, CELL, CELL), Rect2(CELL, 0, CELL, CELL),
		Rect2(CELL * 2, 0, CELL, CELL), Rect2(CELL * 3, 0, CELL, CELL),
		Rect2(0, CELL, CELL, CELL), Rect2(CELL, CELL, CELL, CELL),
		Rect2(CELL * 2, CELL, CELL, CELL), Rect2(CELL * 3, CELL, CELL, CELL),
	]
	var atlas_image := (manifest.animations[0].texture as ImageTexture).get_image()
	for index in 8:
		var texture := frames.get_frame_texture(&"run", index) as AtlasTexture
		t.assert_true(texture != null, "frame %d is an AtlasTexture" % index)
		t.assert_equal(texture.region, expected[index], "frame %d is cut from its row-major cell" % index)
		t.assert_true(texture.atlas == manifest.animations[0].texture, "frame %d shares the one sheet texture" % index)
		var sampled := atlas_image.get_pixelv(Vector2i(texture.region.position) + Vector2i(CELL / 2, CELL / 2))
		t.assert_true(sampled.is_equal_approx(_cell_color(index)), "frame %d carries its own cell's pixels" % index)

	var partial := PlayerSpriteManifest.new()
	partial.animations = [_entry(&"jump", 4, 2, 6)] as Array[PlayerSpriteAnimationEntry]
	var partial_frames := PlayerSpriteFramesBuilder.build(partial)
	t.assert_equal(partial_frames.get_frame_count(&"jump"), 6, "unused grid cells produce no frames")

	var invalid := PlayerSpriteManifest.new()
	invalid.animations = [_entry(&"run")] as Array[PlayerSpriteAnimationEntry]
	invalid.animations[0].texture = null
	t.assert_true(PlayerSpriteFramesBuilder.build(invalid) == null, "an invalid manifest builds nothing")
	t.assert_true(PlayerSpriteFramesBuilder.build(null) == null, "a null manifest builds nothing")

func _test_builder_metadata(t: Node) -> void:
	var manifest := _complete_manifest()
	manifest.entry(&"run").fps = 14.0
	manifest.entry(&"idle").fps = 9.0
	manifest.entry(&"death").loop = false
	var frames := PlayerSpriteFramesBuilder.build(manifest)
	t.assert_true(frames != null, "the complete manifest builds")

	var names := frames.get_animation_names()
	t.assert_equal(names.size(), PlayerSpriteManifest.REQUIRED_SEMANTICS.size(), "every authored clip reaches the SpriteFrames")
	for semantic in PlayerSpriteManifest.REQUIRED_SEMANTICS:
		t.assert_true(frames.has_animation(semantic), "clip '%s' exists" % semantic)
		t.assert_true(frames.get_frame_count(semantic) > 0, "clip '%s' has frames" % semantic)
	t.assert_true(is_equal_approx(frames.get_animation_speed(&"run"), 14.0), "authored fps reaches the clip")
	t.assert_true(is_equal_approx(frames.get_animation_speed(&"idle"), 9.0), "each clip keeps its own fps")
	t.assert_true(frames.get_animation_loop(&"run"), "a looping clip stays looping")
	t.assert_true(not frames.get_animation_loop(&"death"), "a one-shot clip does not loop")
	t.assert_true(not frames.get_animation_loop(&"attack_1"), "attack clips are one-shot")

	# The generated clip names are exactly what the shipped profile maps.
	var profile := PLAYER_ANIMATION_PROFILE as CharacterAnimationProfile
	for semantic: StringName in [
		profile.idle_animation, profile.run_animation, profile.jump_animation,
		profile.fall_animation, profile.climb_animation, profile.climb_idle_animation,
		profile.dodge_animation, profile.hurt_animation, profile.death_animation,
	]:
		t.assert_true(frames.has_animation(semantic), "the profile's '%s' name exists in a built SpriteFrames" % semantic)
	for binding in profile.attack_bindings:
		t.assert_true(frames.has_animation(binding.animation_name), "the profile's '%s' attack clip exists in a built SpriteFrames" % binding.animation_name)

func _test_determinism(t: Node) -> void:
	var manifest := _complete_manifest()
	var first := PlayerSpriteFramesBuilder.build(manifest)
	var second := PlayerSpriteFramesBuilder.build(manifest)
	t.assert_true(first != null and second != null, "the determinism fixture builds twice")
	t.assert_true(first != second, "each build produces its own resource")
	t.assert_equal(
		PlayerSpriteFramesBuilder.describe(first),
		PlayerSpriteFramesBuilder.describe(second),
		"the same manifest always produces the same clips, order, regions, fps and loops"
	)

	# Reordering the manifest is an authoring change and must be visible.
	var reordered := _complete_manifest()
	reordered.entry(&"idle").fps = 30.0
	t.assert_true(
		PlayerSpriteFramesBuilder.describe(first) != PlayerSpriteFramesBuilder.describe(PlayerSpriteFramesBuilder.build(reordered)),
		"a changed manifest produces a different build"
	)

## The generated resource is what gets committed, so it has to survive being
## written and read back unchanged — otherwise "regenerate and diff" compares
## the build against a file that never matched it.
func _test_save_round_trip(t: Node) -> void:
	var frames := PlayerSpriteFramesBuilder.build(_complete_manifest())
	var path := "user://test_player_sprite_frames.tres"
	t.assert_equal(ResourceSaver.save(frames, path), OK, "a built SpriteFrames saves as a resource")
	var reloaded := ResourceLoader.load(path, "SpriteFrames", ResourceLoader.CACHE_MODE_IGNORE) as SpriteFrames
	t.assert_true(reloaded != null, "the saved SpriteFrames loads back")
	t.assert_equal(
		PlayerSpriteFramesBuilder.describe(reloaded),
		PlayerSpriteFramesBuilder.describe(frames),
		"a saved and reloaded build keeps its clips, regions, fps and loops"
	)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

## The checks a regenerated or hand-edited SpriteFrames must survive, applied
## here to a synthetic build and below to the shipped profile when it has art.
func _assert_frames_integrity(t: Node, frames: SpriteFrames, label: String) -> void:
	var expected_size := Vector2.ZERO
	for name in frames.get_animation_names():
		var animation := StringName(name)
		var count := frames.get_frame_count(animation)
		t.assert_true(count > 0, "%s: clip '%s' has frames" % [label, animation])
		for index in count:
			var texture := frames.get_frame_texture(animation, index)
			t.assert_true(texture != null, "%s: '%s' frame %d has a texture" % [label, animation, index])
			var atlas := texture as AtlasTexture
			if atlas == null:
				continue
			t.assert_true(atlas.atlas != null, "%s: '%s' frame %d has a source sheet" % [label, animation, index])
			t.assert_true(atlas.region.size.x > 0.0 and atlas.region.size.y > 0.0, "%s: '%s' frame %d has a real region" % [label, animation, index])
			t.assert_true(
				atlas.region.position.x >= 0.0 and atlas.region.position.y >= 0.0
					and atlas.region.end.x <= float(atlas.atlas.get_width())
					and atlas.region.end.y <= float(atlas.atlas.get_height()),
				"%s: '%s' frame %d stays inside its sheet" % [label, animation, index]
			)
			if expected_size == Vector2.ZERO:
				expected_size = atlas.region.size
			t.assert_equal(atlas.region.size, expected_size, "%s: '%s' frame %d shares the one frame canvas" % [label, animation, index])

func _test_frame_integrity(t: Node) -> void:
	var frames := PlayerSpriteFramesBuilder.build(_complete_manifest())
	_assert_frames_integrity(t, frames, "built frames")

func _test_shipped_profile_state(t: Node) -> void:
	var profile := PLAYER_ANIMATION_PROFILE as CharacterAnimationProfile
	t.assert_true(profile != null, "the shipped player animation profile loads")
	t.assert_true(profile.validation_errors().is_empty(), "the shipped profile validates in whatever state it ships")
	t.assert_true(profile.visual_scale.x > 0.0 and profile.visual_scale.y > 0.0, "the shipped visual scale is usable")

	# The player profile specifically needs all three combo clips bound. That is
	# a player rule, not a rule for every character, so it lives here rather than
	# in CharacterAnimationProfile.
	for key: StringName in [&"attack_1", &"attack_2", &"attack_3"]:
		var binding := profile.attack_binding(key)
		t.assert_true(binding != null, "the player profile binds '%s'" % key)
		t.assert_true(binding != null and not binding.animation_name.is_empty(), "'%s' names a clip" % key)

	if profile.sprite_frames == null:
		# Placeholder mode: the pipeline exists, the art does not yet.
		t.assert_true(profile.allow_placeholder, "a profile without art must permit the placeholder")
		return

	# Production mode: everything the presenter can ask for must be there, and
	# the placeholder must be switched off so a missing clip fails loudly.
	t.assert_true(not profile.allow_placeholder, "a profile with production art disables the placeholder")
	for semantic in PlayerSpriteManifest.REQUIRED_SEMANTICS:
		t.assert_true(profile.sprite_frames.has_animation(semantic), "production art provides the '%s' clip" % semantic)
		t.assert_true(profile.sprite_frames.get_frame_count(semantic) > 0, "production clip '%s' has frames" % semantic)
	for binding in profile.attack_bindings:
		var count := profile.sprite_frames.get_frame_count(binding.animation_name)
		t.assert_true(binding.startup_end_frame < binding.active_end_frame, "'%s' keeps a real ACTIVE range" % binding.presentation_key)
		t.assert_true(binding.active_end_frame < count, "'%s' keeps a real RECOVERY range inside %d frames" % [binding.presentation_key, count])
	_assert_frames_integrity(t, profile.sprite_frames, "shipped frames")

func _test_presentation_transform(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node2D.new()
	t.add_child(layer)
	SceneRouter.register_world_layer(layer)
	t.assert_true(SceneRouter.go_to_settlement(), "the sprite transform fixture loads the settlement")
	await t.get_tree().process_frame
	var actor := t.get_tree().get_first_node_in_group(&"player") as PlayerActor
	var visual := actor.player_visual()
	t.assert_true(visual != null, "a presentation actor builds its visual")
	var presenter := visual.get_node("%PlayerAnimationPresenter") as PlayerAnimationPresenter
	var sprite := visual.get_node("%Sprite") as AnimatedSprite2D
	var placeholder := visual.get_node("%PlaceholderVisual") as Node2D
	t.assert_true(presenter != null and sprite != null and placeholder != null, "the visual exposes its presenter and both visual modes")

	var actor_scale := actor.scale
	var collision := actor.get_node("CollisionShape2D") as CollisionShape2D
	var hitbox := actor.get_node("Hitbox") as Area2D
	var hurtbox := actor.get_node("Hurtbox") as Area2D
	var collision_shape := collision.shape
	var hitbox_position := hitbox.position
	var hurtbox_position := hurtbox.position

	# A profile with art shows the sprite; one without shows the polygon. The
	# choice is all-or-nothing, never mixed per clip.
	var placeholder_profile := CharacterAnimationProfile.new()
	presenter.profile = placeholder_profile
	presenter.configure(actor)
	t.assert_true(not sprite.visible and placeholder.visible, "a profile without art keeps the placeholder visible")

	var production_profile := _production_profile()
	presenter.profile = production_profile
	presenter.configure(actor)
	t.assert_true(sprite.visible and not placeholder.visible, "a profile with art shows the sprite and hides the placeholder")
	t.assert_true(sprite.sprite_frames == production_profile.sprite_frames, "the presenter adopts the profile's frames")

	# Visual scale and offset belong to the presentation child alone.
	production_profile.visual_scale = Vector2(2.5, 2.5)
	production_profile.visual_offset = Vector2(0.0, -12.0)
	presenter.configure(actor)
	t.assert_equal(presenter.scale, Vector2(2.5, 2.5), "authored visual scale reaches the presenter")
	t.assert_equal(sprite.position, Vector2(0.0, -12.0), "authored visual offset reaches the sprite")
	t.assert_equal(actor.scale, actor_scale, "the actor root keeps its own scale")
	t.assert_true(collision.shape == collision_shape, "collision geometry is untouched by visual scale")
	t.assert_equal(hitbox.position, hitbox_position, "hitbox placement is untouched by visual scale")
	t.assert_equal(hurtbox.position, hurtbox_position, "hurtbox placement is untouched by visual scale")

	# Facing flips the sign around the authored magnitude rather than replacing it.
	actor.facing = -1.0
	presenter.refresh()
	t.assert_equal(presenter.scale, Vector2(-2.5, 2.5), "facing left mirrors the authored scale")
	t.assert_equal(actor.scale, actor_scale, "facing never touches the actor root")
	actor.facing = 1.0
	presenter.refresh()
	t.assert_equal(presenter.scale, Vector2(2.5, 2.5), "facing right restores the authored scale")

	# Reconfiguring while mirrored keeps the mirror rather than snapping back.
	actor.facing = -1.0
	presenter.refresh()
	presenter.configure(actor)
	t.assert_true(presenter.scale.x < 0.0 and is_equal_approx(absf(presenter.scale.x), 2.5), "reconfiguring preserves the current facing")

	presenter.profile = PLAYER_ANIMATION_PROFILE
	presenter.configure(actor)
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame
	GameSession.start_new_game()

## A profile whose frames came through the real builder, so the presentation
## checks above run against a genuinely generated resource.
func _production_profile() -> CharacterAnimationProfile:
	var profile := CharacterAnimationProfile.new()
	profile.sprite_frames = PlayerSpriteFramesBuilder.build(_complete_manifest())
	profile.allow_placeholder = false
	var bindings: Array[AttackAnimationBinding] = []
	for key: StringName in [&"attack_1", &"attack_2", &"attack_3"]:
		var binding := AttackAnimationBinding.new()
		binding.presentation_key = key
		binding.animation_name = key
		binding.startup_end_frame = 2
		binding.active_end_frame = 4
		bindings.append(binding)
	profile.attack_bindings = bindings
	return profile
