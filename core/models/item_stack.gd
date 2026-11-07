class_name ItemStack
extends RefCounted

var item_id: StringName
var quantity: int
var instance_id: String = ""
var durability: int = -1

func _init(p_item_id: StringName = &"", p_quantity: int = 0) -> void:
	item_id = p_item_id
	quantity = maxi(0, p_quantity)

static func new_instance_id(id: StringName) -> String:
	return "%s_%s" % [id, Crypto.new().generate_random_bytes(16).hex_encode()]

## Authoritative grants only. Legacy/moved records keep their identities;
## starter records are templates and issue a fresh copy for every owner.
static func issue_grant_instances(stacks: Array[ItemStack], resolver: Callable, starter_template: bool = false) -> Array[ItemStack]:
	var result: Array[ItemStack] = []
	for stack in stacks:
		var gear := resolver.call(stack.item_id) is EquipmentDefinition if resolver.is_valid() else false
		if gear and stack.instance_id.is_empty():
			for index in stack.quantity:
				var instance := stack.duplicate_stack()
				instance.quantity = 1
				instance.instance_id = new_instance_id(stack.item_id)
				result.append(instance)
		elif starter_template and not stack.instance_id.is_empty():
			var instance := stack.duplicate_stack()
			instance.instance_id = new_instance_id(stack.item_id)
			result.append(instance)
		else:
			result.append(stack)
	return result

func duplicate_stack() -> ItemStack:
	var copy := ItemStack.new(item_id, quantity)
	copy.instance_id = instance_id
	copy.durability = durability
	return copy

func to_dict() -> Dictionary:
	return {"item_id": String(item_id), "quantity": quantity, "instance_id": instance_id, "durability": durability}

static func from_dict(data: Dictionary) -> ItemStack:
	var stack := ItemStack.new(StringName(str(data.get("item_id", ""))), int(data.get("quantity", 0)))
	stack.instance_id = str(data.get("instance_id", ""))
	stack.durability = int(data.get("durability", -1))
	return stack
