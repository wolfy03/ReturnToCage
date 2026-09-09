class_name LootEntitySnapshot
extends RefCounted

var entity_id: int
var position: Vector2
var stack: ItemStack
var error_message: String = ""

func to_payload() -> Dictionary:
	return {"entity_id": entity_id, "position": position, "stack": stack.to_dict()}

static func from_payload(payload: Dictionary, resolver: Callable = Callable(ContentRegistry, "get_item")) -> LootEntitySnapshot:
	var result := LootEntitySnapshot.new()
	if not payload.get("entity_id") is int or not payload.get("position") is Vector2 or not payload.get("stack") is Dictionary:
		result.error_message = "Malformed loot snapshot"
		return result
	result.entity_id = payload["entity_id"]
	result.position = payload["position"]
	result.stack = ItemStack.from_dict(payload["stack"])
	var definition := resolver.call(result.stack.item_id) as ItemDefinition if resolver.is_valid() else null
	var stack_error := StackValidation.runtime_error(result.stack, definition)
	if result.entity_id <= 0 or not result.position.is_finite() or not stack_error.is_empty():
		result.error_message = "Invalid loot snapshot: %s" % stack_error
	return result
