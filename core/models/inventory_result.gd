class_name InventoryResult
extends RefCounted

var requested: int = 0
var changed: int = 0
var remainder: int = 0
var success: bool = false
var message: String = ""

static func make(p_requested: int, p_changed: int, p_message: String = "") -> InventoryResult:
	var result := InventoryResult.new()
	result.requested = p_requested
	result.changed = p_changed
	result.remainder = maxi(0, p_requested - p_changed)
	result.success = result.remainder == 0
	result.message = p_message
	return result
