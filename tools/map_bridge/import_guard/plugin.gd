@tool
extends EditorPlugin

const ShutdownGuard := preload("res://tools/map_bridge/shutdown_guard.gd")

func _exit_tree() -> void:
	ShutdownGuard.retain_scripts()
	print("RTC_BRIDGE EDITOR_IMPORT_CLEANUP")
