extends RefCounted

const PLAYER_SCENE := preload("res://gameplay/actors/player/player.tscn")
const PLAYER_ANIMATION_PROFILE := preload("res://presentation/player/player_animation_profile.tres")

func run(t: Node) -> void:
	_test_profile_validation(t)
	_test_phase_frame_mapping(t)
	_test_payload_validation(t)
	await _test_scene_separation(t)
	await _test_authoritative_attack_sync(t)
	await _test_presenter_resolution(t)
	GameSession.start_new_game()

func _test_profile_validation(t: Node) -> void:
	var shipped_profile := PLAYER_ANIMATION_PROFILE as CharacterAnimationProfile
	t.assert_true(shipped_profile != null, "the shipped player animation profile loads")
	t.assert_true(shipped_profile.validation_errors().is_empty(), "the shipped placeholder animation profile validates")

	var placeholder := CharacterAnimationProfile.new()
	t.assert_true(placeholder.validation_errors().is_empty(), "a null SpriteFrames placeholder profile is valid")
	placeholder.allow_placeholder = false
	t.assert_true(not placeholder.validation_errors().is_empty(), "a profile without frames rejects disabled placeholder mode")

	var profile := _synthetic_profile()
	t.assert_true(profile.validation_errors().is_empty(), "a complete synthetic animation profile validates")
	var duplicate := _binding(&"attack_1", &"attack_2")
	profile.attack_bindings.append(duplicate)
	t.assert_true(_has_error(profile.validation_errors(), "duplicate"), "duplicate attack presentation keys are rejected")
	profile.attack_bindings.pop_back()

	profile.sprite_frames.remove_animation(&"run")
	t.assert_true(_has_error(profile.validation_errors(), "run animation"), "missing locomotion animation is rejected")
	profile = _synthetic_profile()
	profile.sprite_frames.add_animation(&"empty_attack")
	profile.attack_bindings[0].animation_name = &"empty_attack"
	t.assert_true(_has_error(profile.validation_errors(), "contain frames"), "a zero-frame attack animation is rejected")
	profile = _synthetic_profile()
	profile.attack_bindings[0].startup_end_frame = 4
	profile.attack_bindings[0].active_end_frame = 4
	t.assert_true(_has_error(profile.validation_errors(), "active frame range"), "an empty ACTIVE frame partition is rejected")
	profile = _synthetic_profile()
	profile.attack_bindings[0].active_end_frame = 8
	t.assert_true(_has_error(profile.validation_errors(), "recovery frame range"), "an empty RECOVERY frame partition is rejected")

	var weapon := ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition
	t.assert_equal(weapon.attack_combo.step(0).presentation_key, &"attack_1", "twig step 0 maps to attack_1")
	t.assert_equal(weapon.attack_combo.step(1).presentation_key, &"attack_2", "twig step 1 maps to attack_2")
	t.assert_equal(weapon.attack_combo.step(2).presentation_key, &"attack_3", "twig step 2 maps to attack_3")
	var invalid_attack := AttackDefinition.new()
	invalid_attack.presentation_key = &""
	t.assert_true(_has_error(invalid_attack.validation_errors(), "presentation_key"), "an empty attack presentation key is invalid")

func _test_phase_frame_mapping(t: Node) -> void:
	var binding := _binding(&"attack_1", &"attack_1")
	t.assert_equal(PlayerAnimationPresenter.attack_frame(0.05, 0.10, 0.12, 0.33, binding, 8), 1, "startup midpoint maps inside frames 0..1")
	t.assert_equal(PlayerAnimationPresenter.attack_frame(0.10, 0.10, 0.12, 0.33, binding, 8), 2, "ACTIVE boundary maps to its first frame")
	t.assert_equal(PlayerAnimationPresenter.attack_frame(0.219, 0.10, 0.12, 0.33, binding, 8), 3, "ACTIVE end remains inside frames 2..3")
	t.assert_equal(PlayerAnimationPresenter.attack_frame(0.385, 0.10, 0.12, 0.33, binding, 8), 6, "recovery midpoint maps inside frames 4..7")
	t.assert_true(PlayerAnimationPresenter.attack_frame(0.50, 0.10, 0.12, 0.33, binding, 8) >= 4, "large elapsed presentation seeks directly into recovery")

func _test_payload_validation(t: Node) -> void:
	t.assert_true(NetworkManager.valid_attack_presentation(0, 1.0, 0, &"attack_1", 0.1, 0.12, 0.33), "valid attack presentation metadata is accepted")
	for invalid in [
		[-1, 1.0, 0, &"attack_1", 0.1, 0.12, 0.33],
		[0, 0.0, 0, &"attack_1", 0.1, 0.12, 0.33],
		[0, NAN, 0, &"attack_1", 0.1, 0.12, 0.33],
		[0, 1.0, -1, &"attack_1", 0.1, 0.12, 0.33],
		[0, 1.0, 0, &"", 0.1, 0.12, 0.33],
		[0, 1.0, 0, &"attack_1", NAN, 0.12, 0.33],
		[0, 1.0, 0, &"attack_1", 0.1, 0.0, 0.33],
		[0, 1.0, 0, &"attack_1", 0.1, 0.12, INF],
		[0, 1.0, 0, &"attack_1", 0.1, 0.12, 10.01],
	]:
		t.assert_true(not NetworkManager.valid_attack_presentation(
			invalid[0], invalid[1], invalid[2], invalid[3], invalid[4], invalid[5], invalid[6]
		), "malformed attack presentation metadata is rejected")
	t.assert_true(NetworkManager.valid_dodge_presentation(0, -1.0, 0.3), "valid dodge presentation metadata is accepted")
	t.assert_true(not NetworkManager.valid_dodge_presentation(-1, -1.0, 0.3), "negative dodge presentation sequence is rejected")
	t.assert_true(not NetworkManager.valid_dodge_presentation(0, 0.5, 0.3), "non-canonical dodge direction is rejected")
	t.assert_true(not NetworkManager.valid_dodge_presentation(0, 1.0, NAN), "NaN dodge duration is rejected")
	t.assert_true(not NetworkManager.valid_dodge_presentation(0, 1.0, 0.0), "zero dodge duration is rejected")
	t.assert_true(NetworkManager.valid_hurt_presentation(0, 0.25), "valid HURT presentation metadata is accepted")
	t.assert_true(not NetworkManager.valid_hurt_presentation(-1, 0.25), "negative HURT presentation sequence is rejected")
	t.assert_true(not NetworkManager.valid_hurt_presentation(0, INF), "infinite HURT duration is rejected")
	t.assert_true(not NetworkManager.valid_hurt_presentation(0, 0.0), "zero HURT duration is rejected")
	t.assert_equal(NetworkProtocol.VERSION, 15, "presentation wire expansion uses protocol v15")
	t.assert_equal(SaveManager.CURRENT_VERSION, 4, "presentation runtime does not change Save v4")
	GameSession.start_new_game()
	var save_text := JSON.stringify(GameSession.export_persistent_state())
	t.assert_true(not save_text.contains("animation"), "Save v4 contains no animation state")
	t.assert_true(not save_text.contains("presentation"), "Save v4 contains no presentation state")
	t.assert_true(not save_text.contains("hurt_remaining"), "Save v4 contains no HURT visual timer")
	t.assert_true(not save_text.contains("combat_action"), "Save v4 contains no CombatAction state")

func _test_scene_separation(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node2D.new()
	t.add_child(layer)
	var headless := PLAYER_SCENE.instantiate() as PlayerActor
	headless.setup_player(1, true, false, PlayerWorldState.SETTLEMENT_WORLD_ID)
	layer.add_child(headless)
	await t.get_tree().process_frame
	t.assert_true(headless.player_visual() == null, "presentation-disabled actor instantiates no PlayerVisual")
	t.assert_equal(headless.presentation_anchor.get_child_count(), 0, "headless PresentationAnchor stays empty")
	t.assert_true(headless.find_children("*", "AnimatedSprite2D", true, false).is_empty(), "headless actor contains no AnimatedSprite2D")
	t.assert_true(headless.find_children("*", "PlayerAnimationPresenter", true, false).is_empty(), "headless actor contains no animation presenter")
	t.assert_true(headless.combat_action.is_idle() and headless.combat != null, "headless gameplay remains configured")

	headless.queue_free()
	await t.get_tree().process_frame
	var presented := PLAYER_SCENE.instantiate() as PlayerActor
	presented.setup_player(1, false, true, PlayerWorldState.SETTLEMENT_WORLD_ID)
	layer.add_child(presented)
	await t.get_tree().process_frame
	var visual := presented.player_visual() as PlayerVisual
	t.assert_true(visual != null, "presentation-enabled actor creates PlayerVisual")
	t.assert_equal(presented.presentation_anchor.get_child_count(), 1, "one visual scene is instantiated")
	presented._setup_presentation()
	t.assert_equal(presented.presentation_anchor.get_child_count(), 1, "presentation setup is idempotent")
	t.assert_true(visual.presenter.placeholder.visible and not visual.presenter.sprite.visible, "shipped null SpriteFrames uses the Polygon placeholder")
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_presenter_resolution(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node2D.new()
	t.add_child(layer)
	var actor := PLAYER_SCENE.instantiate() as PlayerActor
	actor.setup_player(1, false, true, PlayerWorldState.SETTLEMENT_WORLD_ID)
	layer.add_child(actor)
	await t.get_tree().process_frame
	var presenter := (actor.player_visual() as PlayerVisual).presenter
	presenter.profile = _synthetic_profile()
	presenter.configure(actor)
	t.assert_true(presenter.sprite.visible and not presenter.placeholder.visible, "synthetic SpriteFrames replaces the placeholder")

	actor.movement.mode = MovementComponent.Mode.GROUND
	actor.velocity = Vector2.ZERO
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"idle", "grounded stationary actor resolves idle")
	presenter.sprite.pause()
	presenter.sprite.frame = 2
	presenter.refresh()
	t.assert_equal(presenter.sprite.frame, 2, "reselecting the same locomotion clip does not restart it")
	actor.velocity.x = 80.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"run", "grounded velocity resolves run")
	actor.movement.mode = MovementComponent.Mode.AIR
	actor.velocity.y = -20.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"jump", "negative AIR velocity resolves jump")
	actor.velocity.y = 0.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"fall", "non-negative AIR velocity resolves fall")
	actor.movement.mode = MovementComponent.Mode.CLIMB
	actor.velocity.y = 30.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"climb", "moving CLIMB resolves climb")
	actor.velocity.y = 0.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"climb_idle", "stationary CLIMB resolves climb_idle")
	var actor_scale_before_climb_facing := actor.scale
	presenter.profile.faces_right_by_default = false
	presenter.profile.climb_ignores_facing = true
	actor.facing = 1.0
	presenter.refresh()
	t.assert_true(presenter.scale.x > 0.0, "left-canonical climb art remains unflipped when climb ignores live facing")
	t.assert_equal(actor.scale, actor_scale_before_climb_facing, "left-canonical climb facing leaves the PlayerActor root unchanged")
	presenter.profile.climb_ignores_facing = false
	presenter.refresh()
	t.assert_true(presenter.scale.x < 0.0, "climb follows live RIGHT facing when facing is not ignored for left-canonical art")
	presenter.profile.faces_right_by_default = true
	presenter.profile.climb_ignores_facing = true

	actor.movement.mode = MovementComponent.Mode.GROUND
	actor.facing = 1.0
	presenter.refresh()
	var actor_scale := actor.scale
	t.assert_true(presenter.scale.x > 0.0, "right-facing canonical art is not flipped")
	actor.facing = -1.0
	presenter.refresh()
	t.assert_true(presenter.scale.x < 0.0, "left facing flips only the visual child")
	t.assert_equal(actor.scale, actor_scale, "facing never flips the PlayerActor root")

	var stamina_before := GameSession.get_player_runtime(actor.peer_id).combat.stamina
	var health_before := actor.health.current_health
	var position_before := actor.position
	var attack_events: Array[int] = []
	var dodge_events: Array[int] = []
	var hurt_events: Array[int] = []
	actor.attack_presented.connect(func(sequence: int, _facing: float, _step: int, _key: StringName, _startup: float, _active: float, _recovery: float) -> void: attack_events.append(sequence))
	actor.dodge_presented.connect(func(sequence: int, _direction: float, _duration: float) -> void: dodge_events.append(sequence))
	actor.hurt_presented.connect(func(sequence: int, _duration: float) -> void: hurt_events.append(sequence))
	actor.network_combat._on_attack_presented_received(actor.peer_id, 9, 0.0, 0, &"attack_1", 0.10, 0.12, 0.33)
	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 9, 0.5, 0.30)
	actor.network_combat._on_hurt_presented_received(actor.peer_id, 9, 0.0)
	t.assert_true(attack_events.is_empty() and dodge_events.is_empty() and hurt_events.is_empty(), "malformed remote presentation payloads are ignored")
	actor.network_combat._on_attack_presented_received(actor.peer_id, 10, -1.0, 0, &"attack_1", 0.10, 0.12, 0.33)
	actor.network_combat._on_attack_presented_received(actor.peer_id, 10, 1.0, 1, &"attack_2", 0.09, 0.12, 0.30)
	t.assert_equal(attack_events, [10] as Array[int], "duplicate attack presentation sequence is ignored")
	actor.facing = 1.0
	presenter.refresh(0.05)
	t.assert_equal(presenter.current_animation(), &"attack_1", "remote attack event overrides locomotion")
	t.assert_true(presenter.scale.x < 0.0, "attack keeps committed LEFT facing despite live RIGHT facing")
	t.assert_equal(presenter.current_combo_step(), 0, "attack event carries combo step 0")
	actor.network_combat._on_attack_presented_received(actor.peer_id, 11, 1.0, 1, &"attack_2", 0.09, 0.12, 0.30)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"attack_2", "combo chain changes directly from attack_1 to attack_2")
	t.assert_true(presenter.current_animation() != &"idle", "combo chain inserts no idle frame")

	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 12, -1.0, 0.30)
	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 11, 1.0, 0.30)
	t.assert_equal(dodge_events, [12] as Array[int], "stale dodge presentation sequence is ignored")
	presenter.refresh(0.05)
	t.assert_equal(presenter.current_animation(), &"dodge", "dodge overrides an attack presentation")
	t.assert_true(presenter.scale.x < 0.0, "dodge direction freezes visual facing")
	actor.network_combat._on_hurt_presented_received(actor.peer_id, 0, 0.25)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"hurt", "HURT overrides dodge and attack")
	t.assert_equal(presenter.current_frame(), 0, "initial HURT starts at frame zero")
	presenter.refresh(0.12)
	t.assert_true(presenter.current_frame() > 0, "HURT visual advances on presentation time")
	actor.network_combat._on_hurt_presented_received(actor.peer_id, 1, 0.25)
	actor.network_combat._on_hurt_presented_received(actor.peer_id, 1, 0.50)
	t.assert_equal(hurt_events, [0, 1] as Array[int], "duplicate HURT presentation sequence is ignored")
	presenter.refresh()
	t.assert_equal(presenter.current_frame(), 0, "HURT refresh restarts the same clip at frame zero")
	actor.network_combat._on_attack_presented_received(actor.peer_id, 13, 1.0, 2, &"attack_3", 0.13, 0.14, 0.38)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"attack_3", "a newer remote Attack replaces an active local HURT visual timer")
	actor.network_combat._on_hurt_presented_received(actor.peer_id, 2, 0.25)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"hurt", "a newer remote HURT replaces an Attack visual")
	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 13, 1.0, 0.30)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"dodge", "a newer remote Dodge replaces an active local HURT visual timer")
	actor.network_combat._on_attack_presented_received(actor.peer_id, 14, -1.0, 0, &"attack_1", 0.10, 0.12, 0.33)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"attack_1", "a newer remote Attack replaces an active local Dodge visual timer")
	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 14, -1.0, 0.30)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"dodge", "a newer remote Dodge replaces an active Attack visual")

	actor.health.current_health = 0.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"death", "death overrides every combat transient")
	actor.network_combat._on_attack_presented_received(actor.peer_id, 15, 1.0, 1, &"attack_2", 0.09, 0.12, 0.30)
	actor.network_dodge._on_dodge_presented_received(actor.peer_id, 15, 1.0, 0.30)
	actor.network_combat._on_hurt_presented_received(actor.peer_id, 3, 0.25)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"death", "Attack, Dodge and HURT events cannot displace the absolute death visual")
	actor.health.current_health = health_before
	t.assert_true(actor.combat_action.is_idle(), "remote presentation events do not mutate CombatAction")
	t.assert_equal(GameSession.get_player_runtime(actor.peer_id).combat.stamina, stamina_before, "remote presentation events spend no stamina")
	t.assert_equal(actor.health.current_health, health_before, "remote presentation events deal no damage")
	t.assert_equal(actor.position, position_before, "remote presentation events do not move the actor")
	actor.velocity = Vector2.ZERO
	presenter.refresh(1.0)
	t.assert_equal(presenter.current_animation(), &"idle", "expired remote transient returns to locomotion")

	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _test_authoritative_attack_sync(t: Node) -> void:
	GameSession.start_new_game()
	var layer := Node2D.new()
	t.add_child(layer)
	var actor := PLAYER_SCENE.instantiate() as PlayerActor
	actor.setup_player(1, true, true, PlayerWorldState.SETTLEMENT_WORLD_ID)
	layer.add_child(actor)
	await t.get_tree().process_frame
	var presenter := (actor.player_visual() as PlayerVisual).presenter
	presenter.profile = _synthetic_profile()
	presenter.configure(actor)
	var definition := (ContentRegistry.get_definition(&"twig_sword") as WeaponDefinition).attack_combo.step(0)
	t.assert_true(actor.combat.attack(-2.0), "authoritative presentation fixture begins an attack")
	t.assert_equal(actor.combat.current_attack_facing(), -1.0, "committed attack facing is canonicalized for presentation payloads")
	actor.facing = 1.0
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"attack_1", "authoritative presenter reads the current AttackDefinition")
	t.assert_true(presenter.scale.x < 0.0, "authoritative attack uses committed facing instead of live facing")
	actor.combat.physics_tick(definition.startup_seconds + definition.active_seconds + 0.12)
	presenter.refresh()
	t.assert_true(presenter.current_frame() >= 4, "authoritative presenter seeks from attack_elapsed into recovery after a large delta")
	t.assert_true(is_equal_approx(actor.combat.attack_elapsed(), definition.startup_seconds + definition.active_seconds + 0.12), "presentation reads but does not change the gameplay attack clock")
	t.assert_true(actor.hurt.begin_hurt(), "authoritative priority fixture enters actual gameplay HURT")
	actor.attack_presented.emit(
		999,
		1.0,
		0,
		&"attack_1",
		definition.startup_seconds,
		definition.active_seconds,
		definition.recovery_seconds
	)
	presenter.refresh()
	t.assert_equal(presenter.current_animation(), &"hurt", "authoritative gameplay HURT outranks an event-only Attack presentation")
	actor.hurt.reset()
	layer.queue_free()
	await t.get_tree().process_frame
	await t.get_tree().process_frame

func _synthetic_profile() -> CharacterAnimationProfile:
	var result := CharacterAnimationProfile.new()
	result.sprite_frames = SpriteFrames.new()
	result.sprite_frames.remove_animation(&"default")
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.fill(Color.WHITE)
	var texture := ImageTexture.create_from_image(image)
	for animation in [
		&"idle", &"run", &"jump", &"fall", &"climb", &"climb_idle",
		&"dodge", &"hurt", &"death", &"attack_1", &"attack_2", &"attack_3",
	]:
		result.sprite_frames.add_animation(animation)
		var frame_count := 8 if String(animation).begins_with("attack_") else 4
		for frame in frame_count:
			result.sprite_frames.add_frame(animation, texture)
	result.attack_bindings = [
		_binding(&"attack_1", &"attack_1"),
		_binding(&"attack_2", &"attack_2"),
		_binding(&"attack_3", &"attack_3"),
	] as Array[AttackAnimationBinding]
	return result

func _binding(key: StringName, animation: StringName) -> AttackAnimationBinding:
	var result := AttackAnimationBinding.new()
	result.presentation_key = key
	result.animation_name = animation
	result.startup_end_frame = 2
	result.active_end_frame = 4
	return result

func _has_error(errors: PackedStringArray, text: String) -> bool:
	for error in errors:
		if error.contains(text):
			return true
	return false
