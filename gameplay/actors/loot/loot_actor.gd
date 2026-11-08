class_name LootActor
extends InteractionTarget

enum ClaimState { AVAILABLE, CLAIMING, DESPAWNED }

# The golden angle spreads consecutive entity IDs around the cycle.
const FLOAT_PHASE_STEP := 2.399963229728653
const MAX_DISPLAY_SIZE := 32.0
const THROW_DURATION := 0.6
const THROW_ARC_HEIGHT := 36.0
const FLOAT_BLEND_DURATION := 0.12
const VISUAL_SCENE_PATH := "res://gameplay/actors/loot/loot_visual.tscn"
const DISPLAY_TEXTURE_PATHS := {
	ItemDisplayCategory.Kind.EQUIPMENT: "res://assets/item/temp_equipment_item_img.png",
	ItemDisplayCategory.Kind.CONSUMABLE: "res://assets/item/temp_usable_item_img.png",
	ItemDisplayCategory.Kind.OTHER: "res://assets/item/temp_etc_item_img.png",
	ItemDisplayCategory.Kind.QUEST: "res://assets/item/temp_quest_item_img.png",
}
static var _visual_scene: PackedScene
static var _visual_scene_load_attempted := false
static var _display_textures: Dictionary[ItemDisplayCategory.Kind, Texture2D] = {}

var network_entity_id: int
var stack: ItemStack
var claim_state: ClaimState = ClaimState.AVAILABLE
var spawn_manager: LootSpawnManager
var dropped_from_inventory: bool = false
var _throw_origin := Vector2.INF
var _throw_tween: Tween

func configure(
	entity_id: int, p_stack: ItemStack, manager: LootSpawnManager,
	throw_origin: Vector2 = Vector2.INF
) -> void:
	network_entity_id = entity_id
	stack = p_stack.duplicate_stack()
	spawn_manager = manager
	_throw_origin = throw_origin
	interaction_id = StringName("loot_%d" % entity_id)
	prompt = "Pick up %s x%d" % [stack.item_id, stack.quantity]
	interaction_priority = 8

func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	activated.connect(_on_activated)

	if spawn_manager != null and spawn_manager.authoritative_runtime:
		return
	if not _visual_scene_load_attempted:
		_visual_scene_load_attempted = true
		_visual_scene = ResourceLoader.load(VISUAL_SCENE_PATH) as PackedScene
		if _visual_scene == null:
			push_error("Cannot load loot visual scene: %s" % VISUAL_SCENE_PATH)
	if _visual_scene == null:
		return
	var visual_node := _visual_scene.instantiate() if _visual_scene.can_instantiate() else null
	var visual := visual_node as Sprite2D
	if visual == null:
		if visual_node != null:
			visual_node.free()
		_visual_scene = null
		push_error("Cannot instantiate loot Sprite2D from: %s" % VISUAL_SCENE_PATH)
		return
	var definition := ContentRegistry.get_item(stack.item_id) if stack != null else null
	visual.texture = _texture_for(definition)
	add_child(visual)
	if visual.texture != null:
		var size := visual.texture.get_size()
		var inverse_display_scale := maxf(1.0, maxf(size.x, size.y) / MAX_DISPLAY_SIZE)
		visual.scale = Vector2.ONE / inverse_display_scale
		visual.set_instance_shader_parameter(&"inverse_display_scale", inverse_display_scale)
	visual.set_instance_shader_parameter(&"phase", fposmod(network_entity_id * FLOAT_PHASE_STEP, TAU))
	if _throw_origin.is_finite() and visual.texture != null:
		_play_throw(visual)

func _play_throw(visual: Sprite2D) -> void:
	var landing := visual.position
	var origin := to_local(_throw_origin)
	visual.position = origin
	visual.set_instance_shader_parameter(&"float_weight", 0.0)
	_throw_tween = visual.create_tween()
	_throw_tween.tween_method(_update_throw.bind(visual, origin, landing), 0.0, 1.0, THROW_DURATION)
	# The settled shader phase can have a nonzero offset. Blend it in at landing.
	_throw_tween.tween_method(func(weight: float) -> void:
		visual.set_instance_shader_parameter(&"float_weight", weight)
	, 0.0, 1.0, FLOAT_BLEND_DURATION)
	_throw_tween.finished.connect(func() -> void: _throw_tween = null, CONNECT_ONE_SHOT)

func _update_throw(progress: float, visual: Sprite2D, origin: Vector2, landing: Vector2) -> void:
	visual.position = origin.lerp(landing, progress) + Vector2.UP * (4.0 * THROW_ARC_HEIGHT * progress * (1.0 - progress))
	visual.rotation = TAU * progress

func detach_pickup_visual() -> Sprite2D:
	var visual := get_node_or_null("Visual") as Sprite2D
	if visual == null or visual.texture == null:
		return null
	if _throw_tween != null:
		_throw_tween.kill()
		_throw_tween = null
	visual.name = "LootPickup_%d" % network_entity_id
	visual.reparent(get_parent())
	return visual

static func _texture_for(definition: ItemDefinition) -> Texture2D:
	if definition != null and definition.icon != null:
		return definition.icon
	var category := ItemDisplayCategory.for_item(definition)
	if not _display_textures.has(category):
		var path: String = DISPLAY_TEXTURE_PATHS[category]
		var texture := ResourceLoader.load(path) as Texture2D
		# Cache null too, so a missing texture is reported only once.
		_display_textures[category] = texture
		if texture == null:
			push_error("Cannot load loot fallback texture: %s" % path)
	return _display_textures[category]

func can_interact(_actor: Node) -> bool:
	return enabled and claim_state == ClaimState.AVAILABLE and stack != null

func request_local_pickup() -> void:
	if spawn_manager != null:
		spawn_manager.request_pickup(network_entity_id)

func _on_activated(actor: Node) -> void:
	if not NetworkManager.is_authoritative_simulation() or not actor is PlayerActor or spawn_manager == null:
		return
	spawn_manager.server_try_pickup((actor as PlayerActor).peer_id, network_entity_id)
