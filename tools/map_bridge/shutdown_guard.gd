extends Node
## Bridge-owned processes on official 4.7.2 need cached script bases to outlive
## GDScriptLanguage::finish(). That engine's iterator snapshots the next
## SelfList link before releasing its current script reference.
##
## ImageLoader::cleanup() follows ScriptServer::finish_languages() and precedes
## scene module deinitialization in ed1daf0bf. A native loader with no format
## implementation is a bounded reference owner in that interval. No script
## callback runs during its destruction, and the engine releases it normally.

static var _installed := false

static func retain_scripts() -> void:
	if _installed or OS.get_name() != "Windows":
		return
	var release := Engine.get_version_info()
	if release.get("hash") != "ed1daf0bf" and not String(release.get("hash", "")).begins_with("ed1daf0bf"):
		return
	_installed = true
	var scripts: Array[Script] = []
	for row in ProjectSettings.get_global_class_list():
		var script := ResourceLoader.get_cached_ref(row.path) as Script
		while script != null and not scripts.has(script):
			scripts.append(script)
			script = script.get_base_script()
	var owner := ImageFormatLoaderExtension.new()
	owner.set_meta(&"rtc_shutdown_script_refs", scripts)
	owner.add_format_loader()
	print("RTC_BRIDGE SHUTDOWN_REFS_RETAINED ", scripts.size())

func _exit_tree() -> void:
	retain_scripts()
