extends RefCounted

const EDIT_ID := &"rtc_map_object_id"
const PLATFORM_SCRIPT := preload("res://world/adventure/field_platform.gd")
const PLATFORM := preload("res://world/adventure/field_platform.tscn")
const DECORATION := preload("res://world/adventure/field_decoration.gd")
const MIN_SIZE := 4.0
const MAX_SIZE := 1000000.0

static func uid(path: String) -> String:
	var number := ResourceLoader.get_resource_uid(path)
	return "" if number == ResourceUID.INVALID_ID else ResourceUID.id_to_text(number)

static func vector(value: Vector2) -> Array:
	return [value.x, value.y]

static func affine(value: Transform2D) -> Array:
	return [value.x.x, value.x.y, value.y.x, value.y.y, value.origin.x, value.origin.y]

static func is_orthogonal(value: Transform2D) -> bool:
	return value.is_finite() and value.determinant() > 0.00001 and absf(value.x.normalized().dot(value.y.normalized())) < 0.0001

static func identity(root: Node, node: Node, region_id: String) -> String:
	var authored := String(node.get_meta(EDIT_ID, ""))
	if not authored.is_empty():
		return authored
	var path := String(root.get_path_to(node))
	var script: Script = node.get_script()
	var discriminator := script.resource_path if script != null else node.get_class()
	return "godot_" + ("%s|%s|%s" % [region_id, path, discriminator]).sha256_text().substr(0, 40)

static func polygon_is_rectangle(points: PackedVector2Array, size: Vector2) -> bool:
	if points.size() != 4:
		return false
	var corners := [size * -0.5, size * Vector2(0.5, -0.5), size * 0.5, size * Vector2(-0.5, 0.5)]
	for sample in points:
		var index := corners.find_custom(func(corner: Vector2) -> bool: return corner.is_equal_approx(sample))
		if index < 0:
			return false
		corners.remove_at(index)
	return true

static func classify(node: Node, root: Node) -> Dictionary:
	if not node is FieldDecoration and not node is StaticBody2D:
		return {}
	var transform: Transform2D = node.global_transform
	var parent := node.get_parent() as Node2D
	if node.owner != root or parent == null or node.top_level:
		return {"warning": "UNSUPPORTED_NODE: instance ownership or top-level transform"}
	if not is_orthogonal(transform) or not is_orthogonal(parent.global_transform):
		return {"warning": "UNSUPPORTED_TRANSFORM: singular, reflected or skewed basis"}
	var scale := Vector2(transform.x.length(), transform.y.length())
	if node is FieldDecoration:
		if node.get_script() != DECORATION or node.get_child_count() != 0:
			return {"warning": "UNSUPPORTED_NODE: custom decoration"}
		var asset := String(node.asset_path)
		var dimensions := texture_size(asset)
		if dimensions == Vector2.ZERO:
			return {"warning": "UNSUPPORTED_NODE: decoration requires a loaded PNG"}
		return {"kind": "decoration", "size": dimensions * scale, "scale": scale,
			"properties": {"texture_path": asset.trim_prefix("res://")}}
	if not is_equal_approx(scale.x, scale.y):
		return {"warning": "UNSUPPORTED_TRANSFORM: non-uniform platform collision scale"}
	var collision := node.get_node_or_null("CollisionShape2D") as CollisionShape2D
	var visual := node.get_node_or_null("Visual") as Polygon2D
	if node.get_child_count() != 2 or collision == null or visual == null or collision.disabled \
			or not collision.shape is RectangleShape2D or not collision.transform.is_equal_approx(Transform2D.IDENTITY) \
			or not visual.transform.is_equal_approx(Transform2D.IDENTITY):
		return {"warning": "UNSUPPORTED_NODE: platform needs centered rectangular collision and visual"}
	var authored_platform: bool = node is FieldPlatform and node.get_script() == PLATFORM_SCRIPT
	if not authored_platform and (node.get_script() != null or not polygon_is_rectangle(visual.polygon, collision.shape.size)):
		return {"warning": "UNSUPPORTED_NODE: custom static body or polygon"}
	if visual.texture != null or not visual.offset.is_zero_approx() or visual.get_child_count() != 0 or collision.get_child_count() != 0:
		return {"warning": "UNSUPPORTED_NODE: custom platform surface"}
	var size: Vector2 = node.size if authored_platform else collision.shape.size
	var one_way: bool = node.one_way if authored_platform else collision.one_way_collision
	var properties := {"one_way": one_way}
	if authored_platform and (node.terrain_texture != null or not node.terrain_theme.is_empty() or node.terrain_margins != Vector4i.ZERO):
		var path: String = node.terrain_texture.resource_path if node.terrain_texture != null else ""
		var m: Vector4i = node.terrain_margins
		var dimensions := Vector2i(texture_size(path))
		var terrain := {"theme_id": node.terrain_theme, "texture_path": path.trim_prefix("res://"),
			"source_size": [dimensions.x, dimensions.y], "margins": [m.x, m.y, m.z, m.w]}
		var issue := terrain_error(terrain, size)
		if not issue.is_empty():
			return {"error": issue}
		if not _can_texture_platform(node):
			return {"error": "UNSUPPORTED_NODE: themed platform has a custom visual or world scale"}
		properties.terrain = terrain
	return {"kind": "platform", "size": size * scale, "scale": scale, "properties": properties,
		"collision_layer": node.collision_layer, "collision_mask": node.collision_mask}

static func texture_size(asset: String) -> Vector2:
	if not asset.begins_with("res://") or asset.get_extension().to_lower() != "png":
		return Vector2.ZERO
	var texture := ResourceLoader.load(asset, "Texture2D") as Texture2D if ResourceLoader.exists(asset, "Texture2D") else null
	return texture.get_size() if texture != null else Vector2.ZERO

static func inventory(root: Node, region_id: String) -> Dictionary:
	var objects: Array = []
	var bindings: Dictionary = {}
	var warnings: Array = []
	var size := Vector2(1600, 900)
	for node in root.find_children("*", "Node2D", true, false):
		var data := classify(node, root)
		if data.is_empty():
			continue
		var path := String(root.get_path_to(node))
		if data.has("error"):
			return {"error": "%s (%s)" % [data.error, path]}
		if data.has("warning"):
			warnings.append("%s (%s)" % [data.warning, path])
			continue
		var transform: Transform2D = node.global_transform
		var extent: Vector2 = data.size
		if not extent.is_finite() or extent.x < MIN_SIZE or extent.y < MIN_SIZE \
				or maxf(extent.x, extent.y) > MAX_SIZE or maxf(absf(transform.origin.x), absf(transform.origin.y)) > MAX_SIZE:
			warnings.append("UNSUPPORTED_TRANSFORM: geometry outside draft limits (%s)" % path)
			continue
		var key := identity(root, node, region_id)
		if bindings.has(key):
			return {"error": "duplicate Godot object ID %s (%s)" % [key, path]}
		var kind: String = data.kind
		var collision := {} if kind == "decoration" else {"layer": data.collision_layer, "mask": data.collision_mask}
		bindings[key] = {"path": path, "parent": String(root.get_path_to(node.get_parent())),
			"local_transform": affine(node.transform), "world_transform": affine(transform),
			"collision": collision}
		objects.append({"id": key, "type": kind, "layer_id": "terrain" if kind == "platform" else "decorations",
			"position": vector(transform.origin), "size": vector(extent),
			"rotation": rad_to_deg(transform.x.angle()), "properties": data.properties})
		size = size.max(transform.origin + extent / 2)
	return {"objects": objects, "bindings": bindings, "warnings": warnings,
		"extent": [clampi(ceili(size.x), 64, 32768), clampi(ceili(size.y), 64, 32768)]}

static func canonical(value: Variant, root: Node, chain: Array = []) -> Variant:
	if value is Node:
		return {"node": String(root.get_path_to(value)) if value == root or root.is_ancestor_of(value) else "<external>"}
	if value is Resource:
		var path: String = value.resource_path
		if path.begins_with("res://") and not path.contains("::"):
			return {"external": path, "uid": uid(path), "type": value.get_class()}
		if chain.has(value):
			return {"cycle": chain.find(value)}
		var next := chain.duplicate()
		next.append(value)
		return {"subresource": value.get_class(), "properties": storage(value, root, next)}
	if value is Array:
		return value.map(func(item: Variant) -> Variant: return canonical(item, root, chain))
	if value is Dictionary:
		var result := {}
		for key: Variant in value:
			result[var_to_str(key)] = canonical(value[key], root, chain)
		return result
	# Godot's Variant syntax retains types and precision that JSON does not.
	return var_to_str(value)

static func storage(object: Object, root: Node, chain: Array = []) -> Dictionary:
	var properties := {}
	for property: Dictionary in object.get_property_list():
		if not (int(property.usage) & PROPERTY_USAGE_STORAGE):
			continue
		var key: String = property.name
		if not key in ["resource_path", "resource_scene_unique_id", "owner", "scene_file_path"]:
			properties[key] = canonical(object.get(key), root, chain)
	return properties

static func inventory_node(node: Node, root: Node, rows: Dictionary, order: Array) -> void:
	var path := String(root.get_path_to(node))
	var groups := Array(node.get_groups())
	groups.sort()
	rows[path] = {"type": node.get_class(), "owner": String(root.get_path_to(node.owner)) if node.owner != null else "",
		"instance": node.scene_file_path, "groups": groups, "properties": storage(node, root)}
	order.append(path)
	for child in node.get_children():
		inventory_node(child, root, rows, order)

static func connections(packed: PackedScene, root: Node) -> Array:
	var state := packed.get_state()
	var result: Array[String] = []
	for i in range(state.get_connection_count()):
		result.append(JSON.stringify([String(state.get_connection_source(i)), String(state.get_connection_signal(i)),
			String(state.get_connection_target(i)), String(state.get_connection_method(i)),
			state.get_connection_flags(i), state.get_connection_unbinds(i), canonical(state.get_connection_binds(i), root)]))
	result.sort()
	return result

static func _subresource_uses(value: Variant, location: String, uses: Dictionary, chain: Array) -> void:
	if value is Resource:
		if not value.is_built_in() or chain.has(value):
			return
		var key: int = value.get_instance_id()
		if not uses.has(key):
			uses[key] = []
		uses[key].append(location)
		var next := chain.duplicate()
		next.append(value)
		for property in value.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE:
				_subresource_uses(value.get(property.name), location + ":" + String(property.name), uses, next)
	elif value is Array:
		for index in range(value.size()):
			_subresource_uses(value[index], "%s[%d]" % [location, index], uses, chain)
	elif value is Dictionary:
		for key: Variant in value:
			_subresource_uses(value[key], location + "[" + var_to_str(key) + "]", uses, chain)

static func scene_state(root: Node, persistent: Array) -> Dictionary:
	var rows := {}
	var order := []
	inventory_node(root, root, rows, order)
	var uses := {}
	for path: String in order:
		var node := root.get_node(NodePath(path))
		for property in node.get_property_list():
			if int(property.usage) & PROPERTY_USAGE_STORAGE:
				_subresource_uses(node.get(property.name), path + ":" + String(property.name), uses, [])
	var aliases: Array[String] = []
	for locations: Array in uses.values():
		if locations.size() > 1:
			locations.sort()
			aliases.append(JSON.stringify(locations))
	aliases.sort()
	return {"nodes": rows, "order": order, "connections": persistent, "subresource_aliases": aliases}

static func _refers_to(value: Variant, owner: Node, victim: Node) -> bool:
	if value is NodePath and not value.is_empty():
		value = owner.get_node_or_null(NodePath(String(value.get_concatenated_names())))
	if value is Node:
		return value == victim or victim.is_ancestor_of(value)
	if value is Array:
		return value.any(func(item: Variant) -> bool: return _refers_to(item, owner, victim))
	if value is Dictionary:
		return value.values().any(func(item: Variant) -> bool: return _refers_to(item, owner, victim))
	return false

static func removal_issue(root: Node, victim: Node, persistent: Array) -> String:
	var subtree := String(root.get_path_to(victim))
	for text: String in persistent:
		var connection: Array = JSON.parse_string(text)
		for path: String in [connection[0], connection[2]]:
			if path == subtree or path.begins_with(subtree + "/"):
				return "UNSUPPORTED_NODE: persistent signal references %s" % path
	for node in [root] + Array(root.find_children("*", "", true, false)):
		if victim == node or victim.is_ancestor_of(node):
			continue
		for property in node.get_property_list():
			if not (int(property.usage) & PROPERTY_USAGE_STORAGE):
				continue
			if _refers_to(node.get(property.name), node, victim):
				return "UNSUPPORTED_NODE: %s.%s references %s" % [root.get_path_to(node), property.name, subtree]
	return ""

static func set_world(node: Node2D, value: Transform2D) -> void:
	var parent := node.get_parent() as Node2D
	node.transform = parent.global_transform.affine_inverse() * value
	# Godot may omit a near-zero skew from the text scene. Apply the intended
	# orthogonal local basis explicitly when the residual is float roundoff.
	if is_zero_approx(node.skew):
		node.skew = 0.0

static func object_error(object: Dictionary) -> String:
	var id_pattern := RegEx.create_from_string("^[a-z][a-z0-9_]{0,63}$")
	if not object.get("id") is String or id_pattern.search(object.id) == null:
		return "INVALID_DOCUMENT: invalid object ID"
	var kind: Variant = object.get("type")
	if kind != "platform" and kind != "decoration":
		return "INVALID_DOCUMENT: unsupported object type"
	if object.get("layer_id") != ("terrain" if kind == "platform" else "decorations"):
		return "UNSUPPORTED_NODE: unsupported Godot layer for %s" % object.id
	for field: String in ["position", "size"]:
		var values: Variant = object.get(field)
		if not values is Array or values.size() != 2:
			return "INVALID_DOCUMENT: invalid %s for %s" % [field, object.id]
		for n: Variant in values:
			if not _number_in(n, MIN_SIZE if field == "size" else -MAX_SIZE, MAX_SIZE):
				return "INVALID_DOCUMENT: invalid %s for %s" % [field, object.id]
	if not _number_in(object.get("rotation"), -MAX_SIZE, MAX_SIZE) or not object.get("properties") is Dictionary:
		return "INVALID_DOCUMENT: invalid rotation or properties for %s" % object.id
	if kind == "platform" and not object.properties.get("one_way", false) is bool:
		return "INVALID_DOCUMENT: invalid one-way value for %s" % object.id
	var terrain: Variant = object.properties.get("terrain")
	if terrain != null:
		if kind != "platform":
			return "INVALID_DOCUMENT: terrain requires a platform"
		var size := Vector2(float(object.size[0]), float(object.size[1]))
		var issue := terrain_error(terrain, size)
		if not issue.is_empty():
			return "%s (%s)" % [issue, object.id]
	if kind == "decoration":
		var texture: Variant = object.properties.get("texture_path")
		if not texture is String or texture.is_empty() or texture.is_absolute_path() or texture.contains("\\") \
				or texture.contains(":") or texture.split("/").has("..") or texture.split("/").has(".") \
				or texture_size("res://" + texture) == Vector2.ZERO:
			return "RESOURCE_MISSING: decoration PNG for %s (%s)" % [object.id, texture]
	return ""

static func _terrain_png(value: Variant) -> Vector2:
	if not value is String or not value.begins_with("assets/terrain/") or value.contains("\\") or value.contains(":"):
		return Vector2.ZERO
	for part: String in value.split("/"):
		if part.is_empty() or part == "." or part == ".." or part.ends_with(".") or part.ends_with(" "):
			return Vector2.ZERO
	return texture_size("res://" + value)


static func _terrain_geometry(dimensions: Variant, margins: Variant, actual: Vector2) -> bool:
	if not dimensions is Array or dimensions.size() != 2 or not margins is Array or margins.size() != 4:
		return false
	for n: Variant in dimensions + margins:
		if not _number_in(n, 1, 2048) or float(n) != floorf(float(n)):
			return false
	return actual == Vector2(float(dimensions[0]), float(dimensions[1])) \
		and margins[0] + margins[2] < dimensions[0] and margins[1] + margins[3] < dimensions[1]


static func terrain_error(terrain: Variant, size: Vector2) -> String:
	if not terrain is Dictionary or terrain.size() != 4 or not terrain.get("theme_id") is String \
		or RegEx.create_from_string("^[a-z][a-z0-9_]{0,63}$").search(terrain.theme_id) == null:
		return "INVALID_DOCUMENT: invalid terrain surface"
	var metadata := "res://assets/terrain/%s.json" % terrain.theme_id
	if not FileAccess.file_exists(metadata):
		return "RESOURCE_MISSING: " + metadata
	var atlas: Variant = JSON.parse_string(FileAccess.get_file_as_string(metadata))
	if not atlas is Dictionary or atlas.get("format") != "rtc_terrain_9slice" or atlas.get("version") != 1 \
		or atlas.get("theme_id") != terrain.theme_id or atlas.get("filter") != "nearest" \
		or atlas.get("edge_mode") != "tile" or atlas.get("center_mode") != "tile" or not atlas.get("margins") is Dictionary:
		return "INVALID_DOCUMENT: unsupported terrain metadata"
	var defaults: Dictionary = atlas.margins
	var atlas_texture := _terrain_png(atlas.get("texture"))
	if atlas_texture == Vector2.ZERO:
		return "RESOURCE_MISSING: " + str(atlas.get("texture"))
	if not _terrain_geometry(atlas.get("source_size"), [defaults.get("left"), defaults.get("top"),
		defaults.get("right"), defaults.get("bottom")], atlas_texture):
		return "INVALID_DOCUMENT: invalid terrain atlas dimensions or margins"
	var actual := _terrain_png(terrain.get("texture_path"))
	if actual == Vector2.ZERO:
		return "RESOURCE_MISSING: " + str(terrain.get("texture_path"))
	if not _terrain_geometry(terrain.get("source_size"), terrain.get("margins"), actual):
		return "INVALID_DOCUMENT: invalid terrain PNG dimensions or slice margins"
	for texture: String in [atlas.texture, terrain.texture_path]:
		var path := "res://" + texture
		var resource_id := ResourceLoader.get_resource_uid(path)
		if resource_id != ResourceUID.INVALID_ID and ResourceUID.get_id_path(resource_id) != path:
			return "UID_CONFLICT: " + path
	var margins: Array = terrain.margins
	if size.x < margins[0] + margins[2] or size.y < margins[1] + margins[3]:
		return "INVALID_DOCUMENT: platform is smaller than its terrain margins"
	return ""


static func _can_texture_platform(node: Node2D) -> bool:
	if node.get_script() != PLATFORM_SCRIPT and (node.get_script() != null or not node.scene_file_path.is_empty()):
		return false
	var visual := node.get_node_or_null("Visual") as Polygon2D
	var basis := node.global_transform
	return visual != null and visual.visible and visual.material == null and node.material == null \
		and not visual.use_parent_material and visual.modulate == Color.WHITE and visual.self_modulate == Color.WHITE \
		and visual.z_index == 0 and visual.z_as_relative and is_equal_approx(basis.x.length(), 1.0) \
		and is_equal_approx(basis.y.length(), 1.0)


static func _number_in(value: Variant, low: float, high: float) -> bool:
	return (value is int or value is float) and is_finite(value) and value >= low and value <= high

static func apply(root: Node2D, node: Node2D, object: Dictionary) -> String:
	var decoration: bool = object.type == "decoration"
	if node == null:
		var layer_name := "Decorations" if decoration else "Terrain"
		var target := root.get_node_or_null(layer_name)
		if target == null:
			target = Node2D.new()
			target.name = layer_name
			root.add_child(target)
			target.owner = root
		if not target is Node2D or target.owner != root or target.get_script() != null or not is_orthogonal(target.global_transform):
			return "UNSUPPORTED_TRANSFORM: placement parent %s" % layer_name
		var node_name: String = "RTC_" + object.id
		if target.has_node(NodePath(node_name)):
			return "UNSUPPORTED_NODE: node path collision for %s" % object.id
		node = DECORATION.new() if decoration else PLATFORM.instantiate()
		node.name = node_name
		node.set_meta(EDIT_ID, object.id)
		target.add_child(node)
		node.owner = root
	var old: Transform2D = node.global_transform
	var offset := Vector2(float(object.position[0]), float(object.position[1]))
	var size := Vector2(float(object.size[0]), float(object.size[1]))
	var radians := deg_to_rad(float(object.rotation))
	if decoration:
		var texture := "res://" + String(object.properties.texture_path)
		var scale := size / texture_size(texture)
		node.asset_path = texture
		set_world(node, Transform2D(radians, scale, 0.0, offset))
	else:
		var scale := Vector2(old.x.length(), old.y.length())
		var local_size := size / scale
		var terrain: Variant = object.properties.get("terrain")
		if terrain != null:
			if not _can_texture_platform(node):
				return "UNSUPPORTED_NODE: terrain requires a standard rectangular visual and unit world scale"
			if not node is FieldPlatform:
				var legacy_visual := node.get_node("Visual") as Polygon2D
				var legacy_collider := node.get_node("CollisionShape2D") as CollisionShape2D
				node.set_script(PLATFORM_SCRIPT)
				node.size = legacy_collider.shape.size
				node.tint = legacy_visual.color
				node.one_way = legacy_collider.one_way_collision
				node.set_meta(EDIT_ID, object.id)
		set_world(node, Transform2D(radians, scale, 0.0, offset))
		if node is FieldPlatform:
			node.size = local_size
			node.one_way = object.properties.get("one_way", false)
			if terrain is Dictionary:
				node.terrain_theme = terrain.theme_id
				node.terrain_texture = ResourceLoader.load("res://" + terrain.texture_path, "Texture2D") as Texture2D
				var m: Array = terrain.margins
				node.terrain_margins = Vector4i(int(m[0]), int(m[1]), int(m[2]), int(m[3]))
			else:
				node.terrain_theme = ""
				node.terrain_texture = null
				node.terrain_margins = Vector4i.ZERO
		else:
			var collision := node.get_node("CollisionShape2D") as CollisionShape2D
			var visual := node.get_node("Visual") as Polygon2D
			var shape := collision.shape as RectangleShape2D
			if not shape.size.is_equal_approx(local_size):
				var ratio := local_size / shape.size
				var copy := shape.duplicate() as RectangleShape2D
				copy.size = local_size
				collision.shape = copy
				var polygon := visual.polygon
				for index in range(polygon.size()):
					polygon[index] *= ratio
				visual.polygon = polygon
			collision.one_way_collision = object.properties.get("one_way", false)
	return ""
