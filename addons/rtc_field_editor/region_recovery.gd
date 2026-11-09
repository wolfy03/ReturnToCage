@tool
extends RefCounted

const BASE := "res://.godot/rtc_field_sync"
const LOCK := BASE + "/region_publish_lock"
const JOURNAL := "region_pending.json"

static func safe_path(path: String) -> bool:
	if not path.begins_with("res://") or path != path.simplify_path() or path.contains("\\"):
		return false
	var parent := "res://"
	for part in path.trim_prefix("res://").split("/"):
		if part.is_empty() or part in [".", ".."] or part.contains(":"):
			return false
		var directory := DirAccess.open(parent)
		if directory == null or directory.is_link(part):
			return false
		parent = parent.path_join(part)
	return true

static func lock_state() -> String:
	if not DirAccess.dir_exists_absolute(BASE) and safe_path(BASE):
		return "none"
	if not DirAccess.dir_exists_absolute(LOCK):
		return "none" if not FileAccess.file_exists(LOCK) and safe_path(LOCK) else "unknown"
	var owner := LOCK.path_join("owner.json")
	if not safe_path(owner) or not FileAccess.file_exists(owner):
		return "unknown"
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(owner))
	if not value is Dictionary or not value.get("pid") is float or value.pid < 1 or value.pid > 2147483647 or value.pid != floorf(value.pid):
		return "unknown"
	return "active" if OS.is_process_running(int(value.pid)) else "stale"

static func acquire() -> bool:
	if not safe_path(BASE) or DirAccess.make_dir_recursive_absolute(BASE) != OK or not safe_path(LOCK) or DirAccess.make_dir_absolute(LOCK) != OK:
		return false
	if _write_text(LOCK.path_join("owner.json"), JSON.stringify({"pid": OS.get_process_id()})) != OK:
		DirAccess.remove_absolute(LOCK.path_join("owner.json"))
		DirAccess.remove_absolute(LOCK)
		return false
	return true

static func release() -> void:
	var owner := LOCK.path_join("owner.json")
	if not safe_path(owner):
		return
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(owner))
	if not value is Dictionary or value.get("pid") != OS.get_process_id():
		return
	DirAccess.remove_absolute(owner)
	DirAccess.remove_absolute(LOCK)

static func new_transaction() -> String:
	for attempt in 16:
		var directory := BASE.path_join("region_txn_%d_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec(), attempt])
		if DirAccess.make_dir_absolute(directory) == OK:
			return directory
	return ""

static func journal_paths() -> PackedStringArray:
	var results := PackedStringArray()
	var directory := DirAccess.open(BASE) if safe_path(BASE) else null
	if directory == null:
		return results
	for folder in directory.get_directories():
		if folder.begins_with("region_txn_") and not directory.is_link(folder):
			results.append(BASE.path_join(folder).path_join(JOURNAL))
	for filename in directory.get_files():
		if filename.ends_with(".region_pending.json"):
			results.append(BASE.path_join(filename))
	results.sort()
	return results

static func write_record(directory: String, record: Dictionary) -> Error:
	var pending := directory.path_join("record.tmp")
	var error := _write_text(pending, JSON.stringify(record))
	if error == OK:
		error = DirAccess.rename_absolute(pending, directory.path_join(JOURNAL))
	return error

static func inspect(path: String, destination_valid: Callable) -> Dictionary:
	var blocked := {"state": "invalid", "detail": "Missing or malformed recovery record.", "path": path}
	var directory := path.get_base_dir()
	if directory.get_base_dir() != BASE or not directory.get_file().begins_with("region_txn_") or path.get_file() != JOURNAL:
		blocked.detail = "Legacy or unrecognized recovery record. Review its files manually."
		return blocked
	if not safe_path(path) or not FileAccess.file_exists(path) or FileAccess.get_size(path) > 16384:
		return blocked
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return blocked
	var data: Dictionary = json.data
	for key in ["scene", "resource", "scene_sha256", "resource_sha256"]:
		if not data.get(key) is String:
			return blocked
	if data.scene == data.resource or not destination_valid.call(data.scene, "res://world/adventure", "tscn") or not destination_valid.call(data.resource, "res://data/content/regions", "tres"):
		return blocked
	var hashes := [data.scene_sha256, data.resource_sha256]
	for hash in hashes:
		if not hash.is_empty() and (hash.length() != 64 or not hash.is_valid_hex_number(false)):
			return blocked
	var final_paths: Array[String] = [data.scene, data.resource]
	var stages: Array[String] = [directory.path_join("scene.tscn"), directory.path_join("region.tres")]
	var present: Array[bool] = []
	var verified: Array[bool] = []
	var external := false
	var incomplete := false
	for index in 2:
		var target := final_paths[index]
		var stage := stages[index]
		if not safe_path(stage) or DirAccess.dir_exists_absolute(stage) or DirAccess.dir_exists_absolute(target):
			return blocked
		present.append(FileAccess.file_exists(target))
		verified.append(FileAccess.file_exists(stage) and not hashes[index].is_empty() and FileAccess.get_sha256(stage) == hashes[index])
		if present[index] and (hashes[index].is_empty() or FileAccess.get_sha256(target) != hashes[index]):
			external = true
		if FileAccess.file_exists(stage) and not verified[index]:
			incomplete = incomplete or hashes[index].is_empty()
			external = external or not hashes[index].is_empty()
	var state := "before"
	var detail := "Before publication. Remove verified staging files and record."
	if external:
		state = "external"
		detail = "A final or staged file differs from the recorded hash."
	elif present[1] and not present[0]:
		state = "invalid"
		detail = "Only the resource was published; manual review required."
	elif incomplete:
		state = "incomplete"
		detail = "A staging write was interrupted before its hash was recorded. Manual review required."
	elif present[0] and present[1]:
		state = "complete"
		detail = "Both published files match. Remove verified staging files and record only."
	elif present[0]:
		state = "partial" if verified[1] else "incomplete"
		detail = "Resume by publishing the verified staged RegionDefinition. The Scene stays intact." if verified[1] else "Scene exists but the verified staged RegionDefinition is unavailable."
	return {"state": state, "detail": detail, "path": path, "scene": data.scene, "resource": data.resource,
		"stages": stages, "verified": verified, "hashes": hashes}

static func cleanup(record: Dictionary) -> bool:
	var journal: String = record.path
	var directory := DirAccess.open(journal.get_base_dir())
	if directory == null or not directory.get_directories().is_empty():
		return false
	for filename in directory.get_files():
		if filename not in [JOURNAL, "scene.tscn", "region.tres"]:
			return false
	for index in 2:
		if record.verified[index]:
			var path: String = record.stages[index]
			if not safe_path(path) or FileAccess.get_sha256(path) != record.hashes[index] or DirAccess.remove_absolute(path) != OK:
				return false
	if not safe_path(journal) or DirAccess.remove_absolute(journal) != OK:
		return false
	DirAccess.remove_absolute(journal.get_base_dir())
	return true

static func _write_text(path: String, value: String) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(value)
	file.flush()
	return file.get_error()

static func claim(confirmed_stale: bool) -> bool:
	if lock_state() == "none":
		return acquire()
	if not confirmed_stale or lock_state() != "stale":
		return false
	# Rename the stale lock as a unit. A concurrent publisher must still win
	# the ordinary atomic directory creation before either can write files.
	var owner_hash := FileAccess.get_sha256(LOCK.path_join("owner.json"))
	if lock_state() != "stale" or owner_hash.is_empty():
		return false
	var quarantine := BASE.path_join("old_lock_%d_%d" % [OS.get_process_id(), Time.get_ticks_usec()])
	if DirAccess.rename_absolute(LOCK, quarantine) != OK:
		return false
	if FileAccess.get_sha256(quarantine.path_join("owner.json")) != owner_hash:
		if not DirAccess.dir_exists_absolute(LOCK):
			DirAccess.rename_absolute(quarantine, LOCK)
		return false
	DirAccess.remove_absolute(quarantine.path_join("owner.json"))
	DirAccess.remove_absolute(quarantine)
	return acquire()
