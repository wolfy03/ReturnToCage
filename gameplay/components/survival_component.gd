class_name SurvivalComponent
extends Node

signal survival_changed(hunger: float, thirst: float, hunger_stage: int, thirst_stage: int)

@export var config: SurvivalConfig
var state: SurvivalState = SurvivalState.new()
var hunger: float:
	get:
		return state.hunger
	set(value):
		state.hunger = value
var thirst: float:
	get:
		return state.thirst
	set(value):
		state.thirst = value
var drain_multiplier: float = 1.0
var progression_reduction: float:
	get:
		return state.progression_reduction
	set(value):
		state.progression_reduction = value
var drain_paused: bool = false

func configure(p_config: SurvivalConfig, p_difficulty_multiplier: float, p_state: SurvivalState = null) -> void:
	config = p_config
	drain_multiplier = p_difficulty_multiplier
	if p_state != null:
		state = p_state
		state.hunger = clampf(state.hunger, 0.0, config.max_hunger)
		state.thirst = clampf(state.thirst, 0.0, config.max_thirst)
	else:
		state.hunger = config.max_hunger
		state.thirst = config.max_thirst
	_emit_changed()

func _process(delta: float) -> void:
	if config == null or drain_paused:
		return
	var effective := drain_multiplier * (1.0 - clampf(progression_reduction, 0.0, 0.9))
	hunger = maxf(0.0, hunger - config.hunger_drain_per_second * effective * delta)
	thirst = maxf(0.0, thirst - config.thirst_drain_per_second * effective * delta)
	_emit_changed()

func consume(definition: ItemDefinition) -> void:
	if config == null:
		return
	hunger = minf(config.max_hunger, hunger + definition.hunger_restore)
	thirst = minf(config.max_thirst, thirst + definition.thirst_restore)
	_emit_changed()

func set_values(p_hunger: float, p_thirst: float) -> void:
	if config == null:
		return
	hunger = clampf(p_hunger, 0.0, config.max_hunger)
	thirst = clampf(p_thirst, 0.0, config.max_thirst)
	_emit_changed()

func to_dict() -> Dictionary:
	return state.to_dict()

func restore_state(data: Dictionary) -> void:
	state.progression_reduction = 0.0
	state.restore(data)
	set_values(hunger, thirst)

func _emit_changed() -> void:
	if config != null:
		survival_changed.emit(hunger, thirst, config.stage_for_ratio(hunger / config.max_hunger), config.stage_for_ratio(thirst / config.max_thirst))
