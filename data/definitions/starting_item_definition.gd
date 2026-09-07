class_name StartingItemDefinition
extends Resource

@export var item_id: StringName
@export var instance_id: String = ""
@export_range(1, 9999, 1) var quantity: int = 1
## -1 preserves the existing unspecified durability representation.
@export_range(-1, 9999, 1) var durability: int = -1

func create_stack() -> ItemStack:
	var stack := ItemStack.new(item_id, quantity)
	stack.instance_id = instance_id
	stack.durability = durability
	return stack if StackValidation.basic_error(stack).is_empty() and durability >= -1 else null
