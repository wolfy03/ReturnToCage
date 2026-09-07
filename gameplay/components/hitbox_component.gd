class_name HitboxComponent
extends Area2D

var context: DamageContext
var active: bool = false
var remaining: float = 0.0
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

func arm(p_context: DamageContext, seconds: float = 0.12) -> void:
	context = p_context
	active = true
	remaining = seconds
	_hit_targets.clear()
	set_deferred("monitoring", true)

func _process(delta: float) -> void:
	if not active:
		return
	for area in get_overlapping_areas():
		_on_area_entered(area)
	remaining -= delta
	if remaining <= 0.0:
		active = false
		set_deferred("monitoring", false)

func _on_area_entered(area: Area2D) -> void:
	if active and area is HurtboxComponent and not _hit_targets.has(area.get_instance_id()):
		if area.receive_hit(context):
			_hit_targets.append(area.get_instance_id())
