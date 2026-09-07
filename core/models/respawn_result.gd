class_name RespawnResult
extends RefCounted

var success: bool = true
var error_message: String = ""

var inventory_lost: Array[ItemStack] = []
var inventory_kept: Array[ItemStack] = []
var equipment_lost: Array[ItemStack] = []
var equipment_damaged: Array[ItemStack] = []
var drops: Array[DeathDropRecord] = []
var health: float
var hunger: float
var thirst: float
var position: Vector2
var in_adventure: bool = false

func summary() -> String:
	if not success:
		return error_message
	return "Respawn HP %.0f | Lost: %s | Kept: %s | Gear lost: %s | Gear damaged: %s | Death drops: %d" % [health, _items(inventory_lost), _items(inventory_kept), _items(equipment_lost), _items(equipment_damaged), drops.size()]

func _items(stacks: Array[ItemStack]) -> String:
	var parts: Array[String] = []
	for stack in stacks:
		parts.append("%s x%d" % [stack.item_id, stack.quantity])
	return ", ".join(parts) if not parts.is_empty() else "none"

static func failure(message: String) -> RespawnResult:
	var result := RespawnResult.new()
	result.success = false
	result.error_message = message
	return result
