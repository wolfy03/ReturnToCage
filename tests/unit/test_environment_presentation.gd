extends RefCounted
## Background environment system: presentation-only resources, the presenter's
## failure tolerance, and the client-vs-server-runtime boundary.

const SETTLEMENT_PRESET := "res://world/environment/presets/settlement_environment.tres"
const SEWER_PRESET := "res://world/environment/presets/sewer_environment.tres"
const SETTLEMENT_SCENE := "res://world/settlement/settlement.tscn"
const SEWER_SCENE := "res://world/adventure/sewer_region.tscn"
const SEWER_WORLD: StringName = &"adventure:sewer_region"

func run(t: Node) -> void:
	_test_resources(t)
	await _test_presenter_layers_and_layout(t)
	await _test_aspect_ratio_layout(t)
	await _test_presenter_failure_paths(t)
	await _test_pending_load_handoff(t)
	await _test_real_presets(t)
	_test_region_definition_environment_path(t)
	await _test_settlement_presentation_boundary(t)
	await _test_adventure_presentation_boundary(t)
	await _test_server_world_runtime_has_no_environment(t)

func _texture(width: int, height: int) -> ImageTexture:
	return ImageTexture.create_from_image(Image.create_empty(width, height, false, Image.FORMAT_RGBA8))

func _layer(name: StringName, texture: Texture2D, z: int = -900) -> BackgroundLayerDefinition:
	var layer := BackgroundLayerDefinition.new()
	layer.layer_name = name
	layer.texture = texture
	layer.z_index = z
	return layer

func _test_resources(t: Node) -> void:
	var environment := EnvironmentDefinition.new()
	environment.fallback_color = Color.RED
	var sky := _layer(&"sky", _texture(8, 4), -1000)
	var disabled := _layer(&"disabled", _texture(2, 2))
	disabled.enabled = false
	var empty := _layer(&"empty", null)
	var band := BackgroundLayerDefinition.new()
	band.layer_name = &"band"
	var sprite := BackgroundSpriteDefinition.new()
	sprite.texture = _texture(4, 4)
	band.sprites.append(sprite)
	band.repeat_size = Vector2(-10, INF)
	environment.layers = [sky, disabled, empty, band]
	var script: Script = environment.get_script()
	t.assert_true(script.get_base_script() == null and script.get_instance_base_type() == &"Resource", "EnvironmentDefinition is a plain presentation Resource, not gameplay content")
	t.assert_equal(environment.layers.size(), 4, "environment stores several layers")
	t.assert_equal(environment.active_layers().size(), 2, "disabled and textureless layers are not active")
	t.assert_true(environment.find_layer(&"band") == band and environment.find_layer(&"nope") == null, "layers are found by name")
	t.assert_true(sky.has_content() and band.has_content() and not empty.has_content(), "layer content detection covers texture and placed sprites")
	t.assert_equal(band.sanitized_repeat_size(), Vector2.ZERO, "invalid repeat sizes are sanitized to zero")

func _test_presenter_layers_and_layout(t: Node) -> void:
	var presenter := EnvironmentPresenter.new()
	t.add_child(presenter)
	var viewport_size: Vector2 = t.get_viewport().get_visible_rect().size
	var environment := EnvironmentDefinition.new()
	environment.fallback_color = Color("336699")
	environment.reference_size = Vector2(1280, 720)
	var sky := _layer(&"sky", _texture(384, 216), -1000)
	sky.fit_mode = BackgroundLayerDefinition.FitMode.COVER
	var clouds := BackgroundLayerDefinition.new()
	clouds.layer_name = &"clouds"
	clouds.scroll_scale = Vector2(0.1, 0.05)
	clouds.autoscroll = Vector2(-10, 0)
	clouds.repeat_size = Vector2(2560, 0)
	clouds.z_index = 500 # outside the background range on purpose
	var cloud := BackgroundSpriteDefinition.new()
	cloud.texture = _texture(16, 8)
	cloud.position = Vector2(640, 100)
	cloud.scale = Vector2(0.5, 0.5)
	clouds.sprites.append(cloud)
	var moon := _layer(&"moon", _texture(4, 4))
	moon.enabled = false
	environment.layers = [sky, clouds, moon]
	presenter.report_warnings = false
	t.assert_true(presenter.configure(environment), "presenter builds an in-memory environment")
	t.assert_equal(presenter.layer_count(), 2, "presenter instantiates only enabled layers with content")
	t.assert_true(presenter.get_layer_node(&"moon") == null, "disabled layer produces no node")
	t.assert_true(presenter.get_node_or_null("Backdrop") is Parallax2D, "presenter owns a backdrop instead of a global clear color")
	t.assert_equal(presenter.fallback_color(), Color("336699"), "backdrop uses the environment fallback color")

	var sky_node := presenter.get_layer_node(&"sky")
	t.assert_true(sky_node is Parallax2D and sky_node.scroll_scale == Vector2.ZERO and sky_node.z_index == -1000, "sky layer becomes a fixed Parallax2D at its z-index")
	var sky_sprite := sky_node.get_node("Texture") as Sprite2D
	var expected_cover := maxf(viewport_size.x / 384.0, viewport_size.y / 216.0)
	t.assert_true(is_equal_approx(sky_sprite.scale.x, expected_cover) and is_equal_approx(sky_sprite.scale.y, expected_cover), "cover fit keeps aspect ratio while filling the viewport")
	t.assert_true(sky_sprite.position.is_equal_approx(viewport_size * 0.5), "cover-fit sprite is centered on the viewport")

	var cloud_node := presenter.get_layer_node(&"clouds")
	var layout_scale := viewport_size.y / 720.0
	t.assert_true(cloud_node.scroll_scale == Vector2(0.1, 0.05), "parallax depth comes from the layer definition")
	t.assert_true(cloud_node.autoscroll.is_equal_approx(Vector2(-10, 0) * layout_scale), "autoscroll is applied through Parallax2D")
	t.assert_true(cloud_node.repeat_size.is_equal_approx(Vector2(2560, 0) * layout_scale), "repeat size is applied through Parallax2D")
	t.assert_equal(cloud_node.z_index, EnvironmentPresenter.Z_BACKGROUND_MAX, "layer z-index is clamped below gameplay")
	var cloud_sprite := cloud_node.get_node("Sprite0") as Sprite2D
	t.assert_true(cloud_sprite.scale.is_equal_approx(Vector2(0.5, 0.5) * layout_scale), "placed sprite scale follows the layout scale")
	t.assert_true(is_equal_approx(cloud_sprite.position.y, 100.0 * layout_scale), "placed sprite position follows the layout scale")
	t.assert_true(cloud_node.get_children().all(func(child: Node) -> bool: return not child is CollisionObject2D), "background layers carry no collision")

	presenter.set_time_normalized(1.7)
	t.assert_equal(presenter.time_normalized, 1.0, "day/night input is clamped and stored without a local clock")
	t.assert_true(presenter.configure(environment), "presenter can be reconfigured")
	t.assert_equal(presenter.layer_count(), 2, "reconfiguring replaces layers instead of duplicating them")
	presenter.queue_free()
	await t.get_tree().process_frame

func _test_aspect_ratio_layout(t: Node) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1024, 768)
	t.add_child(viewport)
	var presenter := EnvironmentPresenter.new()
	viewport.add_child(presenter)
	var environment := EnvironmentDefinition.new()
	environment.reference_size = Vector2(1280, 720)
	var sky := _layer(&"sky", _texture(384, 216), -1000)
	sky.fit_mode = BackgroundLayerDefinition.FitMode.COVER
	environment.layers = [sky]
	t.assert_true(presenter.configure(environment), "aspect-ratio probe environment configures")
	for size: Vector2i in [Vector2i(1024, 768), Vector2i(1440, 900), Vector2i(2560, 1080)]:
		viewport.size = size
		presenter.relayout()
		var sprite := presenter.get_layer_node(&"sky").get_node("Texture") as Sprite2D
		var covered := sprite.texture.get_size() * sprite.scale
		t.assert_true(
			covered.x >= size.x - 0.5 and covered.y >= size.y - 0.5,
			"cover fit fills non-16:9 viewport %s" % size
		)
		var backdrop := presenter.get_node("Backdrop/Color") as Polygon2D
		var bounds := Rect2(backdrop.polygon[0], Vector2.ZERO)
		for point in backdrop.polygon:
			bounds = bounds.expand(point)
		t.assert_true(
			bounds.position.x <= 0.0 and bounds.position.y <= 0.0 \
				and bounds.end.x >= size.x and bounds.end.y >= size.y,
			"fallback backdrop fills non-16:9 viewport %s" % size
		)
	viewport.queue_free()
	await t.get_tree().process_frame

func _test_presenter_failure_paths(t: Node) -> void:
	var presenter := EnvironmentPresenter.new()
	presenter.report_warnings = false
	t.add_child(presenter)
	t.assert_true(not presenter.configure_from_path("", true), "empty environment path falls back without error")
	t.assert_equal(presenter.layer_count(), 0, "empty path shows only the backdrop")
	t.assert_true(presenter.get_node_or_null("Backdrop") != null, "backdrop exists even without an environment")
	t.assert_true(not presenter.configure_from_path("res://world/environment/presets/does_not_exist.tres", true), "missing environment resource fails safely")
	t.assert_true(presenter.last_warning.contains("missing"), "missing resource is reported as a warning")
	t.assert_true(not presenter.configure_from_path("res://data/content/regions/sewer_region.tres", true), "wrong resource type fails safely")
	t.assert_true(presenter.last_warning.contains("not an EnvironmentDefinition"), "wrong type is reported as a warning")
	t.assert_true(not presenter.configure(null), "null definition falls back")
	var empty := EnvironmentDefinition.new()
	t.assert_true(presenter.configure(empty), "empty environment (no layers) is accepted")
	t.assert_equal(presenter.layer_count(), 0, "empty environment builds no layers")
	var broken := EnvironmentDefinition.new()
	broken.layers = [null, _layer(&"blank", null)]
	t.assert_true(presenter.configure(broken) and presenter.layer_count() == 0, "null and textureless layers are skipped without crashing")
	presenter.relayout()
	presenter.queue_free()
	await t.get_tree().process_frame

func _test_pending_load_handoff(t: Node) -> void:
	var presenter := EnvironmentPresenter.new()
	t.add_child(presenter)
	t.assert_true(presenter.configure_from_path(SETTLEMENT_PRESET), "threaded environment request starts")
	# Start explicitly before the next frame so the coordinator owns the request
	# while this test removes the world node immediately.
	presenter._start_threaded_load(SETTLEMENT_PRESET)
	var coordinator := t.get_tree().root.get_node_or_null("EnvironmentLoadCoordinator") as EnvironmentLoadCoordinator
	t.assert_true(coordinator != null and coordinator.pending_path_count() == 1, "persistent coordinator owns the threaded loader token")
	t.remove_child(presenter)
	t.assert_true(not presenter.is_loading(), "removed presenter detaches its pending callback")
	t.assert_true(coordinator.pending_path_count() == 1, "world removal does not synchronously collect the pending load")
	presenter.free()
	for frame in 300:
		if coordinator.pending_path_count() == 0:
			break
		await t.get_tree().process_frame
	t.assert_equal(coordinator.pending_path_count(), 0, "coordinator eventually collects an abandoned loader token")

func _test_real_presets(t: Node) -> void:
	var presenter := EnvironmentPresenter.new()
	t.add_child(presenter)
	t.assert_true(presenter.configure_from_path(SETTLEMENT_PRESET, true), "settlement preset loads")
	t.assert_true(presenter.layer_count() >= 3, "settlement preset builds sky and cloud layers")
	t.assert_true(presenter.get_layer_node(&"sky") != null and presenter.get_layer_node(&"clouds_far") != null and presenter.get_layer_node(&"clouds_near") != null, "settlement preset uses the real sky and cloud atlases")
	var far := presenter.get_layer_node(&"clouds_far")
	var near := presenter.get_layer_node(&"clouds_near")
	t.assert_true(far.scroll_scale.x < near.scroll_scale.x and far.autoscroll.x != 0.0 and near.autoscroll.x != 0.0, "near clouds move faster than far clouds")
	t.assert_true(far.repeat_size.x > 0.0 and near.repeat_size.x > 0.0, "cloud bands repeat horizontally")
	t.assert_true(far.z_index < near.z_index and near.z_index < EnvironmentPresenter.Z_GAMEPLAY, "cloud layers stay behind gameplay in depth order")
	var viewport_size: Vector2 = t.get_viewport().get_visible_rect().size
	var sky_sprite := presenter.get_layer_node(&"sky").get_node("Texture") as Sprite2D
	var covered := sky_sprite.texture.get_size() * sky_sprite.scale
	t.assert_true(covered.x >= viewport_size.x - 0.5 and covered.y >= viewport_size.y - 0.5, "3840x2160 sky covers the viewport")
	t.assert_true(presenter.configure_from_path(SEWER_PRESET, true), "sewer preset loads")
	t.assert_equal(presenter.layer_count(), 0, "sewer preset has no outdoor layers yet")
	t.assert_equal(presenter.fallback_color(), Color("091a24"), "sewer preset keeps the dark backdrop")
	var loading_color := Color("5a2748")
	t.assert_true(presenter.configure_from_path(SETTLEMENT_PRESET, false, loading_color), "threaded preset load is accepted")
	t.assert_equal(presenter.fallback_color(), loading_color, "caller-provided fallback is drawn before the threaded preset applies")
	t.assert_true(presenter.is_loading() or presenter.layer_count() > 0, "threaded load reports pending state until layers exist")
	if presenter.is_loading():
		await presenter.environment_applied
	t.assert_true(not presenter.is_loading() and presenter.layer_count() >= 3 and presenter.environment_path == SETTLEMENT_PRESET, "threaded preset load builds the same layers without blocking the caller")
	presenter.queue_free()
	await t.get_tree().process_frame

func _test_region_definition_environment_path(t: Node) -> void:
	var region := (ContentRegistry.get_definition(&"sewer_region") as RegionDefinition)
	t.assert_equal(region.environment_path, SEWER_PRESET, "sewer region selects its environment by path")
	t.assert_true(ResourceLoader.exists(region.environment_path), "region environment path exists")
	var copy := region.duplicate() as RegionDefinition
	copy.environment_path = "res://world/environment/presets/missing.tres"
	var errors := copy.validate_definition(ContentRegistry)
	t.assert_true(errors.size() == 1 and errors[0].contains("environment missing"), "region validation reports a missing environment preset")
	copy.environment_path = ""
	t.assert_true(copy.validate_definition(ContentRegistry).is_empty(), "empty region environment path is valid")
	copy.environment_path = "res://data/content/regions/sewer_region.tres"
	errors = copy.validate_definition(ContentRegistry)
	t.assert_true(errors.size() == 1 and errors[0].contains("must be EnvironmentDefinition"), "region validation rejects an existing resource of the wrong type without loading it")

func _test_settlement_presentation_boundary(t: Node) -> void:
	GameSession.start_new_game()
	var packed := load(SETTLEMENT_SCENE) as PackedScene
	var visible: Variant = packed.instantiate()
	t.add_child(visible)
	var presenter := visible.get_node_or_null("EnvironmentPresenter") as EnvironmentPresenter
	t.assert_true(presenter != null, "visible Settlement creates an EnvironmentPresenter")
	if presenter.is_loading():
		await presenter.environment_applied
	t.assert_true(presenter.layer_count() > 0, "visible Settlement presenter builds layers once its preset is loaded")
	t.assert_equal(presenter.environment_path, visible.environment_path, "Settlement presenter uses the scene environment path")
	visible.queue_free()
	await t.get_tree().process_frame

	var server: Variant = packed.instantiate()
	server.configure_server_runtime(&"settlement")
	t.add_child(server)
	t.assert_true(server.get_node_or_null("EnvironmentPresenter") == null, "server runtime Settlement creates no EnvironmentPresenter")
	t.assert_true(server.environment_presenter == null, "server runtime Settlement keeps no presenter reference")
	server.queue_free()
	await t.get_tree().process_frame

func _test_adventure_presentation_boundary(t: Node) -> void:
	GameSession.start_new_game()
	var packed := load(SEWER_SCENE) as PackedScene
	var visible: Variant = packed.instantiate()
	visible.configure(AdventureContext.new(&"sewer_region", &"sewer_gate", &"sewer_entrance", GameSession.difficulty.id, GameSession.session_id))
	t.add_child(visible)
	var presenter := visible.get_node_or_null("EnvironmentPresenter") as EnvironmentPresenter
	t.assert_true(presenter != null, "visible Adventure region creates an EnvironmentPresenter")
	if presenter.is_loading():
		await presenter.environment_applied
	t.assert_equal(presenter.environment_path, SEWER_PRESET, "Adventure environment comes from the region definition of the context")
	t.assert_equal(presenter.fallback_color(), Color("091a24"), "Adventure presenter applies the region preset")
	visible.queue_free()
	await t.get_tree().process_frame

	var server: Variant = packed.instantiate()
	server.configure_server_runtime(SEWER_WORLD, &"sewer_region")
	t.add_child(server)
	t.assert_true(server.get_node_or_null("EnvironmentPresenter") == null, "server runtime Adventure region creates no EnvironmentPresenter")
	server.queue_free()
	await t.get_tree().process_frame

func _test_server_world_runtime_has_no_environment(t: Node) -> void:
	GameSession.start_new_game()
	var runtime := ServerWorldRuntime.new()
	var model := WorldRuntime.new(PlayerWorldState.SETTLEMENT_WORLD_ID, PlayerWorldState.WorldKind.SETTLEMENT)
	t.assert_true(runtime.configure(model, SETTLEMENT_SCENE), "server world runtime configures the Settlement scene")
	t.add_child(runtime)
	await t.get_tree().process_frame
	t.assert_true(bool(runtime.runtime_scene.get("server_runtime_mode")), "server world runtime scene runs in server mode")
	t.assert_true(runtime.runtime_scene.get_node_or_null("EnvironmentPresenter") == null, "ServerWorldRuntime scene never instantiates background presentation")
	t.assert_true(runtime.runtime_scene.find_children("*", "Parallax2D", true, false).is_empty(), "ServerWorldRuntime scene contains no Parallax2D layers")
	runtime.queue_free()
	await t.get_tree().process_frame
