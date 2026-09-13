class_name EnvironmentPresenter
extends Node2D
## Client-side background renderer for one visible world scene.
##
## Owned by the world scene (Settlement / AdventureRegion) and created only for
## the local visible presentation, never for ServerWorldRuntime instances. It
## turns an [EnvironmentDefinition] into a stack of [Parallax2D] nodes with
## [Sprite2D] children, plus a solid backdrop drawn in the definition's
## [member EnvironmentDefinition.fallback_color]. Nothing here is gameplay
## state and nothing is replicated.
##
## Loading is lazy: [method configure_from_path] only touches the resource
## (and therefore its textures) when called, so a scene that never calls it
## (server runtime mode) never loads background images.

## Reserved z-index ranges (CanvasItem z_index, relative to the world scene).
## Backdrop solid color.
const Z_BACKDROP := -1100
## Background layers use [Z_BACKGROUND_MIN, Z_BACKGROUND_MAX].
const Z_BACKGROUND_MIN := -1000
const Z_BACKGROUND_MAX := -100
## Gameplay actors, platforms and interaction visuals draw at 0.
const Z_GAMEPLAY := 0
## Reserved for a future foreground pass in front of actors (not used yet).
const Z_FOREGROUND_MIN := 100
const Z_FOREGROUND_MAX := 900

const DEFAULT_REFERENCE_SIZE := Vector2(1280, 720)
const DEFAULT_FALLBACK_COLOR := Color("162133")
const BACKDROP_MARGIN := 4.0

## Emitted after layers are (re)built. Carries null when only the fallback is shown.
signal environment_applied(definition: EnvironmentDefinition)

## Resource path this presenter was configured from (kept as a plain string).
var environment_path: String = ""
var definition: EnvironmentDefinition
## Tests may silence push_warning() while probing failure paths.
var report_warnings: bool = true
var last_warning: String = ""
## Reserved day/night input in [0, 1]; -1 while nothing has set it. A future
## authoritative time system feeds this; the presenter never advances it itself.
var time_normalized: float = -1.0

var _backdrop: Parallax2D
var _backdrop_shape: Polygon2D
var _layer_nodes: Array[Parallax2D] = []
var _layer_definitions: Array[BackgroundLayerDefinition] = []
var _fallback_color: Color = DEFAULT_FALLBACK_COLOR
var _pending_path: String = ""
var _load_coordinator: EnvironmentLoadCoordinator
var _load_request_id: int = 0

func _enter_tree() -> void:
	var viewport := get_viewport()
	if viewport != null and not viewport.size_changed.is_connected(relayout):
		viewport.size_changed.connect(relayout)
	relayout()

func _exit_tree() -> void:
	var viewport := get_viewport()
	if viewport != null and viewport.size_changed.is_connected(relayout):
		viewport.size_changed.disconnect(relayout)
	_detach_pending_load()

## A threaded request cannot be cancelled. Detach this presenter's callback;
## EnvironmentLoadCoordinator remains alive under SceneTree.root and collects
## the loader token after completion without blocking world removal.
func _detach_pending_load() -> void:
	if _load_coordinator != null and _load_request_id > 0:
		_load_coordinator.cancel(_load_request_id)
	_load_request_id = 0
	_pending_path = ""
	set_process(false)

## Loads the EnvironmentDefinition at [param path] and builds its layers.
## In blocking mode, returns whether an EnvironmentDefinition was applied. In
## threaded mode, true means the request was accepted; final success or failure
## is reported by environment_applied (null means fallback-only presentation).
##
## By default the resource (and its textures) is loaded on a background thread
## so world transitions do not stall on image decoding; the backdrop is shown
## immediately and [signal environment_applied] fires once layers exist
## ([method is_loading] reports the pending state). Pass [param blocking] to
## load synchronously. [param loading_fallback_color] is drawn immediately while
## the preset and its own fallback color are still loading.
func configure_from_path(
	path: String,
	blocking: bool = false,
	loading_fallback_color: Color = DEFAULT_FALLBACK_COLOR
) -> bool:
	_detach_pending_load()
	environment_path = path
	_fallback_color = loading_fallback_color
	if path.is_empty():
		_apply_fallback_only()
		return false
	if not ResourceLoader.exists(path):
		_warn("environment resource missing: %s" % path)
		_apply_fallback_only()
		return false
	if blocking:
		return _apply_loaded_resource(ResourceLoader.load(path), path)
	_pending_path = path
	clear_layers()
	_ensure_backdrop()
	relayout()
	# Root may still be setting up children while a world scene enters the tree.
	# Start the global request after the current tree mutation completes.
	_start_threaded_load.call_deferred(path)
	return true

func is_loading() -> bool:
	return not _pending_path.is_empty()

func _start_threaded_load(path: String) -> void:
	if path != _pending_path or not is_inside_tree():
		return
	_load_coordinator = EnvironmentLoadCoordinator.for_node(self)
	if _load_coordinator == null:
		_warn("environment load coordinator is unavailable: %s" % path)
		_pending_path = ""
		_apply_fallback_only()
		return
	_load_request_id = _load_coordinator.request(path, _on_threaded_load_finished)
	if _load_request_id <= 0:
		_warn("environment resource could not be requested: %s" % path)
		_pending_path = ""
		_apply_fallback_only()

func _on_threaded_load_finished(
	request_id: int,
	path: String,
	status: ResourceLoader.ThreadLoadStatus,
	resource: Resource
) -> void:
	if request_id != _load_request_id or path != _pending_path:
		return
	_load_request_id = 0
	_pending_path = ""
	if status != ResourceLoader.THREAD_LOAD_LOADED or resource == null:
		_warn("environment resource failed to load: %s" % path)
		_apply_fallback_only()
		return
	_apply_loaded_resource(resource, path)

func _apply_loaded_resource(resource: Resource, path: String) -> bool:
	if not resource is EnvironmentDefinition:
		_warn("environment resource is not an EnvironmentDefinition: %s" % path)
		_apply_fallback_only()
		return false
	return configure(resource)

## Builds layers from an in-memory definition. Existing layers are removed first.
func configure(p_definition: EnvironmentDefinition) -> bool:
	if p_definition == null:
		_apply_fallback_only()
		return false
	clear_layers()
	definition = p_definition
	_fallback_color = definition.fallback_color
	_ensure_backdrop()
	for layer in definition.layers:
		if layer == null:
			_warn("environment %s contains a null layer" % environment_path)
			continue
		if not layer.enabled:
			continue
		if not layer.has_content():
			_warn("environment layer %s has no texture" % layer.layer_name)
			continue
		_build_layer(layer)
	relayout()
	environment_applied.emit(definition)
	return true

## Removes every generated layer (the backdrop stays).
func clear_layers() -> void:
	for node in _layer_nodes:
		if is_instance_valid(node):
			remove_child(node)
			node.queue_free()
	_layer_nodes.clear()
	_layer_definitions.clear()
	definition = null

func layer_count() -> int:
	return _layer_nodes.size()

func get_layer_node(layer_name: StringName) -> Parallax2D:
	for index in _layer_definitions.size():
		if _layer_definitions[index].layer_name == layer_name:
			return _layer_nodes[index]
	return null

func fallback_color() -> Color:
	return _fallback_color

## Extension point for a future day/night system. The value is stored only; the
## presenter never runs its own clock so every client keeps identical visuals
## until an authoritative time source exists.
func set_time_normalized(value: float) -> void:
	if not is_finite(value):
		return
	time_normalized = clampf(value, 0.0, 1.0)
	_apply_time_of_day()

func _apply_time_of_day() -> void:
	# Intentionally empty for now. Planned: sky tint, star alpha, sun/moon
	# visibility and position driven by time_normalized and per-layer roles.
	pass

## Recomputes fit scale and sprite placement for the current viewport size.
func relayout() -> void:
	var viewport_size := _viewport_size()
	var reference := definition.reference_size if definition != null else DEFAULT_REFERENCE_SIZE
	if reference.x <= 0.0 or reference.y <= 0.0:
		reference = DEFAULT_REFERENCE_SIZE
	var layout_scale := viewport_size.y / reference.y
	var layout_offset := Vector2((viewport_size.x - reference.x * layout_scale) * 0.5, 0.0)
	_layout_backdrop(viewport_size)
	for index in _layer_nodes.size():
		_layout_layer(_layer_nodes[index], _layer_definitions[index], viewport_size, layout_scale, layout_offset)

func _viewport_size() -> Vector2:
	if is_inside_tree():
		var viewport := get_viewport()
		if viewport != null:
			var size := viewport.get_visible_rect().size
			if size.x > 0.0 and size.y > 0.0:
				return size
	var reference := definition.reference_size if definition != null else DEFAULT_REFERENCE_SIZE
	return reference if reference.x > 0.0 and reference.y > 0.0 else DEFAULT_REFERENCE_SIZE

func _apply_fallback_only() -> void:
	clear_layers()
	_ensure_backdrop()
	relayout()
	environment_applied.emit(null)

func _ensure_backdrop() -> void:
	if _backdrop == null or not is_instance_valid(_backdrop):
		_backdrop = Parallax2D.new()
		_backdrop.name = "Backdrop"
		_backdrop.scroll_scale = Vector2.ZERO
		_backdrop.z_index = Z_BACKDROP
		_backdrop_shape = Polygon2D.new()
		_backdrop_shape.name = "Color"
		_backdrop.add_child(_backdrop_shape)
		add_child(_backdrop)
		move_child(_backdrop, 0)
	_backdrop_shape.color = _fallback_color

func _layout_backdrop(viewport_size: Vector2) -> void:
	if _backdrop_shape == null:
		return
	var m := BACKDROP_MARGIN
	_backdrop_shape.polygon = PackedVector2Array([
		Vector2(-m, -m), Vector2(viewport_size.x + m, -m),
		Vector2(viewport_size.x + m, viewport_size.y + m), Vector2(-m, viewport_size.y + m),
	])

func _build_layer(layer: BackgroundLayerDefinition) -> void:
	var node := Parallax2D.new()
	var suffix := String(layer.layer_name) if not layer.layer_name.is_empty() else str(_layer_nodes.size())
	node.name = "Layer_%s" % suffix
	node.scroll_scale = layer.scroll_scale
	node.repeat_times = maxi(layer.repeat_times, 1)
	node.z_index = clampi(layer.z_index, Z_BACKGROUND_MIN, Z_BACKGROUND_MAX)
	if node.z_index != layer.z_index:
		_warn("environment layer %s z_index %d clamped into the background range" % [layer.layer_name, layer.z_index])
	node.modulate = layer.modulate
	if layer.texture != null:
		var sprite := Sprite2D.new()
		sprite.name = "Texture"
		sprite.texture = layer.texture
		node.add_child(sprite)
	for index in layer.sprites.size():
		var sprite_definition := layer.sprites[index]
		if sprite_definition == null or sprite_definition.texture == null:
			_warn("environment layer %s sprite %d has no texture" % [layer.layer_name, index])
			continue
		var sprite := Sprite2D.new()
		sprite.name = "Sprite%d" % index
		sprite.texture = sprite_definition.texture
		sprite.modulate = sprite_definition.modulate
		sprite.flip_h = sprite_definition.flip_h
		sprite.set_meta(&"sprite_definition", sprite_definition)
		node.add_child(sprite)
	add_child(node)
	_layer_nodes.append(node)
	_layer_definitions.append(layer)

func _layout_layer(
	node: Parallax2D,
	layer: BackgroundLayerDefinition,
	viewport_size: Vector2,
	layout_scale: float,
	layout_offset: Vector2
) -> void:
	node.autoscroll = layer.autoscroll * layout_scale
	node.repeat_size = layer.sanitized_repeat_size() * layout_scale
	for child in node.get_children():
		var sprite := child as Sprite2D
		if sprite == null or sprite.texture == null:
			continue
		if sprite.has_meta(&"sprite_definition"):
			var sprite_definition: BackgroundSpriteDefinition = sprite.get_meta(&"sprite_definition")
			sprite.position = sprite_definition.position * layout_scale + layout_offset
			sprite.scale = sprite_definition.scale * layout_scale
		else:
			var fit := _fit_scale(layer, sprite.texture.get_size(), viewport_size, layout_scale)
			sprite.scale = Vector2(fit, fit) * layer.scale
			sprite.position = viewport_size * 0.5 + layer.position_offset * layout_scale

func _fit_scale(layer: BackgroundLayerDefinition, texture_size: Vector2, viewport_size: Vector2, layout_scale: float) -> float:
	if texture_size.x <= 0.0 or texture_size.y <= 0.0:
		return layout_scale
	match layer.fit_mode:
		BackgroundLayerDefinition.FitMode.COVER:
			return maxf(viewport_size.x / texture_size.x, viewport_size.y / texture_size.y)
		BackgroundLayerDefinition.FitMode.FIT_WIDTH:
			return viewport_size.x / texture_size.x
		BackgroundLayerDefinition.FitMode.FIT_HEIGHT:
			return viewport_size.y / texture_size.y
	return layout_scale

func _warn(message: String) -> void:
	last_warning = message
	if report_warnings:
		push_warning("[Environment] %s" % message)
