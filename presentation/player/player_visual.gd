class_name PlayerVisual
extends Node2D
## Thin scene boundary that keeps all visual nodes outside PlayerActor's
## gameplay core. The presenter owns state resolution; this node only wires it.

@onready var presenter: PlayerAnimationPresenter = %PlayerAnimationPresenter

func configure(actor: PlayerActor) -> void:
	if presenter != null:
		presenter.configure(actor)

