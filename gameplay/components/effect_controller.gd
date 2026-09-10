class_name EffectController
extends Node
## Scene adapter. Session-owned models are ticked only by GameSession.
signal effects_changed
var model: EffectRuntimeModel
var stats: StatBlock
var session_owned: bool = false
var active_effects: Dictionary[StringName, ActiveEffect]:
	get:
		return model.active_effects

func configure(p_stats: StatBlock, shared: EffectRuntimeModel = null) -> void:
	if model != null and model.changed.is_connected(effects_changed.emit):
		model.changed.disconnect(effects_changed.emit)
	stats = p_stats
	session_owned = shared != null
	model = shared if shared != null else EffectRuntimeModel.new(stats)
	model.changed.connect(effects_changed.emit)

func _process(delta: float) -> void:
	if model != null and not session_owned:
		model.tick(delta)

func _exit_tree() -> void:
	if model == null:
		return
	if model.changed.is_connected(effects_changed.emit):
		model.changed.disconnect(effects_changed.emit)
	if not session_owned:
		for key in model.active_effects.keys():
			model.remove_effect(key)

func apply_item(definition: ItemDefinition) -> void:
	model.apply_item(definition)

func apply_effect(definition: EffectDefinition, food_slot: ItemDefinition.FoodSlot = ItemDefinition.FoodSlot.NONE) -> void:
	model.apply_effect(definition, food_slot)

func remove_effect(id: StringName) -> void:
	model.remove_effect(id)

func descriptions() -> Array[String]:
	return model.descriptions() if model != null else []
