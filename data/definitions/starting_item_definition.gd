class_name StartingItemDefinition
extends Resource

@export var item_id: StringName
@export_range(1, 9999, 1) var quantity: int = 1
## -1 preserves the existing unspecified durability representation.
@export_range(-1, 9999, 1) var durability: int = -1

func create_stack() -> ItemStack:
	var stack := ItemStack.new(item_id, quantity)
	stack.durability = durability
	return stack
