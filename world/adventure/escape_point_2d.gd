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
	if NetworkManager.is_authoritative_simulation():
		for node in get_tree().get_nodes_in_group(&"player"):
			var player := node as PlayerActor
			var runtime := GameSession.get_player_runtime(player.peer_id) if player != null else null
			if player != null and runtime != null and runtime.life_phase == PlayerRuntimeState.LifePhase.ALIVE \
					and player.is_simulation_authority() and player.get_parent() == get_parent() \
					and player.global_position.distance_to(global_position) < 65.0:
				GameSession.discover_escape(interaction_id, GameSession.get_player_id(player.peer_id))
				break
	var discovered: bool = GameSession.progression.discovered_escape_points.has(interaction_id)
	var world_id := GameSession.get_peer_world_id(GameSession.get_local_peer_id())
	var region := get_parent()
	if region != null and region.get("context") is AdventureContext:
		world_id = PlayerWorldState.adventure_world_id(region.context.region_id)
	var session := GameSession.adventure_session_for_world(world_id)
	if session != null:
		discovered = discovered or session.discovered_escape_points.has(interaction_id)
	visible = display_policy == DifficultyDefinition.EscapeDisplay.ALWAYS or (display_policy == DifficultyDefinition.EscapeDisplay.DISCOVERED and discovered)
