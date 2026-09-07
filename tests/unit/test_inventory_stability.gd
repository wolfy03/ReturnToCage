extends RefCounted

func run(t: Node) -> void:
	var resolver := Callable(ContentRegistry, "get_item")
	var inventory := InventoryModel.new(2, resolver)
	var unique: ItemStack = instance("one")
	var invalid: ItemStack = unique.duplicate_stack()
	invalid.quantity = 2
	t.assert_true(not inventory.add_stack(invalid).success, "instance quantity 2 rejected at add boundary")
	t.assert_true(inventory.stacks().is_empty(), "invalid instance add preserves inventory")
	t.assert_true(inventory.add_stack(unique).success, "one instance occupies one stack")
	t.assert_true(not inventory.add_stack(unique).success, "duplicate runtime instance rejected")
	t.assert_equal(inventory.stacks().size(), 1, "duplicate does not split or clone instance")
	var warnings: PackedStringArray = inventory.restore([unique.to_dict(), unique.to_dict(), invalid.to_dict()])
	t.assert_equal(inventory.stacks().size(), 1, "restore keeps first instance only")
	t.assert_equal(warnings.size(), 2, "duplicate and malformed quantity each have one warning")
	t.assert_equal(inventory.restore([unique.to_dict()]).size(), 0, "independent restore does not reuse seen IDs")
	var count: Array[int] = [0]
	inventory.changed.connect(func() -> void: count[0] += 1)
	inventory.restore([ItemStack.new(&"berry", 15).to_dict(), ItemStack.new(&"water_drop", 1).to_dict()])
	t.assert_equal(count[0], 1, "bulk restore emits once even with split and overflow")
	count[0] = 0
	inventory.initialize([unique])
	t.assert_equal(count[0], 1, "bulk initialize emits once")
	var before: Array[Dictionary] = inventory.to_array()
	t.assert_true(not inventory.initialize([unique, unique]).success, "initialize rejects duplicate identity")
	t.assert_equal(inventory.to_array(), before, "invalid initialize is atomic")
	t.assert_true(not inventory.exchange([instance("missing")], []).success, "exchange requires exact input instance")
	t.assert_equal(inventory.to_array(), before, "missing instance exchange rolls back")
	count[0] = 0
	t.assert_true(inventory.exchange([unique], [instance("two")]).success, "instance exchange succeeds")
	t.assert_equal(count[0], 1, "successful exchange emits once")
	t.assert_equal(inventory.stacks()[0].instance_id, "two", "exchange removes named identity")
	before = inventory.to_array()
	t.assert_true(not inventory.exchange([], [instance("two")]).success, "duplicate instance output rejected")
	t.assert_equal(inventory.to_array(), before, "duplicate output does not alter source")
	t.assert_true(not inventory.exchange([], [invalid]).success, "instance output cannot split")
	t.assert_true(not inventory.exchange([ItemStack.new(&"berry", 1), null], []).success, "malformed transaction result tolerates null input record")
	inventory.capacity = 1
	inventory.initialize([ItemStack.new(&"berry", 10)])
	before = inventory.to_array()
	t.assert_true(not inventory.exchange([ItemStack.new(&"berry", 11)], []).success, "insufficient input fails")
	t.assert_equal(inventory.to_array(), before, "insufficient input leaves all materials")
	t.assert_true(not inventory.exchange([ItemStack.new(&"berry", 1)], [ItemStack.new(&"water_drop", 1)]).success, "output slot shortage fails")
	t.assert_equal(inventory.to_array(), before, "output shortage rolls back input removal")
	t.assert_true(inventory.exchange([ItemStack.new(&"berry", 2)], [ItemStack.new(&"berry", 2)]).success, "same input/output at max stack succeeds")
	t.assert_equal(inventory.to_array(), before, "same item exchange conserves contents")
	t.assert_true(not inventory.exchange([], [ItemStack.new(&"berry", 1)]).success, "max stack and capacity boundary respected")
	t.assert_true(inventory.exchange([ItemStack.new(&"berry", 10)], [unique]).success, "instance output uses exactly one freed slot")
	var equipment := EquipmentModel.new(resolver)
	t.assert_true(equipment.equip(invalid) == invalid, "equipment rejects multi-quantity instance")
	t.assert_true(equipment.equip(unique) == null, "valid instance equipment equips")
	t.assert_true(equipment.equip(unique) == unique, "same equipped identity cannot be duplicated")
	var raw: Dictionary = unique.to_dict()
	raw["durability"] = -90
	warnings = equipment.restore({"0": raw})
	t.assert_equal(equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND).durability, 0, "negative durability clamps to broken")
	t.assert_equal(warnings.size(), 1, "durability correction has specific warning")
	raw["durability"] = 9999
	warnings = equipment.restore({"0": raw})
	t.assert_equal(equipment.equipped(EquipmentDefinition.EquipmentSlot.MAIN_HAND).durability, 60, "durability limited by equipment definition")
	raw["durability"] = -1
	t.assert_true(equipment.restore({"0": raw}).is_empty(), "legacy unspecified durability sentinel preserved")
	for malformed in [null, [], {}, {"item_id": "berry", "quantity": 0}, {"item_id": "berry", "quantity": 1.5}, {"item_id": "berry", "quantity": INF}, {"item_id": "berry", "quantity": 1, "instance_id": []}]:
		warnings = inventory.restore([malformed])
		t.assert_equal(warnings.size(), 1, "malformed stack reports one boundary warning")
		t.assert_true(inventory.stacks().is_empty(), "malformed stack is excluded")

func instance(id: String) -> ItemStack:
	var stack := ItemStack.new(&"twig_sword", 1)
	stack.instance_id = id
	stack.durability = 40
	return stack
