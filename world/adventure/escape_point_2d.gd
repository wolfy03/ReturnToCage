class_name EscapePoint2D
extends InteractionTarget

var requires_landing: bool = false
var display_policy: DifficultyDefinition.EscapeDisplay = DifficultyDefinition.EscapeDisplay.ALWAYS

func can_interact(actor: Node) -> bool:
	if not super.can_interact(actor):
		return false
	if requires_landing and actor is PlayerActor:
		return actor.movement.mode != MovementComponent.Mode.CLIMB and actor.global_position.y <= global_position.y + 8.0
	return true

func _process(_delta: float) -> void:
	var player := get_tree().get_first_node_in_group(&"player") as PlayerActor
	if player != null and player.global_position.distance_to(global_position) < 65.0:
		GameSession.discover_escape(interaction_id)
	var discovered: bool = GameSession.progression.discovered_escape_points.has(interaction_id)
	if GameSession.adventure.active_session != null:
		discovered = discovered or GameSession.adventure.active_session.discovered_escape_points.has(interaction_id)
	visible = display_policy == DifficultyDefinition.EscapeDisplay.ALWAYS or (display_policy == DifficultyDefinition.EscapeDisplay.DISCOVERED and discovered)
