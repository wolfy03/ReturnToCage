class_name LootActor
extends InteractionTarget

enum ClaimState { AVAILABLE, CLAIMING, DESPAWNED }

# The golden angle spreads consecutive entity IDs around the cycle.
const FLOAT_PHASE_STEP := 2.399963229728653
const MAX_DISPLAY_SIZE := 32.0
const VISUAL_SCENE_PATH := "res://gameplay/actors/loot/loot_visual.tscn"
const DISPLAY_TEXTURE_PATHS := {
	ItemDisplayCategory.Kind.EQUIPMENT: "res://assets/item/temp_equipment_item_img.png",
	ItemDisplayCategory.Kind.CONSUMABLE: "res://assets/item/temp_usable_item_img.png",
	ItemDisplayCategory.Kind.OTHER: "res://assets/item/temp_etc_item_img.png",
	ItemDisplayCategory.Kind.QUEST: "res://assets/item/temp_quest_item_img.png",
}
static var _visual_scene: PackedScene
static var _display_textures: Dictionary[ItemDisplayCategory.Kind, Texture2D] = {}

var network_entity_id: int
var stack: ItemStack
var claim_state: ClaimState = ClaimState.AVAILABLE
var spawn_manager: LootSpawnManager
var dropped_from_inventory: bool = false

func configure(entity_id: int, p_stack: ItemStack, manager: LootSpawnManager) -> void:
	network_entity_id = entity_id
	stack = p_stack.duplicate_stack()
	spawn_manager = manager
	interaction_id = StringName("loot_%d" % entity_id)
	prompt = "Pick up %s x%d" % [stack.item_id, stack.quantity]
	interaction_priority = 8

func _ready() -> void:
	collision_layer = 8
	collision_mask = 0
	activated.connect(_on_activated)

	if spawn_manager != null and spawn_manager.authoritative_runtime:
		return
	if _visual_scene == null:
		_visual_scene = load(VISUAL_SCENE_PATH) as PackedScene
	var visual := _visual_scene.instantiate() as Sprite2D
	var definition := ContentRegistry.get_item(stack.item_id) if stack != null else null
	visual.texture = _texture_for(definition)
	add_child(visual)
	if visual.texture != null:
		var size := visual.texture.get_size()
		var inverse_display_scale := maxf(1.0, maxf(size.x, size.y) / MAX_DISPLAY_SIZE)
		visual.scale = Vector2.ONE / inverse_display_scale
		visual.set_instance_shader_parameter(&"inverse_display_scale", inverse_display_scale)
	visual.set_instance_shader_parameter(&"phase", fposmod(network_entity_id * FLOAT_PHASE_STEP, TAU))

static func _texture_for(definition: ItemDefinition) -> Texture2D:
	if definition != null and definition.icon != null:
		return definition.icon
	var category := ItemDisplayCategory.for_item(definition)
	if not _display_textures.has(category):
		_display_textures[category] = ResourceLoader.load(DISPLAY_TEXTURE_PATHS[category]) as Texture2D
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
