class_name LootActor
extends InteractionTarget

enum ClaimState { AVAILABLE, CLAIMING, DESPAWNED }

var network_entity_id: int
var stack: ItemStack
var claim_state: ClaimState = ClaimState.AVAILABLE
var spawn_manager: LootSpawnManager

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

func can_interact(_actor: Node) -> bool:
	return enabled and claim_state == ClaimState.AVAILABLE and stack != null

func request_local_pickup() -> void:
	if spawn_manager != null:
		spawn_manager.request_pickup(network_entity_id)

func _on_activated(actor: Node) -> void:
	if not NetworkManager.is_authoritative_simulation() or not actor is PlayerActor or spawn_manager == null:
		return
	spawn_manager.server_try_pickup((actor as PlayerActor).peer_id, network_entity_id)
