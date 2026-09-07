class_name CommandResult
extends RefCounted

var success: bool = false
var message: String = ""
var remaining: Array[ItemStack] = []

static func make(ok: bool, reason: String = "", items: Array[ItemStack] = []) -> CommandResult:
	var result := CommandResult.new()
	result.success = ok
	result.message = reason
	for stack in items:
		if stack != null:
			result.remaining.append(stack.duplicate_stack())
	return result
