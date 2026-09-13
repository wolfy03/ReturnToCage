class_name HitboxComponent
extends Area2D
## The collision half of an attack: whether it is live right now, and which
## targets it already hit.
##
## It owns no duration. [CombatComponent] is the single owner of attack phase
## timing and switches this on when the attack enters ATTACK_ACTIVE and off when
## it leaves — nothing here reads `active_seconds` or counts down.

var context: DamageContext
var active: bool = false
var _hit_targets: Array[int] = []

func _ready() -> void:
	area_entered.connect(_on_area_entered)

func configure_range(distance: float, facing: float) -> void:
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision != null:
		var shape := RectangleShape2D.new()
		shape.size = Vector2(distance, 30.0)
		collision.shape = shape
	position.x = distance * 0.5 * signf(facing)

## Makes the hitbox live for whatever targets it overlaps, until [method
## deactivate]. Enabling `monitoring` only takes effect on the next physics step,
## so anything already inside the shape is resolved immediately with a direct
## space query — otherwise an attack whose whole ACTIVE phase falls inside one
## long frame would never get a chance to hit.
func activate(p_context: DamageContext) -> void:
	context = p_context
	active = true
	_hit_targets.clear()
	set_deferred("monitoring", true)
	_sweep_overlaps_now()

## Ends the live window. `active` drops immediately so that a deferred
## `monitoring` change still in flight cannot deal damage in between.
func deactivate() -> void:
	active = false
	context = null
	_hit_targets.clear()
	set_deferred("monitoring", false)

## Resolves everything currently inside the hitbox shape without waiting for the
## next physics step.
func _sweep_overlaps_now() -> void:
	var collision := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if collision == null or collision.shape == null or not is_inside_tree():
		return
	var space := get_world_2d().direct_space_state
	if space == null:
		return
	var query := PhysicsShapeQueryParameters2D.new()
	query.shape = collision.shape
	query.transform = collision.global_transform
	query.collision_mask = collision_mask
	query.collide_with_areas = true
	query.collide_with_bodies = false
	for hit in space.intersect_shape(query, 32):
		_on_area_entered(hit.get("collider") as Area2D)

func _on_area_entered(area: Area2D) -> void:
	if active and area is HurtboxComponent and not _hit_targets.has(area.get_instance_id()):
		if area.receive_hit(context):
			_hit_targets.append(area.get_instance_id())
