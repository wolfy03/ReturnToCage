class_name ItemStack
extends RefCounted

var item_id: StringName
var quantity: int
var instance_id: String = ""
var durability: int = -1

func _init(p_item_id: StringName = &"", p_quantity: int = 0) -> void:
	item_id = p_item_id
	quantity = maxi(0, p_quantity)

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
