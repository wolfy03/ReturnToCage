class_name QuestSystem
extends RefCounted

signal quest_mutated(quest_id: StringName, scope: int, owner_player_id: StringName, revision: int)

var progression: ProgressionState
var settlement: SettlementState
var registry: Node
var player_state_resolver: Callable

func _init(
	p_progression: ProgressionState,
	p_settlement: SettlementState,
	p_registry: Node,
	p_player_state_resolver: Callable
) -> void:
	progression = p_progression
	settlement = p_settlement
	registry = p_registry
	player_state_resolver = p_player_state_resolver

func start_quest(quest_id: StringName, actor_player_id: StringName) -> CommandResult:
	var definition := registry.get_definition(quest_id) as QuestDefinition
	var check := ProgressionService.check_quest_start(quest_id, progression, registry, actor_player_id)
	if not check.success or definition == null:
		return check
	var state := QuestState.new(quest_id)
	state.initialize(definition)
	if not progression.set_quest_state(quest_id, actor_player_id, state, registry):
		return CommandResult.make(false, "Quest owner is unavailable")
	_notify(definition, actor_player_id)
	return CommandResult.make(true, "Quest started: %s" % definition.title)

func report(event: GameplayEvent) -> void:
	if event == null or event.amount <= 0 or event.target_id.is_empty():
		return
	# Kill and collect credit require a concrete player contribution. This prevents
	# environment deaths or ownerless drops from advancing either ownership scope.
	if event.type in [QuestObjectiveDefinition.ObjectiveType.KILL_ENEMY, QuestObjectiveDefinition.ObjectiveType.COLLECT_ITEM] \
			and event.actor_player_id.is_empty():
		return
	for quest_id in progression.shared_quest_states.keys():
		var definition := registry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = progression.shared_quest_states.get(quest_id)
		if definition != null and state != null and state.apply_event(definition, event.type, event.target_id, event.amount):
			_notify(definition, &"")
	if event.actor_player_id.is_empty():
		return
	var personal := progression.get_personal_progression(event.actor_player_id)
	if personal == null:
		return
	for quest_id in personal.quest_states.keys():
		var definition := registry.get_definition(quest_id) as QuestDefinition
		var state: QuestState = personal.quest_states.get(quest_id)
		if definition != null and state != null and state.apply_event(definition, event.type, event.target_id, event.amount):
			_notify(definition, event.actor_player_id)

func claim_reward(quest_id: StringName, actor_player_id: StringName) -> CommandResult:
	var definition := registry.get_definition(quest_id) as QuestDefinition
	if definition == null:
		return CommandResult.make(false, "Unknown quest")
	var owner := actor_player_id if definition.scope == QuestDefinition.Scope.PERSONAL else &""
	var state := progression.get_quest_state(quest_id, actor_player_id, registry)
	if state == null or not state.begin_reward_claim():
		return CommandResult.make(false, "Quest reward is unavailable")
	var destination: InventoryModel
	if definition.scope == QuestDefinition.Scope.PERSONAL:
		var player_state := player_state_resolver.call(actor_player_id) as PlayerState
		destination = player_state.inventory if player_state != null else null
	else:
		destination = settlement.storage
	if destination == null:
		state.finish_reward_claim(false)
		return CommandResult.make(false, "Quest reward owner is unavailable")
	destination.begin_update()
	var reward := destination.exchange([], ProgressionService.item_amounts(definition.reward_item_ids, definition.reward_amounts))
	state.finish_reward_claim(reward.success)
	destination.end_update()
	if not reward.success:
		return reward
	_notify(definition, owner)
	for follow_up_id in definition.follow_up_quest_ids:
		start_quest(follow_up_id, actor_player_id)
	return CommandResult.make(true, "Quest reward claimed")

func _notify(definition: QuestDefinition, owner_player_id: StringName) -> void:
	var owner := owner_player_id if definition.scope == QuestDefinition.Scope.PERSONAL else &""
	var revision := progression.bump_quest_revision(definition.id, owner)
	quest_mutated.emit(definition.id, int(definition.scope), owner, revision)
