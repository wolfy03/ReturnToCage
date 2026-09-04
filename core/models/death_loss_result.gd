class_name DeathLossResult
extends RefCounted

var kept: Array[ItemStack] = []
var lost: Array[ItemStack] = []
var world_drops: Array[ItemStack] = []
var equipment_kept: Array[ItemStack] = []
var equipment_lost: Array[ItemStack] = []

func lost_count(item_id: StringName) -> int:
	var total := 0
	for stack in lost:
		if stack.item_id == item_id:
			total += stack.quantity
	return total
