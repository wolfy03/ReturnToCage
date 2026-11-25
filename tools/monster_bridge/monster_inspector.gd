extends RefCounted
## Reads what the game ships for an EnemyDefinition: values, actor scene structure,
## state timings, collision shapes, animation profile and loot.
##
## One implementation for every tool that needs these facts - the contract probe
## and the editor bridge - so "what the engine says" cannot differ between them.
## It only reads. Nothing here saves a resource, and it assumes nothing about a
## particular monster: unknown structure is reported as it is found or left out.

## Engine and project facts every response carries.
static func environment() -> Dictionary:
	return {
		"godot_version": Engine.get_version_info().string,
		"physics_ticks_per_second": Engine.physics_ticks_per_second,
		"network_protocol_version": NetworkProtocol.VERSION,
		"gravity": EnemyAgent.GRAVITY,
		"target_keep_range_scale": EnemyAgent.TARGET_KEEP_RANGE_SCALE,
		"snapshot_states": EnemyRuntimeSnapshot.State.keys(),
	}

static func enemy_definitions() -> Array[EnemyDefinition]:
	var definitions: Array[EnemyDefinition] = []
	for definition in ContentRegistry.all_definitions():
		if definition is EnemyDefinition:
			definitions.append(definition)
	return definitions

static func item_ids() -> Array[String]:
	var ids: Array[String] = []
	for definition in ContentRegistry.all_definitions():
		if definition is ItemDefinition:
			ids.append(String(definition.id))
	ids.sort()
	return ids

static func describe(definition: EnemyDefinition) -> Dictionary:
	var entry := {
		"definition_path": definition.resource_path,
		"display_name": definition.display_name,
		"max_health": definition.max_health,
		"attack_damage": definition.attack_damage,
		"move_speed": definition.move_speed,
		"chase_range": definition.chase_range,
		"attack_range": definition.attack_range,
		"faction": String(definition.faction),
		"loot_table_id": String(definition.loot_table_id),
		"definition_errors": Array(definition.validate_definition(ContentRegistry)),
		"actor_scene_path": definition.actor_scene.resource_path if definition.actor_scene != null else "",
	}
	var table := ContentRegistry.get_definition(definition.loot_table_id) as LootTableDefinition
	if table != null:
		entry["loot"] = {
			"path": table.resource_path,
			"item_ids": table.item_ids.map(func(id: StringName) -> String: return String(id)),
			"weights": Array(table.weights),
			"min_amounts": Array(table.min_amounts),
			"max_amounts": Array(table.max_amounts),
			"apply_difficulty_multiplier": table.apply_difficulty_multiplier,
		}
	if definition.actor_scene == null:
		return entry
	# Not added to the tree: _ready does not run, only the authored scene data is read.
	var actor := definition.actor_scene.instantiate() as EnemyAgent
	if actor == null:
		return entry
	entry["agent_script"] = (actor.get_script() as Script).resource_path
	# What every enemy actor must have, whatever kind of monster it is.
	entry["components"] = {
		"health": actor.get_node_or_null("%Health") is HealthComponent,
		"hurtbox": actor.get_node_or_null("%Hurtbox") is HurtboxComponent,
		"network_enemy": actor.get_node_or_null("%NetworkEnemy") is NetworkEnemyComponent,
		"states": actor.get_node_or_null("%States") != null,
	}
	entry["agent_properties"] = exported(actor)
	entry["agent_constants"] = constants(actor)
	entry["collision_layer"] = actor.collision_layer
	entry["collision_mask"] = actor.collision_mask
	entry["body"] = shapes(actor)
	var hurtbox := actor.get_node_or_null("%Hurtbox") as HurtboxComponent
	if hurtbox != null:
		entry["hurtbox"] = {
			"collision_layer": hurtbox.collision_layer,
			"collision_mask": hurtbox.collision_mask,
			"shapes": shapes(hurtbox),
		}
	var health := actor.get_node_or_null("%Health") as HealthComponent
	if health != null:
		entry["invulnerability_seconds"] = health.invulnerability_seconds
	var states: Array[Dictionary] = []
	var states_root := actor.get_node_or_null("%States")
	if states_root != null:
		for child in states_root.get_children():
			if child is EnemyState:
				states.append({
					"id": child.name.to_snake_case(),
					"script": (child.get_script() as Script).resource_path,
					"snapshot_state": child.snapshot_state(),
					"properties": exported(child),
					"constants": constants(child),
				})
	entry["states"] = states
	entry["animation_profile_path"] = actor.animation_profile_path
	actor.free()
	if not String(entry.animation_profile_path).is_empty():
		entry["profile"] = profile(entry.animation_profile_path)
	return entry

## Exported script variables with plain values, which is what a designer can tune.
static func exported(node: Object) -> Dictionary:
	var values := {}
	for property in node.get_property_list():
		var usage: int = property.usage
		if usage & PROPERTY_USAGE_SCRIPT_VARIABLE == 0 or usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		var value: Variant = node.get(property.name)
		if value is float or value is int or value is bool:
			values[property.name] = value
		elif value is String or value is StringName:
			values[property.name] = String(value)
	return values

## Numeric script constants, including the ones inherited from base scripts.
static func constants(node: Object) -> Dictionary:
	var values := {}
	var script := node.get_script() as Script
	while script != null:
		var constants := script.get_script_constant_map()
		for key in constants:
			var value: Variant = constants[key]
			if (value is float or value is int) and not values.has(key):
				values[key] = value
		script = script.get_base_script()
	return values

static func shapes(parent: Node) -> Array[Dictionary]:
	var shapes: Array[Dictionary] = []
	for child in parent.get_children():
		var collision := child as CollisionShape2D
		if collision == null or collision.shape == null:
			continue
		var shape := {
			"class": collision.shape.get_class(),
			"position": [collision.position.x, collision.position.y],
			"disabled": collision.disabled,
		}
		if collision.shape is RectangleShape2D:
			var size: Vector2 = (collision.shape as RectangleShape2D).size
			shape["size"] = [size.x, size.y]
		elif collision.shape is CircleShape2D:
			shape["radius"] = (collision.shape as CircleShape2D).radius
		shapes.append(shape)
	return shapes

static func profile(path: String) -> Dictionary:
	var profile := ResourceLoader.load(path) as EnemyAnimationProfile
	if profile == null:
		return {"error": "cannot load %s" % path}
	var data := {
		"errors": Array(profile.validation_errors()),
		"sprite_frames_path": profile.sprite_frames.resource_path if profile.sprite_frames != null else "",
		"faces_right_by_default": profile.faces_right_by_default,
		"visual_scale": [profile.visual_scale.x, profile.visual_scale.y],
		"visual_offset": [profile.visual_offset.x, profile.visual_offset.y],
		"attack_hit_frame": profile.attack_hit_frame,
		"attack_hit_seconds": profile.frame_start_seconds(profile.attack_animation, profile.attack_hit_frame),
		"airborne_speed": profile.airborne_speed,
		"move_speed_threshold": profile.move_speed_threshold,
		"texture_filter": int(profile.get("texture_filter")) if "texture_filter" in profile else -1,
		"roles": {
			"idle": String(profile.idle_animation), "move": String(profile.move_animation),
			"attack": String(profile.attack_animation), "hurt": String(profile.hurt_animation),
			"death": String(profile.death_animation), "jump_start": String(profile.jump_start_animation),
			"jump": String(profile.jump_animation), "fall": String(profile.fall_animation),
			"land": String(profile.land_animation),
		},
		"animations": {},
	}
	if profile.sprite_frames == null:
		return data
	var frames := profile.sprite_frames
	for animation in frames.get_animation_names():
		var rows: Array[Dictionary] = []
		for index in frames.get_frame_count(animation):
			var texture := frames.get_frame_texture(animation, index)
			var atlas := texture as AtlasTexture
			var row := {"duration": frames.get_frame_duration(animation, index)}
			if atlas != null and atlas.atlas != null:
				row["texture_path"] = atlas.atlas.resource_path
				row["region"] = [atlas.region.position.x, atlas.region.position.y, atlas.region.size.x, atlas.region.size.y]
			elif texture != null:
				row["texture_path"] = texture.resource_path
				row["region"] = [0.0, 0.0, float(texture.get_width()), float(texture.get_height())]
			rows.append(row)
		data.animations[String(animation)] = {
			"fps": frames.get_animation_speed(animation),
			"loop": frames.get_animation_loop(animation),
			"seconds": profile.animation_seconds(animation),
			"frames": rows,
		}
	return data
