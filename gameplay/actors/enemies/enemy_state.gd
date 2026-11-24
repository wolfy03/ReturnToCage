class_name EnemyState
extends Node

var agent: EnemyAgent

func setup(p_agent: EnemyAgent) -> void:
	agent = p_agent

func enter() -> void:
	pass

func physics_tick(_delta: float) -> StringName:
	return &""

## Replicated state for this node, or -1 to use the default mapping by state
## name in NetworkEnemyComponent. Lets an enemy add states without changing the
## snapshot payload.
func snapshot_state() -> int:
	return -1
