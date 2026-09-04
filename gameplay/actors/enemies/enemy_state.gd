class_name EnemyState
extends Node

var agent: EnemyAgent

func setup(p_agent: EnemyAgent) -> void:
	agent = p_agent

func enter() -> void:
	pass

func physics_tick(_delta: float) -> StringName:
	return &""
