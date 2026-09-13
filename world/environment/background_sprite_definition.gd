class_name BackgroundSpriteDefinition
extends Resource
## One decorative sprite inside a [BackgroundLayerDefinition]. Presentation-only.
##
## The atlas sheets in assets/backgrounds hold several objects per image, so a
## layer can place any number of these (each pointing at an AtlasTexture region)
## instead of tiling the whole sheet. Positions are expressed in the
## [member EnvironmentDefinition.reference_size] coordinate space and are
## rescaled by [EnvironmentPresenter] when the viewport size differs.

@export var texture: Texture2D
## Sprite center in reference-viewport coordinates (see EnvironmentDefinition).
@export var position: Vector2 = Vector2.ZERO
## Local scale applied on top of the presenter layout scale.
@export var scale: Vector2 = Vector2.ONE
@export var modulate: Color = Color.WHITE
@export var flip_h: bool = false
