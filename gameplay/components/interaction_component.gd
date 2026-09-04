class_name InteractionComponent
extends Area2D

signal target_changed(target: InteractionTarget)

var _targets: Array[InteractionTarget] = []
var current_target: InteractionTarget

func _ready() -> void:
	area_entered.connect(_on_area_entered)
	area_exited.connect(_on_area_exited)

func try_interact(actor: Node) -> bool:
	return current_target != null and current_target.interact(actor)

func _on_area_entered(area: Area2D) -> void:
	if area is InteractionTarget:
		_targets.append(area)
		_select_target()

func _on_area_exited(area: Area2D) -> void:
	if area is InteractionTarget:
		_targets.erase(area)
		_select_target()

func _select_target() -> void:
	var previous := current_target
	current_target = null
	for candidate in _targets:
		if candidate.can_interact(get_parent()) and (current_target == null or candidate.interaction_priority > current_target.interaction_priority or (candidate.interaction_priority == current_target.interaction_priority and global_position.distance_squared_to(candidate.global_position) < global_position.distance_squared_to(current_target.global_position))):
			current_target = candidate
	if previous != current_target:
		target_changed.emit(current_target)
