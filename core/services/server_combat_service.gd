class_name ServerCombatService
extends RefCounted

## Executes the existing combat pipeline. Network authentication and life-state
## checks deliberately stay in NetworkCombatComponent.
static func try_player_attack(actor: PlayerActor) -> CombatResult:
	if actor == null or not is_instance_valid(actor) or actor.combat == null:
		return CombatResult.make(false, 0, "Player combat is unavailable")
	if not actor.combat.attack(actor.facing):
		return CombatResult.make(false, actor.peer_id, "Attack rejected by combat rules")
	return CombatResult.make(true, actor.peer_id)
