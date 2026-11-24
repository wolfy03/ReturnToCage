extends RefCounted

const FRAME := 1.0 / 60.0

func run(t: Node) -> void:
	await _check_enemy(t, &"sewer_beetle", false)

func _check_enemy(t: Node, enemy_id: StringName, expects_airborne: bool) -> void:
	var label := String(enemy_id)
	var definition := ContentRegistry.get_definition(enemy_id) as EnemyDefinition
	t.assert_true(definition != null, label + " is registered")
	if definition == null:
		return
	var enemy := definition.actor_scene.instantiate() as EnemyAgent
	t.assert_true(not enemy.animation_profile_path.is_empty(), label + " scene names an animation profile")
	var profile := ResourceLoader.load(enemy.animation_profile_path) as EnemyAnimationProfile
	t.assert_true(profile != null and profile.validation_errors().is_empty(), label + " animation profile validates")
	if profile == null:
		enemy.free()
		return
	for animation in profile.required_animations():
		t.assert_true(profile.has_animation(animation), "%s has the %s clip" % [label, animation])
	for animation in profile.airborne_animations():
		t.assert_equal(profile.has_animation(animation), expects_airborne, "%s airborne clip presence: %s" % [label, animation])
	for animation in profile.sprite_frames.get_animation_names():
		var seen: Array[Rect2] = []
		for index in profile.sprite_frames.get_frame_count(animation):
			var atlas := profile.sprite_frames.get_frame_texture(animation, index) as AtlasTexture
			t.assert_true(atlas != null and not seen.has(atlas.region), "%s %s frame %d is its own sheet cell" % [label, animation, index])
			if atlas != null:
				seen.append(atlas.region)

	# The clips follow gameplay timing that the states own.
	var attack := enemy.get_node("States/Attack")
	var frame_seconds := 1.0 / profile.sprite_frames.get_animation_speed(profile.attack_animation)
	var strike := profile.frame_start_seconds(profile.attack_animation, profile.attack_hit_frame)
	t.assert_true(absf(strike - float(attack.call("hit_seconds"))) <= frame_seconds * 0.5 + 0.001, label + " strike frame starts when the attack state lands the hit")
	t.assert_true(profile.animation_seconds(profile.attack_animation) <= float(attack.get("duration_seconds")) + 0.001, label + " attack clip fits the attack state")
	t.assert_true(profile.animation_seconds(profile.death_animation) <= float(enemy.get_node("States/Dead").get("removal_seconds")) + 0.001, label + " death clip finishes before removal")

	enemy.setup_enemy(definition, 9101, true, &"")
	t.add_child(enemy)
	await t.get_tree().process_frame
	var presenter := enemy.animation_presenter
	t.assert_true(presenter != null and presenter.sprite != null, label + " builds a sprite presenter when presentation is enabled")
	if presenter == null:
		enemy.free()
		return
	t.assert_true(not (enemy.get_node("Visual") as CanvasItem).visible, label + " hides the placeholder polygon behind the sprite")
	enemy.set_physics_process(false)
	presenter.set_process(false)
	var body_shape := (enemy.get_node("CollisionShape2D") as CollisionShape2D).shape
	var body_scale := enemy.scale

	enemy.change_state(&"idle")
	enemy.velocity = Vector2.ZERO
	_tick(presenter, 4)
	t.assert_equal(presenter.current_animation, profile.idle_animation, label + " idles when still")
	if not expects_airborne:
		enemy.velocity = Vector2(40.0, 0.0)
		_tick(presenter, 1)
		t.assert_equal(presenter.current_animation, profile.move_animation, label + " plays move from real speed")
		var plays := presenter.play_count
		_tick(presenter, 30)
		t.assert_equal(presenter.play_count, plays, label + " does not restart a held clip every frame")
	enemy.facing = -1.0
	_tick(presenter, 1)
	t.assert_true(presenter.scale.x < 0.0 and enemy.scale == body_scale, label + " flips only the visual child")
	enemy.facing = 1.0
	_tick(presenter, 1)
	t.assert_true(presenter.scale.x > 0.0, label + " faces right again")

	if expects_airborne:
		enemy.velocity = Vector2.ZERO
		enemy.current_state_id = &"prepare"
		_tick(presenter, 1)
		t.assert_equal(presenter.current_animation, profile.jump_start_animation, label + " crouches while preparing a hop")
		enemy.current_state_id = &"chase"
		enemy.velocity = Vector2(120.0, -300.0)
		_tick(presenter, 1)
		t.assert_equal(presenter.current_animation, profile.jump_animation, label + " plays jump while rising")
		enemy.velocity = Vector2(120.0, 0.0)
		_tick(presenter, 2)
		t.assert_equal(presenter.current_animation, profile.jump_animation, label + " keeps the airborne clip through the apex")
		enemy.velocity = Vector2(120.0, 260.0)
		_tick(presenter, 1)
		t.assert_equal(presenter.current_animation, profile.fall_animation, label + " plays fall while descending")
		enemy.velocity = Vector2.ZERO
		_tick(presenter, 6)
		t.assert_equal(presenter.current_animation, profile.land_animation, label + " plays land on touchdown")
		_tick(presenter, 20)
		t.assert_equal(presenter.current_animation, profile.idle_animation, label + " returns to idle after landing")

	enemy.velocity = Vector2.ZERO
	enemy.current_state_id = &"attack"
	_tick(presenter, 1)
	t.assert_equal(presenter.current_animation, profile.attack_animation, label + " plays attack in the attack state")
	var attack_plays := presenter.play_count
	_tick(presenter, 20)
	t.assert_equal(presenter.play_count, attack_plays, label + " plays one attack clip per attack")
	enemy.current_state_id = &"chase"
	_tick(presenter, 1)
	t.assert_true(presenter.current_animation != profile.attack_animation, label + " leaves the attack clip after the attack")

	enemy.current_state_id = &"hurt"
	_tick(presenter, 1)
	t.assert_equal(presenter.current_animation, profile.hurt_animation, label + " plays hurt in the hurt state")
	var hurt_plays := presenter.play_count
	enemy.health.health_changed.emit(enemy.health.current_health - 1.0, enemy.health.max_health)
	t.assert_equal(presenter.play_count, hurt_plays + 1, label + " restarts hurt on a second hit")

	enemy.current_state_id = &"dead"
	_tick(presenter, 1)
	t.assert_equal(presenter.current_animation, profile.death_animation, label + " plays death when dead")
	var death_plays := presenter.play_count
	enemy.current_state_id = &"hurt"
	enemy.health.health_changed.emit(0.0, enemy.health.max_health)
	_tick(presenter, 10)
	t.assert_true(presenter.play_count == death_plays and presenter.current_animation == profile.death_animation, label + " never replays or replaces death")
	t.assert_true((enemy.get_node("CollisionShape2D") as CollisionShape2D).shape == body_shape, label + " presentation leaves the body shape alone")
	enemy.free()

	# A replicated actor draws from the mirrored snapshot state alone.
	var remote := definition.actor_scene.instantiate() as EnemyAgent
	remote.setup_enemy(definition, 9102, false, &"")
	t.add_child(remote)
	await t.get_tree().process_frame
	t.assert_true(remote.animation_presenter != null and not remote.is_physics_processing(), label + " replica has a presenter and no simulation")
	if remote.animation_presenter != null:
		remote.animation_presenter.set_process(false)
		var snapshot := EnemyRuntimeSnapshot.new()
		snapshot.entity_id = 9102
		snapshot.enemy_id = enemy_id
		snapshot.max_health = remote.health.max_health
		snapshot.health = remote.health.max_health
		snapshot.state = EnemyRuntimeSnapshot.State.ATTACKING
		remote.apply_runtime_presentation(snapshot)
		_tick(remote.animation_presenter, 1)
		t.assert_equal(remote.animation_presenter.current_animation, profile.attack_animation, label + " replica shows the replicated attack")
		snapshot.state = EnemyRuntimeSnapshot.State.DEAD
		remote.apply_runtime_presentation(snapshot)
		_tick(remote.animation_presenter, 1)
		t.assert_equal(remote.animation_presenter.current_animation, profile.death_animation, label + " replica shows the replicated death")
	remote.free()

	# The server runtime copy never builds visuals.
	var server := definition.actor_scene.instantiate() as EnemyAgent
	server.setup_enemy(definition, 9103, true, &"", false)
	t.add_child(server)
	await t.get_tree().process_frame
	t.assert_true(server.animation_presenter == null and server.get_node_or_null("AnimationPresenter") == null, label + " server runtime actor has no presenter")
	server.free()

func _tick(presenter: EnemyAnimationPresenter, frames: int) -> void:
	for index in frames:
		presenter._process(FRAME)
