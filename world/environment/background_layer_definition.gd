class_name BackgroundLayerDefinition
extends Resource
## Data for one visual background layer. Presentation-only: never referenced by
## gameplay models, never replicated, never loaded by ContentRegistry.
##
## A layer becomes one Parallax2D in [EnvironmentPresenter]. It can carry a
## single full-layer [member texture] (sky, overlay) that is fitted to the
## viewport with [member fit_mode], and/or a list of individually placed
## [member sprites] (cloud bands, sun, moon) laid out in the reference viewport
## space of the owning [EnvironmentDefinition].

enum FitMode {
	## Use the texture at its native size (times [member scale]).
	NONE,
	## Uniform scale so the texture covers the whole viewport; aspect ratio is kept
	## and overflow is cropped. Use for full-screen sky images.
	COVER,
	## Uniform scale so the texture width matches the viewport width.
	FIT_WIDTH,
	## Uniform scale so the texture height matches the viewport height.
	FIT_HEIGHT,
}

## Stable identifier used by EnvironmentPresenter node names and lookups
## (for example a future day/night controller finding the "sun" layer).
@export var layer_name: StringName = &""
@export var enabled: bool = true

@export_group("Single texture")
@export var texture: Texture2D
@export var fit_mode: FitMode = FitMode.NONE
## Extra offset in reference-viewport coordinates, applied after fitting.
@export var position_offset: Vector2 = Vector2.ZERO
## Extra scale multiplied on top of the fit result.
@export var scale: Vector2 = Vector2.ONE

@export_group("Placed sprites")
## Individually placed sprites (atlas regions). Positions are in
## reference-viewport coordinates.
@export var sprites: Array[BackgroundSpriteDefinition] = []

@export_group("Parallax")
## Parallax2D.scroll_scale: 0 = fixed to the screen, 1 = moves with the world.
@export var scroll_scale: Vector2 = Vector2.ZERO
## Parallax2D.autoscroll in reference pixels per second (camera independent).
@export var autoscroll: Vector2 = Vector2.ZERO
## Parallax2D.repeat_size in reference pixels; zero disables repetition on that
## axis. Only meaningful when the layer content is periodic over that size.
@export var repeat_size: Vector2 = Vector2.ZERO
@export_range(1, 8, 1) var repeat_times: int = 1

@export_group("Rendering")
## Background layers must stay below gameplay (z 0). See
## EnvironmentPresenter.Z_* constants for the reserved ranges.
@export_range(-4096, 4096, 1) var z_index: int = -1000
@export var modulate: Color = Color.WHITE

## True when the layer has anything to draw.
func has_content() -> bool:
	if texture != null:
		return true
	for sprite in sprites:
		if sprite != null and sprite.texture != null:
			return true
	return false

## Returns a copy of [member repeat_size] with negative or non-finite axes
## replaced by zero so a bad value can never break Parallax2D.
func sanitized_repeat_size() -> Vector2:
	var result := repeat_size
	if not is_finite(result.x) or result.x < 0.0:
		result.x = 0.0
	if not is_finite(result.y) or result.y < 0.0:
		result.y = 0.0
	return result
